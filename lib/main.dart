import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/credentials_screen.dart';
import 'services/credentials_service.dart';
import 'services/background_download_service.dart';
import 'services/market_data_service.dart';
import 'screens/dashboard_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize WebSocket setting from SharedPreferences
  await MarketDataService.initializeWebsocketSetting();
  
  // Initialize background download service
  await BackgroundDownloadService.initialize();
  
  // Auto-start service if it was enabled before (survives app restarts and reboots)
  try {
    final prefs = await SharedPreferences.getInstance();
    final wasEnabled = prefs.getBool('background_service_enabled') ?? false;
    if (wasEnabled) {
      await BackgroundDownloadService.startService();
    }
  } catch (e) {
    debugPrint('Error auto-starting background service: $e');
  }
  
  // Set preferred orientations (optional)
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: Colors.blueGrey.shade900,
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: 'QuantKey',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B1120),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF1E293B),
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Color(0xFF0B1120),
          selectedItemColor: Colors.white,
          unselectedItemColor: Colors.white70,
          type: BottomNavigationBarType.fixed,
          showUnselectedLabels: true,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1E3A8A),
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1E293B),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _credentialsService = CredentialsService();
  bool _hasCredentials = false;
  bool _isChecking = true;

  @override
  void initState() {
    super.initState();
    _checkCredentials();
  }

  Future<void> _checkCredentials() async {
    final hasCreds = await _credentialsService.hasCredentials();
    setState(() {
      _hasCredentials = hasCreds;
      _isChecking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      // Splash screen with full logo
      return Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 40),
                  // Full Logo Image - Display complete image without cutting
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(
                      maxWidth: 350,
                      maxHeight: 400,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 20.0),
                    child: Image.asset(
                      'assets/images/Gemini_Generated_Image_blgl61blgl61blgl.png',
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        // Fallback to regular logo if the image doesn't exist
                        return Image.asset(
                          'assets/images/logo.png',
                          fit: BoxFit.contain,
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 40),
                  // Loading indicator
                  const CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF1E3A8A)),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (!_hasCredentials) {
      return CredentialsScreen(
        onCredentialsSaved: () {
          setState(() {
            _hasCredentials = true;
          });
        },
      );
    }

    return const DashboardScreen();
  }
}
