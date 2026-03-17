import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/dashboard_screen.dart';
import 'services/mqtt_service.dart';

void main() {
  runApp(const SmartEnergyApp());
}

class SmartEnergyApp extends StatefulWidget {
  const SmartEnergyApp({super.key});

  @override
  State<SmartEnergyApp> createState() => _SmartEnergyAppState();
}

class _SmartEnergyAppState extends State<SmartEnergyApp> {
  final MqttService _mqttService = MqttService();

  @override
  void initState() {
    super.initState();
    _autoConnect();
  }

  /// If an IP was previously saved, reconnect automatically at startup.
  Future<void> _autoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString('mqtt_broker_ip') ?? '';
    final port = prefs.getInt('mqtt_broker_port') ?? 1883;
    if (ip.isNotEmpty) {
      await _mqttService.connect(ip, port: port);
    }
  }

  @override
  void dispose() {
    _mqttService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Energy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
      ),
      home: DashboardScreen(mqttService: _mqttService),
    );
  }
}
