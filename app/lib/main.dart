import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_model.dart';
import 'notifier.dart';
import 'push_service.dart';
import 'screens/home_screen.dart';
import 'screens/homes_screen.dart';
import 'screens/login_screen.dart';
import 'theme.dart';

/// Để đóng các màn hình phụ đã đẩy lên (thành viên, ngữ cảnh…) khi quyền truy cập căn hộ bị thu hồi.
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Notifier.init();
  await PushService.init();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppModel()
        ..onPopToRoot = (() => navigatorKey.currentState?.popUntil((r) => r.isFirst))
        ..boot(),
      child: const SmartHomeApp(),
    ),
  );
}

class SmartHomeApp extends StatelessWidget {
  const SmartHomeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigatorKey,
    title: 'MSmart',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.light),
    darkTheme: buildTheme(Brightness.dark),
    home: Consumer<AppModel>(
      builder: (_, m, _) {
        Widget page;
        if (m.booting) {
          page = const Scaffold(
            key: ValueKey('boot'),
            body: Center(child: CircularProgressIndicator()),
          );
        } else if (!m.loggedIn) {
          page = const LoginScreen(key: ValueKey('login'));
        } else if (m.home == null) {
          page = const HomesScreen(key: ValueKey('homes'));
        } else {
          page = const HomeScreen(key: ValueKey('home'));
        }
        return AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: page);
      },
    ),
  );
}
