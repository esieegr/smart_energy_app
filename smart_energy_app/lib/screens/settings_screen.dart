import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/mqtt_service.dart';
import '../services/kafka_service.dart';

class SettingsScreen extends StatefulWidget {
  final MqttService  mqttService;
  final KafkaService kafkaService;
  const SettingsScreen({
    super.key,
    required this.mqttService,
    required this.kafkaService,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _keyIp   = 'mqtt_broker_ip';
  static const _keyPort = 'mqtt_broker_port';

  final _formKey        = GlobalKey<FormState>();
  final _ipController   = TextEditingController();
  final _portController = TextEditingController();

  // Kafka fields
  final _kafkaIpController    = TextEditingController();
  final _kafkaPortController  = TextEditingController();
  final _kafkaTopicController = TextEditingController();

  bool _isSaving      = false;
  bool _isSavingKafka = false;
  String? _kafkaTestResult;

  @override
  void initState() {
    super.initState();
    _loadSaved();
    _loadKafkaSaved();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ipController.text   = prefs.getString(_keyIp) ?? '';
      _portController.text = (prefs.getInt(_keyPort) ?? 1883).toString();
    });
  }

  Future<void> _loadKafkaSaved() async {
    setState(() {
      _kafkaIpController.text    = widget.kafkaService.brokerIp;
      _kafkaPortController.text  = widget.kafkaService.port.toString();
      _kafkaTopicController.text = widget.kafkaService.topic;
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

  Future<void> _saveKafka() async {
    final ip    = _kafkaIpController.text.trim();
    final port  = int.tryParse(_kafkaPortController.text.trim()) ?? 8082;
    final topic = _kafkaTopicController.text.trim();

    if (ip.isEmpty) {
      await widget.kafkaService.clearSettings();
      if (mounted) setState(() => _kafkaTestResult = 'Kafka désactivé');
      return;
    }

    setState(() => _isSavingKafka = true);
    await widget.kafkaService.saveSettings(
      brokerIp: ip,
      port:     port,
      topic:    topic.isEmpty ? 'domoticz-events' : topic,
    );
    if (mounted) setState(() { _isSavingKafka = false; _kafkaTestResult = null; });
  }

  Future<void> _testKafka() async {
    setState(() { _isSavingKafka = true; _kafkaTestResult = null; });
    // Save first so testConnection uses the current field values
    await _saveKafka();
    final error = await widget.kafkaService.testConnection();
    if (mounted) {
      setState(() {
        _isSavingKafka  = false;
        _kafkaTestResult = error ?? '✓ Connexion Kafka OK';
      });
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
    _kafkaIpController.dispose();
    _kafkaPortController.dispose();
    _kafkaTopicController.dispose();
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
              // ── Statut MQTT ────────────────────────────────────────────────
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

              const SizedBox(height: 40),
              const Divider(),
              const SizedBox(height: 16),

              // ── Section Kafka ──────────────────────────────────────────────
              Row(children: [
                Icon(Icons.stream_rounded,
                    color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text('Kafka (optionnel)',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 6),
              Text(
                'Envoie chaque message Domoticz vers un topic Kafka via le '
                'Confluent REST Proxy (port 8082 par défaut). '
                'Laisser vide pour désactiver.',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _kafkaIpController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'IP du serveur (REST Proxy)',
                  hintText: 'ex : 192.168.1.50',
                  prefixIcon: Icon(Icons.dns_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _kafkaPortController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Port REST Proxy',
                  hintText: '8082',
                  prefixIcon: Icon(Icons.numbers_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _kafkaTopicController,
                decoration: const InputDecoration(
                  labelText: 'Topic Kafka',
                  hintText: 'domoticz-events',
                  prefixIcon: Icon(Icons.label_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isSavingKafka ? null : _saveKafka,
                    icon: _isSavingKafka
                        ? const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save_outlined),
                    label: const Text('Sauvegarder'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _isSavingKafka ? null : _testKafka,
                    icon: _isSavingKafka
                        ? const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.network_check_outlined),
                    label: const Text('Tester'),
                  ),
                ),
              ]),
              if (_kafkaTestResult != null) ...[
                const SizedBox(height: 12),
                Row(children: [
                  Icon(
                    _kafkaTestResult!.startsWith('✓')
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    color: _kafkaTestResult!.startsWith('✓')
                        ? Colors.green
                        : Colors.red,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _kafkaTestResult!,
                      style: TextStyle(
                        color: _kafkaTestResult!.startsWith('✓')
                            ? Colors.green
                            : Colors.red,
                      ),
                    ),
                  ),
                ]),
              ],
              // Statut Kafka en temps réel
              const SizedBox(height: 12),
              ListenableBuilder(
                listenable: widget.kafkaService,
                builder: (context, _) {
                  final ks = widget.kafkaService;
                  if (!ks.isEnabled) return const SizedBox.shrink();
                  final color = switch (ks.status) {
                    KafkaStatus.idle       => Colors.green,
                    KafkaStatus.publishing => Colors.orange,
                    KafkaStatus.error      => Colors.red,
                    KafkaStatus.disabled   => Colors.grey,
                  };
                  return Text(
                    ks.summary,
                    style: theme.textTheme.bodySmall?.copyWith(color: color),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

