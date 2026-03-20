import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/domoticz_message.dart';
import '../models/energy_history.dart';
import 'kafka_service.dart';

/// SharedPreferences key: JSON map {"meterIdx": switchIdx, ...}
const _kMeterSwitchMap = 'meter_switch_map';

enum MqttConnectionStatus { disconnected, connecting, connected, error }

class MqttService extends ChangeNotifier {
  static const String _topicOut = 'domoticz/out';
  static const String _topicIn  = 'domoticz/in';
  static const int _defaultPort = 1883;

  MqttServerClient? _client;

  /// Optional Kafka service — set after construction via [kafkaService] setter.
  KafkaService? _kafkaService;

  String _brokerIp = '';
  int _port = _defaultPort;
  MqttConnectionStatus _status = MqttConnectionStatus.disconnected;
  String _statusMessage = 'Non connecté';

  final Map<int, DomoticzMessage> _messages = {};
  final Map<int, EnergyHistory> _histories = {};
  // Switch on/off state, keyed by switch idx
  final Map<int, bool> _switchStates = {};
  // meter idx → switch idx (saved in prefs, set from Settings or dialog)
  final Map<int, int> _meterToSwitch = {};
  // All switch devices discovered from domoticz/out (auto-detected)
  final Map<int, DomoticzMessage> _discoveredSwitches = {};

  String get brokerIp => _brokerIp;
  int get port => _port;
  MqttConnectionStatus get status => _status;
  String get statusMessage => _statusMessage;
  Map<int, DomoticzMessage> get messages => Map.unmodifiable(_messages);
  Map<int, EnergyHistory> get histories => Map.unmodifiable(_histories);
  Map<int, bool> get switchStates => Map.unmodifiable(_switchStates);
  /// All switch devices seen on domoticz/out (auto-discovered).
  /// Key = idx, value = last received message.
  Map<int, DomoticzMessage> get discoveredSwitches =>
      Map.unmodifiable(_discoveredSwitches);

  int? switchIdxForMeter(int meterIdx) => _meterToSwitch[meterIdx];
  DomoticzMessage? switchForMeter(int meterIdx) {
    final swIdx = _meterToSwitch[meterIdx];
    return swIdx == null ? null : _messages[swIdx];
  }

  /// Attach a [KafkaService] so every received Domoticz message is forwarded.
  /// Call this from main.dart after creating both services.
  set kafkaService(KafkaService? service) {
    _kafkaService = service;
  }

  // -------------------------------------------------------------------------
  // Persist / load meter→switch mapping
  // -------------------------------------------------------------------------

