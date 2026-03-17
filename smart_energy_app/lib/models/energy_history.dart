/// One recorded data point for the energy chart.
class EnergyPoint {
  final DateTime time;
  final double powerWatts;
  final double energyWh;

  const EnergyPoint({
    required this.time,
    required this.powerWatts,
    required this.energyWh,
  });
}

/// Keeps the last [maxPoints] readings for a single device.
class EnergyHistory {
  static const int maxPoints = 50;

  final int idx;
  final List<EnergyPoint> _points = [];

  EnergyHistory(this.idx);

  List<EnergyPoint> get points => List.unmodifiable(_points);

  void add(double powerWatts, double energyWh) {
    _points.add(EnergyPoint(
      time: DateTime.now(),
      powerWatts: powerWatts,
      energyWh: energyWh,
    ));
    if (_points.length > maxPoints) {
      _points.removeAt(0);
    }
  }

  double get maxEnergy =>
      _points.isEmpty ? 1 : _points.map((p) => p.energyWh).reduce((a, b) => a > b ? a : b);

  double get minEnergy =>
      _points.isEmpty ? 0 : _points.map((p) => p.energyWh).reduce((a, b) => a < b ? a : b);

  double get maxPower =>
      _points.isEmpty ? 1 : _points.map((p) => p.powerWatts).reduce((a, b) => a > b ? a : b);
}
