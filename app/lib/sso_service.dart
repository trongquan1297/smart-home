import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// Client ID OAuth của Google (dự án msmart-ed122; không phải bí mật, nằm sẵn trong app phát hành).
/// Đổi khi cần bằng --dart-define=GOOGLE_IOS_CLIENT_ID=… / GOOGLE_SERVER_CLIENT_ID=…
/// iOS còn cần URL scheme = client iOS đảo ngược: ios/Flutter/GoogleSignIn.xcconfig.
/// Android dùng client Web làm serverClientId; cần thêm OAuth client Android (package + SHA-1) trong Google Cloud.
const _googleIosClientId = String.fromEnvironment(
  'GOOGLE_IOS_CLIENT_ID',
  defaultValue: '511774696963-n5cu5mo2ej2j8m0e1vnha7fdd6c6d4i4.apps.googleusercontent.com',
);
const _googleServerClientId = String.fromEnvironment(
  'GOOGLE_SERVER_CLIENT_ID',
  defaultValue: '511774696963-hhpar6mrcj9i3te566thasn676lc8jjg.apps.googleusercontent.com',
);

/// Kết quả đăng nhập để gửi lên backend (/v1/auth/sso). Backend tự kiểm tra chữ ký/aud/nonce của [idToken].
class SsoCredential {
  final String provider, idToken;
  final String? nonce, name;

  /// Apple: mã ủy quyền dùng một lần; backend đổi lấy refresh token để thu hồi được khi người dùng xoá tài khoản.
  final String? authorizationCode;
  const SsoCredential(this.provider, this.idToken, {this.nonce, this.name, this.authorizationCode});
}

/// Người dùng tự đóng màn đăng nhập Google/Apple: không coi là lỗi.
class SsoCancelled implements Exception {}

class SsoService {
  static bool _googleReady = false;

  /// iOS: SDK Google (AppAuth) tự chèn một nonce NGẪU NHIÊN vào ID token nếu app không đưa nonce; app không biết giá trị đó
  /// nên backend từ chối ("unauthorized"). Vì vậy app tự tạo nonce và gửi kèm. google_sign_in chỉ nhận nonce lúc
  /// `initialize` (gọi một lần), nên dùng một nonce cho mỗi lần chạy app.
  static final String _googleNonce = _randomNonce();

  /// App build có client ID Google cho nền tảng này chưa (máy chủ có bật hay không thì hỏi /v1/auth/providers).
  static bool get googleConfigured {
    if (kIsWeb) return false;
    if (Platform.isIOS) return _googleIosClientId.isNotEmpty;
    if (Platform.isAndroid) return _googleServerClientId.isNotEmpty;
    return false;
  }

  /// Sign in with Apple dạng native chỉ có trên iOS (Android/web cần Services ID + trang chuyển hướng riêng).
  static Future<bool> appleAvailable() async {
    if (kIsWeb || !Platform.isIOS) return false;
    try {
      return await SignInWithApple.isAvailable();
    } catch (_) {
      return false;
    }
  }

  static Future<SsoCredential> google() async {
    final g = GoogleSignIn.instance;
    if (!_googleReady) {
      await g.initialize(
        clientId: Platform.isIOS ? _googleIosClientId : null,
        serverClientId: _googleServerClientId.isEmpty ? null : _googleServerClientId,
        nonce: Platform.isIOS ? _googleNonce : null,
      );
      _googleReady = true;
    }
    try {
      final account = await g.authenticate();
      final token = account.authentication.idToken;
      if (token == null || token.isEmpty) throw Exception('Google không trả về ID token');
      return SsoCredential('google', token, nonce: Platform.isIOS ? _googleNonce : null, name: account.displayName);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) throw SsoCancelled();
      rethrow;
    }
  }

  static Future<SsoCredential> apple() async {
    // Apple nhận sha256(nonce) và đưa nó vào ID token; backend so với sha256(nonce gốc) → token không dùng lại được.
    final raw = _randomNonce();
    final hashed = sha256.convert(utf8.encode(raw)).toString();
    try {
      final c = await SignInWithApple.getAppleIDCredential(scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName], nonce: hashed);
      final token = c.identityToken;
      if (token == null || token.isEmpty) throw Exception('Apple không trả về ID token');
      // Apple chỉ cho biết họ tên ở LẦN ĐẦU người dùng đồng ý; backend dùng khi tạo tài khoản mới.
      final name = [c.givenName, c.familyName].whereType<String>().where((s) => s.trim().isNotEmpty).join(' ');
      return SsoCredential('apple', token, nonce: raw, name: name.isEmpty ? null : name, authorizationCode: c.authorizationCode);
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) throw SsoCancelled();
      rethrow;
    }
  }

  static Future<void> signOut() async {
    if (!_googleReady) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }

  static String _randomNonce([int length = 32]) {
    const chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final r = Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }
}
