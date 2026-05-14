import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_theme.dart';
import 'providers/app_provider.dart';
import 'pages/main_page.dart';
import 'pages/settings_page.dart';
import 'pages/onboarding_page.dart';
import 'utils/background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    if (details.exceptionAsString().contains('ViewInsets cannot be negative')) {
      return;
    }
    FlutterError.presentError(details);
  };

  await BackgroundService.initialize();

  runApp(const XiaoxinChatApp());
}

class XiaoxinChatApp extends StatefulWidget {
  const XiaoxinChatApp({super.key});

  @override
  State<XiaoxinChatApp> createState() => _XiaoxinChatAppState();
}

class _XiaoxinChatAppState extends State<XiaoxinChatApp> {
  String _appName = 'xiaoxinChatAI';

  @override
  void initState() {
    super.initState();
    _loadCustomAppName();
  }

  Future<void> _loadCustomAppName() async {
    final prefs = await SharedPreferences.getInstance();
    final customName = prefs.getString('custom_app_name') ?? '';
    if (customName.isNotEmpty && mounted) {
      setState(() {
        _appName = customName;
      });
    }
    if (customName.isNotEmpty) {
      try {
        const channel = MethodChannel('com.xiaoxinchat.xiaoxin_chat_app/restart');
        await channel.invokeMethod('setAppDisplay', {
          'label': customName,
          'iconPath': prefs.getString('custom_app_icon_path'),
        });
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppProvider()),
      ],
      child: MaterialApp(
        title: _appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: ThemeMode.system,
        builder: (context, child) {
          SystemChrome.setApplicationSwitcherDescription(
            ApplicationSwitcherDescription(
              label: _appName,
              primaryColor: AppTheme.primaryColor.toARGB32(),
            ),
          );
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.0)),
            child: child!,
          );
        },
        home: const AppWrapper(),
      ),
    );
  }
}

class AppWrapper extends StatefulWidget {
  const AppWrapper({super.key});

  @override
  State<AppWrapper> createState() => _AppWrapperState();
}

class _AppWrapperState extends State<AppWrapper> {
  bool _isLoading = true;
  bool _onboardingComplete = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final provider = context.read<AppProvider>();
    await provider.initialize();

    final prefs = await SharedPreferences.getInstance();
    final complete = prefs.getBool('onboarding_complete') ?? false;

    if (mounted) {
      setState(() {
        _onboardingComplete = complete;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_onboardingComplete) {
      return const MainScaffold();
    }
    return OnboardingPage(
      onComplete: () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('onboarding_complete', true);
        if (mounted) setState(() => _onboardingComplete = true);
      },
    );
  }
}

class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold>
    with WidgetsBindingObserver {
  int _currentIndex = 0;

  final List<Widget> _pages = [
    const MainPage(),
    const SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    try {
      final provider = context.read<AppProvider>();
      if (state == AppLifecycleState.resumed) {
        provider.botService.onForeground();
      } else if (state == AppLifecycleState.paused) {
        provider.botService.onBackground();
        BackgroundService.start();
      }
    } catch (e) {
      debugPrint('[MainScaffold] 生命周期回调异常: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.chat_rounded),
            activeIcon: Icon(Icons.chat_rounded),
            label: '聊天',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_rounded),
            activeIcon: Icon(Icons.settings_rounded),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
