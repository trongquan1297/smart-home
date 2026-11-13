import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_model.dart';
import 'screens/home_screen.dart';
import 'screens/homes_screen.dart';
import 'screens/login_screen.dart';
import 'theme.dart';

void main() => runApp(
      ChangeNotifierProvider(create: (_) => AppModel()..boot(), child: const SmartHomeApp()),
    );

class SmartHomeApp extends StatelessWidget {
  const SmartHomeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Smart Home',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: Consumer<AppModel>(builder: (_, m, _) {
          Widget page;
          if (m.booting) {
            page = const Scaffold(key: ValueKey('boot'), body: Center(child: CircularProgressIndicator()));
          } else if (!m.loggedIn) {
            page = const LoginScreen(key: ValueKey('login'));
          } else if (m.home == null) {
            page = const HomesScreen(key: ValueKey('homes'));
          } else {
            page = const HomeScreen(key: ValueKey('home'));
          }
          return AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: page);
        }),
      );
}