  Future<void> _persistMeterSwitchMap() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kMeterSwitchMap,
      jsonEncode(_meterToSwitch.map((k, v) => MapEntry(k.toString(), v))),
    );
    debugPrint('[PREFS] saved meterSwitchMap: $_meterToSwitch');
  }

  Future<void> _loadPersistedMeterSwitchMap() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kMeterSwitchMap) ?? '';
    if (raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      decoded.forEach((k, v) {
        final meterIdx = int.tryParse(k);
        final swIdx = v is int ? v : int.tryParse(v.toString());
        if (meterIdx != null && swIdx != null) {
          _meterToSwitch[meterIdx] = swIdx;
        }
      });
      debugPrint('[PREFS] loaded meterSwitchMap: $_meterToSwitch');
    } catch (e) {
      debugPrint('[PREFS] parse error: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Persist / load energy histories
  // -------------------------------------------------------------------------

  /// Charge tous les historiques déjà sauvegardés en SharedPreferences.
  /// Appelé une fois au démarrage avant la connexion MQTT.
  Future<void> _loadAllHistories() async {
    final prefs = await SharedPreferences.getInstance();
    // On parcourt toutes les clés qui commencent par "history_"
    final historyKeys = prefs.getKeys()
        .where((k) => k.startsWith('history_'))
        .toList();
    for (final key in historyKeys) {
      final idxStr = key.replaceFirst('history_', '');
      final idx    = int.tryParse(idxStr);
      if (idx == null) continue;
      final h = EnergyHistory(idx);
      await h.loadFromPrefs();
      if (h.points.isNotEmpty) {
        _histories[idx] = h;
        debugPrint('[PREFS] history loaded — idx=$idx  ${h.points.length} points');
      }
    }
  }

  /// Called from Settings when the user configures a meter→switch association.
  Future<void> setMeterSwitchMapping(int meterIdx, int switchIdx) async {
    _meterToSwitch[meterIdx] = switchIdx;
    await _persistMeterSwitchMap();
    // Ask Domoticz to echo the current state of that switch right away
    _requestDeviceInfo(switchIdx);
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Ask Domoticz to push current state for an idx via domoticz/in
  // -------------------------------------------------------------------------

  void _requestDeviceInfo(int idx) {
    if (_client?.connectionStatus?.state != MqttConnectionState.connected) {
      return;
    }
    final cmd = jsonEncode({'command': 'getdeviceinfo', 'idx': idx});
    debugPrint('[MQTT OUT] domoticz/in → $cmd');
    final builder = MqttClientPayloadBuilder()..addString(cmd);
    _client!.publishMessage(_topicIn, MqttQos.atMostOnce, builder.payload!);
  }

  // -------------------------------------------------------------------------
  // MQTT connect / disconnect
  // -------------------------------------------------------------------------

  Future<void> connect(String ip, {int port = _defaultPort}) async {
    if (_status == MqttConnectionStatus.connecting) return;

    _client?.onDisconnected = null;
    _client?.disconnect();
    _client = null;

    _brokerIp = ip.trim();
    _port = port;

    if (_brokerIp.isEmpty) {
      _setStatus(MqttConnectionStatus.error, 'Adresse IP invalide');
      return;
    }

    // Load persisted meter→switch mapping and energy histories before connecting
    await _loadPersistedMeterSwitchMap();
    await _loadAllHistories();

    _setStatus(MqttConnectionStatus.connecting, 'Connexion à $_brokerIp:$_port…');

    _client = MqttServerClient.withPort(_brokerIp, 'flutter_smart_energy', _port)
      ..logging(on: false)
      ..keepAlivePeriod = 30
      ..connectTimeoutPeriod = 15000
      ..onDisconnected = _onDisconnected
      ..onConnected = _onConnected
      ..onSubscribed = _onSubscribed;

    _client!.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(
            'smart_energy_${DateTime.now().millisecondsSinceEpoch}')
        .startClean()
        .withWillQos(MqttQos.atMostOnce);

    try {
      await _client!.connect();
    } on Exception catch (e) {
      _setStatus(MqttConnectionStatus.error, 'Erreur : $e');
      _client?.disconnect();
      _client = null;
      return;
    }

    if (_client!.connectionStatus?.state == MqttConnectionState.connected) {
      if (_status != MqttConnectionStatus.connected) {
        _setStatus(MqttConnectionStatus.connected, 'Connecté à $_brokerIp:$_port');
      }
      _client!.subscribe(_topicOut, MqttQos.atMostOnce);
      _client!.updates!.listen(_onMessage);

      // Ask Domoticz to push the current state of all known switches
      for (final swIdx in _meterToSwitch.values.toSet()) {
        _requestDeviceInfo(swIdx);
      }
    } else {
      final code = _client!.connectionStatus?.returnCode;
      _setStatus(MqttConnectionStatus.error, 'Échec de connexion (code : $code)');
      _client?.disconnect();
      _client = null;
    }
  }

  Future<void> disconnect() async {
    _client?.onDisconnected = null;
    _client?.disconnect();
    _client = null;
    _setStatus(MqttConnectionStatus.disconnected, 'Non connecté');
  }

  void _onConnected() {
    _setStatus(MqttConnectionStatus.connected, 'Connecté à $_brokerIp:$_port');
  }

  void _onDisconnected() {
    _setStatus(MqttConnectionStatus.disconnected, 'Déconnecté');
  }

  void _onSubscribed(String topic) {
    debugPrint('[MQTT] Abonné : $topic');
  }

  // -------------------------------------------------------------------------
  // MQTT message handler
  // -------------------------------------------------------------------------

  void _onMessage(List<MqttReceivedMessage<MqttMessage>> events) {
    for (final event in events) {
      final publish = event.payload as MqttPublishMessage;
      final payload = MqttPublishPayload.bytesToStringAsString(
        publish.payload.message,
      );
      final msg = DomoticzMessage.tryParse(payload);
      if (msg != null) {
        debugPrint('[MQTT IN] idx=${msg.idx} name="${msg.name}" '
            'dtype="${msg.dtype}" stype="${msg.stype}" '
            'nvalue=${msg.nvalue} isSwitch=${msg.isSwitch} '
            'isKwhMeter=${msg.isKwhMeter} isSwitchOn=${msg.isSwitchOn}');
        _messages[msg.idx] = msg;
        if (msg.isKwhMeter) {
          final history = _histories.putIfAbsent(msg.idx, () => EnergyHistory(msg.idx));
          history.add(msg.powerWatts, msg.energyWh);
          history.saveToPrefs(); // fire-and-forget — non bloquant
        }
        if (msg.isSwitch) {
          _switchStates[msg.idx] = msg.isSwitchOn;
          _discoveredSwitches[msg.idx] = msg;          // auto-discover
          debugPrint('[MQTT IN] → switch state: idx=${msg.idx} on=${msg.isSwitchOn}');
        }
        // Forward every message to Kafka (fire-and-forget)
        _kafkaService?.publishMessage(msg.toJson());
        notifyListeners();
      }
    }
  }

  // -------------------------------------------------------------------------
  // Commands
  // -------------------------------------------------------------------------

  void _setStatus(MqttConnectionStatus status, String message) {
    _status = status;
    _statusMessage = message;
    notifyListeners();
  }

  /// Send getdeviceinfo for a range of idx values to discover all devices.
  /// Domoticz will reply on domoticz/out for each existing device.
  /// [from] and [to] are inclusive. Keep the range small (e.g. 1–30).
  void scanSwitches({int from = 1, int to = 30}) {
    for (var i = from; i <= to; i++) {
      _requestDeviceInfo(i);
    }
  }

  void publishSwitch(int idx, {required bool on}) {
    if (_client?.connectionStatus?.state != MqttConnectionState.connected) {
      debugPrint('[MQTT OUT] publishSwitch ignored — not connected');
      return;
    }
    final command = jsonEncode({
      'command': 'switchlight',
      'idx': idx,
      'switchcmd': on ? 'On' : 'Off',
    });
    debugPrint('[MQTT OUT] domoticz/in → $command');
    final builder = MqttClientPayloadBuilder()..addString(command);
    _client!.publishMessage(_topicIn, MqttQos.atMostOnce, builder.payload!);
    // Optimistic update until Domoticz confirms via domoticz/out
    _switchStates[idx] = on;
    notifyListeners();
  }

  void toggleSwitch(int idx) {
    publishSwitch(idx, on: !(_switchStates[idx] ?? false));
  }

  @override
  void dispose() {
    _client?.disconnect();
    super.dispose();
  }
}
