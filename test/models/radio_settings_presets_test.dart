import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/radio_settings.dart';

void main() {
  group('US frequency presets', () {
    test('USA Regulatory matches the FCC 15.247(a)(2)-aligned community setting', () {
      final preset = RadioSettings.presets.firstWhere((p) => p.$1 == 'USA Regulatory');
      final r = preset.$2;
      expect(r.frequencyMHz, 910.25);
      expect(r.bandwidth, LoRaBandwidth.bw500);
      expect(r.spreadingFactor, LoRaSpreadingFactor.sf10);
      expect(r.codingRate, LoRaCodingRate.cr4_5);
    });

    test('USA SoCal matches issue #1798 (927.875 / BW62.5 / SF7 / CR8)', () {
      final preset = RadioSettings.presets.firstWhere((p) => p.$1 == 'USA SoCal');
      final r = preset.$2;
      expect(r.frequencyMHz, 927.875);
      expect(r.bandwidth, LoRaBandwidth.bw62_5);
      expect(r.spreadingFactor, LoRaSpreadingFactor.sf7);
      expect(r.codingRate, LoRaCodingRate.cr4_8);
    });

    test('presets are uniquely named', () {
      final names = RadioSettings.presets.map((p) => p.$1).toList();
      expect(names.toSet().length, names.length);
    });
  });
}
