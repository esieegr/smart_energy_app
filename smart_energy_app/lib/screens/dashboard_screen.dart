import 'package:flutter/material.dart';
import '../models/domoticz_message.dart';
import '../services/mqtt_service.dart';
import '../services/kafka_service.dart';
import 'device_detail_screen.dart';
import 'settings_screen.dart';
import 'switch_config_dialog.dart';

class DashboardScreen extends StatelessWidget {
  final MqttService  mqttService;
  final KafkaService kafkaService;

  const DashboardScreen({
    super.key,
    required this.mqttService,
    required this.kafkaService,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Energy Monitor'),
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: theme.colorScheme.onPrimary,
        actions: [
          ListenableBuilder(
            listenable: mqttService,
            builder: (context, _) {
              final status = mqttService.status;
              final color = switch (status) {
                MqttConnectionStatus.connected => Colors.greenAccent,
                MqttConnectionStatus.connecting => Colors.orangeAccent,
                MqttConnectionStatus.error => Colors.redAccent,
                MqttConnectionStatus.disconnected => Colors.white54,
              };
              return IconButton(
                tooltip: mqttService.statusMessage,
                icon: Icon(Icons.circle, color: color, size: 14),
                onPressed: null,
              );
            },
          ),
          IconButton(
            tooltip: 'Paramètres',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(
                  mqttService:  mqttService,
                  kafkaService: kafkaService,
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: mqttService,
        builder: (context, _) {
          final messages = mqttService.messages;
          final status = mqttService.status;

          if (status == MqttConnectionStatus.disconnected ||
              status == MqttConnectionStatus.error) {
            return _NotConnectedPlaceholder(
              mqttService:  mqttService,
              kafkaService: kafkaService,
              message: mqttService.statusMessage,
            );
          }

          if (status == MqttConnectionStatus.connecting) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Connexion au broker MQTT…'),
                ],
              ),
            );
          }

          if (messages.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sensors, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'En attente de données Domoticz…',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          final kwhMessages = messages.values
              .where((m) => m.isKwhMeter)
              .toList()
            ..sort((a, b) => a.idx.compareTo(b.idx));

          // Collect all switch idx already associated to a kWh meter
          // so we don't show them again in "Autres capteurs"
          final associatedSwitchIdxs = kwhMessages
              .map((m) => mqttService.switchIdxForMeter(m.idx))
              .whereType<int>()
              .toSet();

          final otherMessages = messages.values
              .where((m) => !m.isKwhMeter && !associatedSwitchIdxs.contains(m.idx))
              .toList()
            ..sort((a, b) => a.idx.compareTo(b.idx));

          return RefreshIndicator(
            onRefresh: () async {},
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (kwhMessages.isNotEmpty) ...[
                  _SectionHeader(title: 'Compteurs d\'énergie'),
                  const SizedBox(height: 8),
                  ...kwhMessages.map((m) => _KwhMeterCard(
                        message: m,
                        mqttService: mqttService,
                      )),
                ],
                if (otherMessages.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _SectionHeader(title: 'Autres capteurs'),
                  const SizedBox(height: 8),
                  ...otherMessages.map((m) => _GenericSensorCard(message: m)),
                ],
                const SizedBox(height: 80),
              ],
            ),
          );
        },
      ),
      floatingActionButton: ListenableBuilder(
        listenable: mqttService,
        builder: (context, _) {
          final isConnected =
              mqttService.status == MqttConnectionStatus.connected;
          return FloatingActionButton.extended(
            onPressed: () async {
              if (isConnected) {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Déconnecter ?'),
                    content: const Text(
                        'Voulez-vous vous déconnecter du broker MQTT ?'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Annuler')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Déconnecter')),
                    ],
                  ),
                );
                if (confirm == true) mqttService.disconnect();
              } else {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SettingsScreen(
                      mqttService:  mqttService,
                      kafkaService: kafkaService,
                    ),
                  ),
                );
              }
            },
            icon: Icon(isConnected ? Icons.wifi_off : Icons.wifi),
            label: Text(isConnected ? 'Déconnecter' : 'Connecter'),
            backgroundColor:
                isConnected ? Colors.red.shade400 : theme.colorScheme.primary,
            foregroundColor: Colors.white,
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section header
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context)
          .textTheme
          .titleSmall
          ?.copyWith(color: Colors.grey.shade600, letterSpacing: 0.8),
    );
  }
}

// ---------------------------------------------------------------------------
// kWh Meter card
// ---------------------------------------------------------------------------

