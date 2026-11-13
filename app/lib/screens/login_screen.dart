import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  bool _register = false, _busy = false, _hide = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final m = context.read<AppModel>();
    try {
      if (_register) {
        await m.register(_email.text.trim(), _password.text, _name.text.trim());
      } else {
        await m.login(_email.text.trim(), _password.text);
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      body: Container(
        decoration: brandGradient(context),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .18),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: Colors.white.withValues(alpha: .35)),
                    ),
                    child: const Icon(Icons.home_rounded, size: 46, color: Colors.white),
                  ),
                  const SizedBox(height: 16),
                  Text('Smart Home', style: tt.headlineLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text('Điều khiển ngôi nhà của bạn, ở mọi nơi',
                      style: tt.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: .85))),
                  const SizedBox(height: 28),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(22),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Text(_register ? 'Tạo tài khoản' : 'Đăng nhập', style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 18),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 200),
                          alignment: Alignment.topCenter,
                          child: _register
                              ? Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: TextField(
                                    controller: _name,
                                    textCapitalization: TextCapitalization.words,
                                    decoration: const InputDecoration(labelText: 'Họ tên', prefixIcon: Icon(Icons.person_outline)),
                                  ),
                                )
                              : const SizedBox(width: double.infinity),
                        ),
                        TextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline)),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _password,
                          obscureText: _hide,
                          onSubmitted: (_) => _busy ? null : _submit(),
                          decoration: InputDecoration(
                            labelText: _register ? 'Mật khẩu (tối thiểu 8 ký tự)' : 'Mật khẩu',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                              onPressed: () => setState(() => _hide = !_hide),
                            ),
                          ),
                        ),
                        if (_error != null)
                          Container(
                            margin: const EdgeInsets.only(top: 14),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(12)),
                            child: Row(children: [
                              Icon(Icons.error_outline, size: 18, color: cs.onErrorContainer),
                              const SizedBox(width: 8),
                              Expanded(child: Text(_error!, style: TextStyle(color: cs.onErrorContainer))),
                            ]),
                          ),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: _busy ? null : _submit,
                          child: _busy
                              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                              : Text(_register ? 'Đăng ký' : 'Đăng nhập'),
                        ),
                        const SizedBox(height: 4),
                        TextButton(
                          onPressed: _busy ? null : () => setState(() => _register = !_register),
                          child: Text(_register ? 'Đã có tài khoản? Đăng nhập' : 'Chưa có tài khoản? Đăng ký'),
                        ),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
