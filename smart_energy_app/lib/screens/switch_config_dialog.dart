import 'package:flutter/material.dart';
import '../models/domoticz_message.dart';
import '../services/mqtt_service.dart';

/// Shows a dialog that lets the user configure which switch idx controls a
/// given kWh meter.  It lists the switches already discovered on domoticz/out,
/// offers a manual entry field, and has a "Scan" button to query a range of
/// idx values via getdeviceinfo.
///
/// Returns nothing — it calls [mqttService.setMeterSwitchMapping] directly
/// when the user confirms.
Future<void> showSwitchConfigDialog({
  required BuildContext context,
  required int meterIdx,
  required String meterName,
  required MqttService mqttService,
}) {
  return showDialog(
    context: context,
    builder: (ctx) => _SwitchConfigDialog(
      meterIdx: meterIdx,
      meterName: meterName,
      mqttService: mqttService,
    ),
  );
}

// ---------------------------------------------------------------------------

class _SwitchConfigDialog extends StatefulWidget {
  final int meterIdx;
  final String meterName;
  final MqttService mqttService;

  const _SwitchConfigDialog({
    required this.meterIdx,
    required this.meterName,
    required this.mqttService,
  });

  @override
  State<_SwitchConfigDialog> createState() => _SwitchConfigDialogState();
}

class _SwitchConfigDialogState extends State<_SwitchConfigDialog> {
  final _manualController = TextEditingController();
  int? _selectedIdx;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    // Pre-select the currently mapped switch if any
    _selectedIdx = widget.mqttService.switchIdxForMeter(widget.meterIdx);
    if (_selectedIdx != null) {
      _manualController.text = _selectedIdx.toString();
    }
  }

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  // ── Scan via MQTT getdeviceinfo ──────────────────────────────────────────

  Future<void> _scan() async {
    setState(() => _scanning = true);
    widget.mqttService.scanSwitches(from: 1, to: 40);
    // Wait a couple of seconds for Domoticz to reply, then refresh list
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _scanning = false);
  }

  // ── Confirm selection ────────────────────────────────────────────────────

  Future<void> _confirm() async {
    final manualText = _manualController.text.trim();
    final swIdx = int.tryParse(manualText) ?? _selectedIdx;
    if (swIdx == null || swIdx <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Veuillez choisir ou saisir un idx valide')),
      );
      return;
    }
    await widget.mqttService.setMeterSwitchMapping(widget.meterIdx, swIdx);
    if (mounted) Navigator.of(context).pop();
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.mqttService,
      builder: (ctx, _) {
        final discovered = widget.mqttService.discoveredSwitches;

        // Switchs already bound to a *different* meter (warn the user)
        final usedElsewhere = <int>{};
        widget.mqttService.messages.values
            .where((m) => m.isKwhMeter && m.idx != widget.meterIdx)
            .forEach((m) {
          final sw = widget.mqttService.switchIdxForMeter(m.idx);
          if (sw != null) usedElsewhere.add(sw);
        });

        return AlertDialog(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Associer un switch'),
              Text(
                'Compteur : ${widget.meterName} (idx ${widget.meterIdx})',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.grey),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Discovered list ────────────────────────────────────────
                if (discovered.isNotEmpty) ...[
                  Text(
                    'Switchs détectés automatiquement :',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView(
                      shrinkWrap: true,
                      children: discovered.values
                          .map((sw) => _SwitchTile(
                                sw: sw,
                                selected: _selectedIdx == sw.idx,
                                usedByOtherMeter: usedElsewhere.contains(sw.idx),
                                onTap: () => setState(() {
                                  _selectedIdx = sw.idx;
                                  _manualController.text = sw.idx.toString();
                                }),
                              ))
                          .toList(),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                // ── Scan button ────────────────────────────────────────────
                OutlinedButton.icon(
                  onPressed: _scanning ? null : _scan,
                  icon: _scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search, size: 18),
                  label: Text(_scanning
                      ? 'Scan en cours…'
                      : discovered.isEmpty
                          ? 'Scanner les appareils (idx 1–40)'
                          : 'Rescanner'),
                ),
                const SizedBox(height: 12),
                // ── Manual entry ───────────────────────────────────────────
                const Divider(),
                const SizedBox(height: 4),
                Text(
                  'Ou saisissez l\'idx manuellement :',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _manualController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'idx du switch (ex : 7)',
                    prefixIcon: Icon(Icons.power_settings_new),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) {
                    final i = int.tryParse(v.trim());
                    if (i != null) setState(() => _selectedIdx = i);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: _confirm,
              child: const Text('Associer'),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------

class _SwitchTile extends StatelessWidget {
  final DomoticzMessage sw;
  final bool selected;
  final bool usedByOtherMeter;
  final VoidCallback onTap;

  const _SwitchTile({
    required this.sw,
    required this.selected,
    required this.usedByOtherMeter,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      leading: Icon(
        sw.isSwitchOn ? Icons.power : Icons.power_off_outlined,
        color: sw.isSwitchOn ? Colors.green : Colors.grey,
        size: 20,
      ),
      title: Text(sw.name),
      subtitle: Text(
        'idx ${sw.idx} · ${sw.dtype}/${sw.stype}'
        '${usedByOtherMeter ? '  ⚠ déjà associé à un autre compteur' : ''}',
        style: TextStyle(
          color: usedByOtherMeter ? Colors.orange : null,
        ),
      ),
      trailing: selected
          ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
          : null,
      selected: selected,
      selectedTileColor: theme.colorScheme.primaryContainer.withAlpha(80),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      onTap: onTap,
    );
  }
}