class _KwhMeterCard extends StatelessWidget {
  final DomoticzMessage message;
  final MqttService mqttService;
  const _KwhMeterCard({required this.message, required this.mqttService});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Find the switch idx associated with this meter (via HTTP API mapping)
    final switchIdx = mqttService.switchIdxForMeter(message.idx) ?? message.idx;
    final isOn = mqttService.switchStates[switchIdx] ?? false;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DeviceDetailScreen(
              idx: message.idx,
              mqttService: mqttService,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.bolt,
                      color: theme.colorScheme.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message.name,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'idx ${message.idx} · ${message.dtype} / ${message.stype}',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  _RssiChip(rssi: message.rssi),
                ],
              ),
              const SizedBox(height: 16),
              // Metrics row
              Row(
                children: [
                  Expanded(
                    child: _MetricTile(
                      icon: Icons.electric_meter_outlined,
                      label: 'Énergie consommée',
                      value: '${message.energyWh.toStringAsFixed(3)} Wh',
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MetricTile(
                      icon: Icons.speed_outlined,
                      label: 'Puissance actuelle',
                      value: '${message.powerWatts.toStringAsFixed(1)} W',
                      color: Colors.orange.shade700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.access_time, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Mis à jour : ${message.lastUpdate}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.grey),
                    ),
                  ),
                  // Quick ON/OFF toggle
                  _QuickSwitch(
                    meterIdx: message.idx,
                    meterName: message.name,
                    switchIdx: mqttService.switchIdxForMeter(message.idx),
                    isOn: isOn,
                    mqttService: mqttService,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Quick ON/OFF toggle shown on the card
// ---------------------------------------------------------------------------

class _QuickSwitch extends StatelessWidget {
  final int meterIdx;
  final String meterName;
  final int? switchIdx;     // null = not yet configured
  final bool isOn;
  final MqttService mqttService;

  const _QuickSwitch({
    required this.meterIdx,
    required this.meterName,
    required this.switchIdx,
    required this.isOn,
    required this.mqttService,
  });

  @override
  Widget build(BuildContext context) {
    final connected = mqttService.status == MqttConnectionStatus.connected;
    final configured = switchIdx != null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!configured)
          // No switch configured → show a "configure" icon button
          GestureDetector(
            onTap: () {}, // absorb card tap
            child: Tooltip(
              message: 'Associer un switch à ce compteur',
              child: IconButton(
                icon: const Icon(Icons.power_settings_new_outlined,
                    color: Colors.grey),
                iconSize: 22,
                onPressed: connected
                    ? () => showSwitchConfigDialog(
                          context: context,
                          meterIdx: meterIdx,
                          meterName: meterName,
                          mqttService: mqttService,
                        )
                    : null,
              ),
            ),
          )
        else ...[
          Icon(Icons.power_settings_new,
              size: 16, color: isOn ? Colors.green : Colors.grey),
          const SizedBox(width: 4),
          // GestureDetector absorbs the tap so it doesn't bubble up to
          // the card's InkWell and trigger navigation.
          GestureDetector(
            onTap: () {}, // absorb
            child: Switch.adaptive(
              value: isOn,
              activeThumbColor: Colors.green,
              activeTrackColor: Colors.green.shade200,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: connected
                  ? (val) => mqttService.publishSwitch(switchIdx!, on: val)
                  : null,
            ),
          ),
          // Long-press to reconfigure
          GestureDetector(
            onTap: () {}, // absorb
            child: Tooltip(
              message: 'Changer le switch associé (idx $switchIdx)',
              child: IconButton(
                icon: const Icon(Icons.edit_outlined, size: 16),
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                onPressed: connected
                    ? () => showSwitchConfigDialog(
                          context: context,
                          meterIdx: meterIdx,
                          meterName: meterName,
                          mqttService: mqttService,
                        )
                    : null,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Generic sensor card (non-kWh devices)
// ---------------------------------------------------------------------------

class _GenericSensorCard extends StatelessWidget {
  final DomoticzMessage message;
  const _GenericSensorCard({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: const Icon(Icons.sensors),
        title: Text(message.name),
        subtitle: Text(
          '${message.dtype} / ${message.stype}  ·  '
          'val1: ${message.svalue1}  val2: ${message.svalue2}',
          style: theme.textTheme.bodySmall,
        ),
        trailing: _RssiChip(rssi: message.rssi),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Metric tile
// ---------------------------------------------------------------------------

class _MetricTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// RSSI chip
// ---------------------------------------------------------------------------

class _RssiChip extends StatelessWidget {
  final int rssi;
  const _RssiChip({required this.rssi});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: const Icon(Icons.signal_cellular_alt, size: 14),
      label: Text('RSSI $rssi'),
      labelStyle: const TextStyle(fontSize: 11),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}

// ---------------------------------------------------------------------------
// Not-connected placeholder
// ---------------------------------------------------------------------------

class _NotConnectedPlaceholder extends StatelessWidget {
  final MqttService  mqttService;
  final KafkaService kafkaService;
  final String message;

  const _NotConnectedPlaceholder({
    required this.mqttService,
    required this.kafkaService,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final isError = mqttService.status == MqttConnectionStatus.error;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isError ? Icons.wifi_off : Icons.wifi_off_outlined,
              size: 80,
              color: isError ? Colors.red.shade300 : Colors.grey.shade400,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isError ? Colors.red.shade400 : Colors.grey,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(
                    mqttService:  mqttService,
                    kafkaService: kafkaService,
                  ),
                ),
              ),
              icon: const Icon(Icons.settings),
              label: const Text('Configurer le broker'),
            ),          ],
        ),
      ),
    );
  }
}
