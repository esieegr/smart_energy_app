import 'dart:convert';

/// Represents a message published on the domoticz/out MQTT topic.
class DomoticzMessage {
  final int battery;
  final String lastUpdate;
  final int rssi;
  final String description;
  final String dtype;
  final String hwid;
  final String id;
  final int idx;
  final String name;
  final int nvalue;
  final String orgHwid;
  final String stype;
  /// svalue1: total energy consumed (Wh)
  final String svalue1;
  /// svalue2: current power (W)
  final String svalue2;
  final int unit;

  const DomoticzMessage({
    required this.battery,
    required this.lastUpdate,
    required this.rssi,
    required this.description,
    required this.dtype,
    required this.hwid,
    required this.id,
    required this.idx,
    required this.name,
    required this.nvalue,
    required this.orgHwid,
    required this.stype,
    required this.svalue1,
    required this.svalue2,
    required this.unit,
  });

  factory DomoticzMessage.fromJson(Map<String, dynamic> json) {
    return DomoticzMessage(
      battery: (json['Battery'] as num?)?.toInt() ?? 0,
      lastUpdate: json['LastUpdate'] as String? ?? '',
      rssi: (json['RSSI'] as num?)?.toInt() ?? 0,
      description: json['description'] as String? ?? '',
      dtype: json['dtype'] as String? ?? '',
      hwid: json['hwid'] as String? ?? '',
      id: json['id'] as String? ?? '',
      idx: (json['idx'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      nvalue: (json['nvalue'] as num?)?.toInt() ?? 0,
      orgHwid: json['org_hwid'] as String? ?? '',
      stype: json['stype'] as String? ?? '',
      svalue1: json['svalue1'] as String? ?? '0',
      svalue2: json['svalue2'] as String? ?? '0',
      unit: (json['unit'] as num?)?.toInt() ?? 0,
    );
  }

  static DomoticzMessage? tryParse(String payload) {
    try {
      final map = jsonDecode(payload) as Map<String, dynamic>;
      return DomoticzMessage.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  /// Energy consumed in Wh (svalue1)
  double get energyWh => double.tryParse(svalue1) ?? 0.0;

  /// Current power in Watts (svalue2)
  double get powerWatts => double.tryParse(svalue2) ?? 0.0;

  /// True if this device is a kWh energy meter (Type 243 / SubType 29)
  bool get isKwhMeter => stype == 'kWh';

  /// True if this device is a controllable switch (Type 244)
  bool get isSwitch => dtype == 'Light/Switch';

  /// For a switch: is it ON? (nvalue=1 means On)
  bool get isSwitchOn => nvalue == 1;

  /// Serialise back to JSON for forwarding to Kafka.
  Map<String, dynamic> toJson() => {
    'Battery'    : battery,
    'LastUpdate' : lastUpdate,
    'RSSI'       : rssi,
    'description': description,
    'dtype'      : dtype,
    'hwid'       : hwid,
    'id'         : id,
    'idx'        : idx,
    'name'       : name,
    'nvalue'     : nvalue,
    'org_hwid'   : orgHwid,
    'stype'      : stype,
    'svalue1'    : svalue1,
    'svalue2'    : svalue2,
    'unit'       : unit,
  };
}
