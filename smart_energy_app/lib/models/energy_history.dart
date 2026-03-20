import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

// ── Fenêtre temporelle sélectionnable ────────────────────────────────────────

enum HistoryWindow {
  h24('24 h',   Duration(hours: 24)),
  d7 ('7 j',    Duration(days: 7)),
  d30('30 j',   Duration(days: 30)),
  all('Tout',   Duration(days: 36500)); // ~100 ans = tout garder

  final String label;
  final Duration duration;
  const HistoryWindow(this.label, this.duration);
}

// ── Point de mesure ───────────────────────────────────────────────────────────

class EnergyPoint {
  final DateTime time;
  final double powerWatts;
  final double energyWh;

  const EnergyPoint({
    required this.time,
    required this.powerWatts,
    required this.energyWh,
  });

  Map<String, dynamic> toJson() => {
    't': time.millisecondsSinceEpoch,
    'p': powerWatts,
    'e': energyWh,
  };

  factory EnergyPoint.fromJson(Map<String, dynamic> j) => EnergyPoint(
    time:        DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
    powerWatts:  (j['p'] as num).toDouble(),
    energyWh:    (j['e'] as num).toDouble(),
  );
}

// ── Historique persistant par appareil ───────────────────────────────────────

class EnergyHistory {
  /// Durée maximale conservée (30 jours). Les points plus anciens sont purgés.
  static const Duration maxAge     = Duration(days: 30);

  /// Nombre maximal de points toutes périodes confondues (protège la mémoire).
  static const int      maxPoints  = 5000;

  final int idx;
  final List<EnergyPoint> _points = [];

  EnergyHistory(this.idx);

  // ── Lecture ──────────────────────────────────────────────────────────────

  List<EnergyPoint> get points => List.unmodifiable(_points);

  /// Renvoie les points compris dans la fenêtre temporelle [window].
  List<EnergyPoint> getPointsForWindow(HistoryWindow window) {
    if (window == HistoryWindow.all) return points;
    final cutoff = DateTime.now().subtract(window.duration);
    return _points.where((p) => p.time.isAfter(cutoff)).toList();
  }

  // ── Ajout ────────────────────────────────────────────────────────────────

  void add(double powerWatts, double energyWh) {
    _points.add(EnergyPoint(
      time:       DateTime.now(),
      powerWatts: powerWatts,
      energyWh:   energyWh,
    ));
    _prune();
  }

  /// Supprime les points trop anciens et plafonne à [maxPoints].
  void _prune() {
    final cutoff = DateTime.now().subtract(maxAge);
    _points.removeWhere((p) => p.time.isBefore(cutoff));
    while (_points.length > maxPoints) {
      _points.removeAt(0);
    }
  }

  // ── Statistiques ─────────────────────────────────────────────────────────

  double _maxOf(List<EnergyPoint> pts, double Function(EnergyPoint) f, double fallback) =>
      pts.isEmpty ? fallback : pts.map(f).reduce((a, b) => a > b ? a : b);

  double _minOf(List<EnergyPoint> pts, double Function(EnergyPoint) f, double fallback) =>
      pts.isEmpty ? fallback : pts.map(f).reduce((a, b) => a < b ? a : b);

  double maxEnergyFor(HistoryWindow w) => _maxOf(getPointsForWindow(w), (p) => p.energyWh, 1);
  double minEnergyFor(HistoryWindow w) => _minOf(getPointsForWindow(w), (p) => p.energyWh, 0);
  double maxPowerFor (HistoryWindow w) => _maxOf(getPointsForWindow(w), (p) => p.powerWatts, 1);

  // Compat avec l'ancien code (fenêtre = tout)
  double get maxEnergy => maxEnergyFor(HistoryWindow.all);
  double get minEnergy => minEnergyFor(HistoryWindow.all);
  double get maxPower  => maxPowerFor (HistoryWindow.all);

  // ── Persistence SharedPreferences ────────────────────────────────────────

  static String _key(int idx) => 'history_$idx';

  Future<void> saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_points.map((p) => p.toJson()).toList());
    await prefs.setString(_key(idx), encoded);
  }

  Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(idx));
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _points.clear();
      _points.addAll(
        list.map((e) => EnergyPoint.fromJson(e as Map<String, dynamic>)),
      );
      _prune(); // supprimer les points expirés au chargement
    } catch (_) {
      // Données corrompues → on repart de zéro
      _points.clear();
    }
  }
}
