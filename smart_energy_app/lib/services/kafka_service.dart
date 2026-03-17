import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences keys for Kafka settings
const _kKafkaBrokerIp   = 'kafka_broker_ip';
const _kKafkaBrokerPort = 'kafka_broker_port'; // REST Proxy port (default 8082)
const _kKafkaTopic      = 'kafka_topic';        // target topic name

/// Status of the Kafka REST Proxy connection.
enum KafkaStatus { disabled, idle, publishing, error }

/// Forwards Domoticz messages to a Kafka topic via the Confluent REST Proxy.
///
/// Architecture (Raspberry Pi):
///   Flutter app --HTTP POST--&gt; Confluent REST Proxy (:8082)
///                                      |
///                               Kafka broker (:9092)
///
/// REST Proxy endpoint used:
///   POST http://&lt;host&gt;:&lt;port&gt;/topics/&lt;topic&gt;
///   Content-Type: application/vnd.kafka.json.v2+json
///   Body: { "records": [ { "value": { ...domoticz message... } } ] }
class KafkaService extends ChangeNotifier {
  static const int    _defaultPort  = 8082;
  static const String _defaultTopic = 'domoticz-events';

  String _brokerIp = '';
  int    _port     = _defaultPort;
  String _topic    = _defaultTopic;

  KafkaStatus _status        = KafkaStatus.disabled;
  String      _statusMessage = 'Kafka désactivé';

  int    _publishedCount = 0;
  int    _errorCount     = 0;
  String _lastError      = '';

  // ── Getters ────────────────────────────────────────────────────────────────
  String      get brokerIp       => _brokerIp;
  int         get port           => _port;
  String      get topic          => _topic;
  KafkaStatus get status         => _status;
  String      get statusMessage  => _statusMessage;
  int         get publishedCount => _publishedCount;
  int         get errorCount     => _errorCount;
  String      get lastError      => _lastError;

  /// True if a broker IP is configured (Kafka integration is active).
  bool get isEnabled => _brokerIp.isNotEmpty;

  String get _baseUrl => 'http://$_brokerIp:$_port';

  // ── Configuration ──────────────────────────────────────────────────────────

  /// Load saved settings from SharedPreferences.
  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _brokerIp = prefs.getString(_kKafkaBrokerIp) ?? '';
    _port     = prefs.getInt(_kKafkaBrokerPort)  ?? _defaultPort;
    _topic    = prefs.getString(_kKafkaTopic)    ?? _defaultTopic;
    if (_brokerIp.isNotEmpty) {
      _status        = KafkaStatus.idle;
      _statusMessage = 'Kafka configuré ($_brokerIp:$_port → $_topic)';
    } else {
      _status        = KafkaStatus.disabled;
      _statusMessage = 'Kafka désactivé';
    }
    notifyListeners();
    debugPrint('[KAFKA] Settings loaded — ip=$_brokerIp port=$_port topic=$_topic');
  }

  /// Save Kafka settings and reload.
  Future<void> saveSettings({
    required String brokerIp,
    required int    port,
    required String topic,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKafkaBrokerIp,  brokerIp.trim());
    await prefs.setInt(_kKafkaBrokerPort,    port);
    await prefs.setString(_kKafkaTopic,      topic.trim());
    await loadSettings();
  }

  /// Disable Kafka and clear all stored settings.
  Future<void> clearSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kKafkaBrokerIp);
    await prefs.remove(_kKafkaBrokerPort);
    await prefs.remove(_kKafkaTopic);
    _brokerIp      = '';
    _port          = _defaultPort;
    _topic         = _defaultTopic;
    _status        = KafkaStatus.disabled;
    _statusMessage = 'Kafka désactivé';
    notifyListeners();
  }

  // ── Test connection ─────────────────────────────────────────────────────────

  /// Calls GET /topics on the REST Proxy to verify connectivity.
  /// Returns null on success, or an error message on failure.
  Future<String?> testConnection() async {
    if (!isEnabled) return 'Aucun broker configuré';
    try {
      final uri = Uri.parse('$_baseUrl/topics');
      debugPrint('[KAFKA] Testing connection: GET $uri');
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        debugPrint('[KAFKA] Connection OK');
        return null; // success
      }
      return 'REST Proxy a répondu ${response.statusCode}';
    } on TimeoutException {
      return 'Timeout (5s) — vérifier IP/port du REST Proxy';
    } catch (e) {
      return 'Erreur réseau: $e';
    }
  }

  // ── Publish ────────────────────────────────────────────────────────────────

  /// Publish one Domoticz message (as JSON map) to the configured Kafka topic.
  Future<void> publishMessage(Map<String, dynamic> messageJson) async {
    if (!isEnabled) return;

    _status        = KafkaStatus.publishing;
    _statusMessage = 'Publication en cours…';
    notifyListeners();

    final uri  = Uri.parse('$_baseUrl/topics/$_topic');
    final body = jsonEncode({
      'records': [
        {'value': messageJson},
      ],
    });

    debugPrint('[KAFKA OUT] → idx=${messageJson['idx']} '
        '"${messageJson['name']}" (${messageJson['stype']})');

    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/vnd.kafka.json.v2+json',
              'Accept':       'application/vnd.kafka.v2+json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200 || response.statusCode == 201) {
        _publishedCount++;
        _status        = KafkaStatus.idle;
        _statusMessage = '$_publishedCount messages publiés';
        _lastError     = '';
        debugPrint('[KAFKA OK] total published: $_publishedCount');
      } else {
        _handleError('REST Proxy ${response.statusCode}: ${response.body}');
      }
    } on TimeoutException {
      _handleError('Timeout lors de la publication');
    } catch (e) {
      _handleError('Erreur HTTP: $e');
    }

    notifyListeners();
  }

  void _handleError(String message) {
    _errorCount++;
    _lastError     = message;
    _status        = KafkaStatus.error;
    _statusMessage = 'Erreur Kafka: $message';
    debugPrint('[KAFKA ERROR] $message (total: $_errorCount)');
  }

  String get summary {
    if (!isEnabled) return 'Kafka : non configuré';
    return '$_brokerIp:$_port → $_topic  '
        '(✓ $_publishedCount  ✗ $_errorCount)';
  }
}
