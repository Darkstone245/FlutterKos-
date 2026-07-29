class localParams {
  double trip;
  String deviceName;
  int LP_Error;
  localParams(this.LP_Error) : trip = 0, deviceName = '';
}

localParams assignJSON_LP(Map<String, dynamic> mapJSON, localParams LP) {
  LP.deviceName = mapJSON['deviceName'] as String? ?? '';
  LP.trip = double.tryParse(mapJSON['trip'].toString()) ?? 0;

  return LP;
}

Map<String, dynamic> assignMap_LP(Map<String, dynamic> mapJSON, localParams LP) {
  mapJSON['deviceName'] = LP.deviceName;
  mapJSON['trip'] = LP.trip.toStringAsFixed(1);

  return mapJSON;
}
