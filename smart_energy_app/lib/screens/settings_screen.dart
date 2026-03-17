import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/mqtt_service.dart';

class SettingsScreen extends StatefulWidget {
  final MqttService mqttService;
  const SettingsScreen({super.key, required this.mqttService});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _keyIp      = 'mqtt_broker_ip';
  static const _keyPort    = 'mqtt_broker_port';

  final _formKey            = GlobalKey<FormState>();
  final _ipController       = TextEditingController();
  final _portController     = TextEditingController();

  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ipController.text   = prefs.getString(_keyIp) ?? '';
      _portController.text = (prefs.getInt(_keyPort) ?? 1883).toString();
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    final ip   = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 1883;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyIp, ip);
    await prefs.setInt(_keyPort, port);

    await widget.mqttService.connect(ip, port: port);

    if (mounted) {
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connexion à $ip:$port en cours…'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.of(context).pop();
    }
  }

  String? _validateIp(String? v) {
    if (v == null || v.trim().isEmpty) return 'IP ou nom d\'hôte requis';
    return null;
  }

  String? _validatePort(String? v) {
    final p = int.tryParse(v?.trim() ?? '');
    if (p == null || p < 1 || p > 65535) return 'Port invalide (1–65535)';
    return null;
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Paramètres'),
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: theme.colorScheme.onPrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Broker MQTT ──────────────────────────────────────────────
              Text('Broker MQTT',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                'L\'association switch ↔ compteur se configure directement '
                'depuis le tableau de bord en appuyant sur l\'icône switch.',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _ipController,
                validator: _validateIp,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Adresse IP du serveur',
                  hintText: 'ex : 192.168.1.100',
                  prefixIcon: Icon(Icons.dns_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _portController,
                validator: _validatePort,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Port MQTT',
                  hintText: '1883',
                  prefixIcon: Icon(Icons.numbers_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 32),
              // ── Bouton ────────────────────────────────────────────────────
              FilledButton.icon(
                onPressed: _isSaving ? null : _save,
                icon: _isSaving
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi),
                label: Text(_isSaving ? 'Connexion…' : 'Connecter'),
              ),
              const SizedBox(height: 24),
              // ── Statut ────────────────────────────────────────────────────
              ListenableBuilder(
                listenable: widget.mqttService,
                builder: (context, _) {
                  final status  = widget.mqttService.status;
                  final message = widget.mqttService.statusMessage;
                  final color = switch (status) {
                    MqttConnectionStatus.connected    => Colors.green,
                    MqttConnectionStatus.connecting   => Colors.orange,
                    MqttConnectionStatus.error        => Colors.red,
                    MqttConnectionStatus.disconnected => Colors.grey,
                  };
                  final icon = switch (status) {
                    MqttConnectionStatus.connected    => Icons.check_circle,
                    MqttConnectionStatus.connecting   => Icons.hourglass_empty_rounded,
                    MqttConnectionStatus.error        => Icons.error_outline,
                    MqttConnectionStatus.disconnected => Icons.wifi_off_outlined,
                  };
                  return Row(children: [
                    Icon(icon, color: color, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(message, style: TextStyle(color: color)),
                    ),
                  ]);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

