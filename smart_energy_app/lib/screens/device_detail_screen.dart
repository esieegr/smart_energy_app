import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../models/domoticz_message.dart';
import '../models/energy_history.dart';
import '../services/mqtt_service.dart';
import 'switch_config_dialog.dart';

class DeviceDetailScreen extends StatefulWidget {
  final int idx;
  final MqttService mqttService;

  const DeviceDetailScreen({
    super.key,
    required this.idx,
    required this.mqttService,
  });

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  HistoryWindow _window = HistoryWindow.h24;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.mqttService,
      builder: (context, _) {
        final msg       = widget.mqttService.messages[widget.idx];
        final history   = widget.mqttService.histories[widget.idx];
        final switchIdx = widget.mqttService.switchIdxForMeter(widget.idx);
        final isOn      = widget.mqttService.switchStates[switchIdx ?? widget.idx] ?? false;

        return Scaffold(
          appBar: AppBar(
            title: Text(msg?.name ?? 'Appareil ${widget.idx}'),
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
          ),
          body: msg == null
              ? const Center(child: Text('Aucune donnée reçue'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _InfoCard(msg: msg),
                    const SizedBox(height: 16),
                    if (msg.isKwhMeter) ...[
                      _SwitchCard(
                        meterIdx:   widget.idx,
                        meterName:  msg.name,
                        switchIdx:  switchIdx,
                        isOn:       isOn,
                        mqttService: widget.mqttService,
                      ),
                      const SizedBox(height: 16),
                      // ── Sélecteur de période ──────────────────────────────
                      _WindowSelector(
                        selected: _window,
                        onChanged: (w) => setState(() => _window = w),
                      ),
                      const SizedBox(height: 12),
                      _PowerChart(history: history, window: _window),
                      const SizedBox(height: 16),
                      if (history != null && history.getPointsForWindow(_window).isNotEmpty)
                        _HistoryTable(history: history, window: _window),
                    ],
                  ],
                ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Info card — current values
// ---------------------------------------------------------------------------

class _InfoCard extends StatelessWidget {
  final DomoticzMessage msg;
  const _InfoCard({required this.msg});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Informations',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const Divider(),
            _Row('Type', '${msg.dtype} / ${msg.stype}'),
            _Row('idx', '${msg.idx}'),
            _Row('ID matériel', msg.id),
            _Row('Énergie consommée', '${msg.energyWh.toStringAsFixed(3)} Wh'),
            _Row('Puissance actuelle', '${msg.powerWatts.toStringAsFixed(1)} W'),
            _Row('Dernière mise à jour', msg.lastUpdate),
            _Row('RSSI', '${msg.rssi}'),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  const _Row(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 180,
            child: Text(label,
                style: const TextStyle(color: Colors.grey, fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Switch / ON-OFF card
// ---------------------------------------------------------------------------

class _SwitchCard extends StatelessWidget {
  final int meterIdx;
  final String meterName;
  final int? switchIdx;   // null = not configured
  final bool isOn;
  final MqttService mqttService;

  const _SwitchCard({
    required this.meterIdx,
    required this.meterName,
    required this.switchIdx,
    required this.isOn,
    required this.mqttService,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = mqttService.status == MqttConnectionStatus.connected;
    final configured = switchIdx != null;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: !configured
                    ? Colors.grey.withAlpha(30)
                    : isOn
                        ? Colors.green.withAlpha(30)
                        : Colors.red.withAlpha(30),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.power_settings_new,
                color: !configured
                    ? Colors.grey
                    : isOn
                        ? Colors.green
                        : Colors.red,
                size: 28,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        configured
                            ? (mqttService.messages[switchIdx]?.name ??
                                'Switch idx $switchIdx')
                            : 'Switch non configuré',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 6),
                      // Edit button to reconfigure
                      if (connected)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => showSwitchConfigDialog(
                            context: context,
                            meterIdx: meterIdx,
                            meterName: meterName,
                            mqttService: mqttService,
                          ),
                          child: Icon(
                            Icons.edit_outlined,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                    ],
                  ),
                  Text(
                    !configured
                        ? 'Appuyez sur ✏ pour associer un switch'
                        : isOn
                            ? 'Allumée'
                            : 'Éteinte',
                    style: TextStyle(
                      color: !configured
                          ? Colors.grey
                          : isOn
                              ? Colors.green
                              : Colors.red,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (!configured)
              // Big "configure" button when not set up
              FilledButton.tonal(
                onPressed: connected
                    ? () => showSwitchConfigDialog(
                          context: context,
                          meterIdx: meterIdx,
                          meterName: meterName,
                          mqttService: mqttService,
                        )
                    : null,
                child: const Text('Associer'),
              )
            else
              Switch.adaptive(
                value: isOn,
                activeThumbColor: Colors.green,
                activeTrackColor: Colors.green.shade200,
                onChanged: connected
                    ? (val) => mqttService.publishSwitch(switchIdx!, on: val)
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Window selector — SegmentedButton
// ---------------------------------------------------------------------------

class _WindowSelector extends StatelessWidget {
  final HistoryWindow selected;
  final ValueChanged<HistoryWindow> onChanged;

  const _WindowSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<HistoryWindow>(
      segments: HistoryWindow.values
          .map((w) => ButtonSegment(value: w, label: Text(w.label)))
          .toList(),
      selected: {selected},
      onSelectionChanged: (s) => onChanged(s.first),
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Energy bar chart
// ---------------------------------------------------------------------------

class _PowerChart extends StatelessWidget {
  final EnergyHistory? history;
  final HistoryWindow  window;
  const _PowerChart({required this.history, required this.window});

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final points = history?.getPointsForWindow(window) ?? [];

    // Compute a nice Y-axis range based on energy values
    final maxE = history?.maxEnergyFor(window) ?? 1;
    final minE = history?.minEnergyFor(window) ?? 0;
    // Add 10% headroom; ensure a minimum span so the chart isn't flat
    final span = (maxE - minE).clamp(1.0, double.infinity);
    final chartMax = maxE + span * 0.15;
    final chartMin = (minE - span * 0.10).clamp(0.0, double.infinity);

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                'Énergie consommée (Wh) — ${window.label}  ·  ${points.length} mesures',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            SizedBox(
              height: 220,
              child: points.isEmpty
                  ? const Center(
                      child: Text('En attente de données…',
                          style: TextStyle(color: Colors.grey)))
                  : BarChart(
                      BarChartData(
                        alignment: BarChartAlignment.spaceAround,
                        maxY: chartMax,
                        minY: chartMin,
                        barTouchData: BarTouchData(
                          touchTooltipData: BarTouchTooltipData(
                            getTooltipColor: (_) =>
                                theme.colorScheme.surfaceContainerHigh,
                            getTooltipItem: (group, groupIndex, rod, rodIndex) {
                              final p = points[groupIndex];
                              final time =
                                  '${p.time.hour.toString().padLeft(2, '0')}:${p.time.minute.toString().padLeft(2, '0')}:${p.time.second.toString().padLeft(2, '0')}';
                              return BarTooltipItem(
                                '$time\n${rod.toY.toStringAsFixed(3)} Wh',
                                TextStyle(
                                  color: theme.colorScheme.onSurface,
                                  fontSize: 11,
                                ),
                              );
                            },
                          ),
                        ),
                        titlesData: FlTitlesData(
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 56,
                              getTitlesWidget: (val, meta) => Text(
                                '${val.toStringAsFixed(1)} Wh',
                                style: const TextStyle(fontSize: 9),
                              ),
                            ),
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 28,
                              interval: (points.length / 5).ceilToDouble().clamp(1, double.infinity),
                              getTitlesWidget: (val, meta) {
                                final i = val.toInt();
                                if (i < 0 || i >= points.length) {
                                  return const SizedBox.shrink();
                                }
                                final t = points[i].time;
                                return Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                                    style: const TextStyle(fontSize: 9),
                                  ),
                                );
                              },
                            ),
                          ),
                          rightTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          topTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                        ),
                        gridData: FlGridData(
                          drawVerticalLine: false,
                          horizontalInterval: (span / 4).clamp(0.01, double.infinity),
                          getDrawingHorizontalLine: (val) => FlLine(
                            color: theme.dividerColor.withAlpha(80),
                            strokeWidth: 1,
                          ),
                        ),
                        borderData: FlBorderData(show: false),
                        barGroups: List.generate(points.length, (i) {
                          return BarChartGroupData(
                            x: i,
                            barRods: [
                              BarChartRodData(
                                toY: points[i].energyWh,
                                fromY: chartMin,
                                color: theme.colorScheme.primary,
                                width: (260 / points.length.clamp(1, 50))
                                    .clamp(3, 18),
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(4)),
                              ),
                            ],
                          );
                        }),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// History table
// ---------------------------------------------------------------------------

class _HistoryTable extends StatelessWidget {
  final EnergyHistory history;
  final HistoryWindow window;
  const _HistoryTable({required this.history, required this.window});

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    // Show most recent first, filtered by selected window
    final reversed = history.getPointsForWindow(window).reversed.toList();

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Historique — ${window.label} (${reversed.length} mesures)',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(2),
                1: FlexColumnWidth(1.5),
                2: FlexColumnWidth(1.5),
              },
              children: [
                TableRow(
                  decoration: BoxDecoration(
                    border: Border(
                        bottom: BorderSide(color: theme.dividerColor)),
                  ),
                  children: const [
                    _TableHeader('Date / Heure'),
                    _TableHeader('Puissance'),
                    _TableHeader('Énergie'),
                  ],
                ),
                ...reversed.map(
                  (p) => TableRow(children: [
                    _TableCell(
                        '${_fmtDate(p.time)}\n${_fmtTime(p.time)}'),
                    _TableCell('${p.powerWatts.toStringAsFixed(1)} W'),
                    _TableCell('${p.energyWh.toStringAsFixed(3)} Wh'),
                  ]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtDate(DateTime t) =>
      '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}/${t.year}';

  static String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

class _TableHeader extends StatelessWidget {
  final String text;
  const _TableHeader(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(text,
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
      );
}

class _TableCell extends StatelessWidget {
  final String text;
  const _TableCell(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Text(text, style: const TextStyle(fontSize: 12)),
      );
}
