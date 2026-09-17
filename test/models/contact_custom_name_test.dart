import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/contact.dart';

Contact _contact({String? customName}) {
  final key = Uint8List(32);
  for (var i = 0; i < key.length; i++) {
    key[i] = i;
  }
  return Contact(
    publicKey: key,
    name: 'Advertised Name',
    type: 0,
    pathLength: -1,
    path: Uint8List(0),
    customName: customName,
    lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
    lastMessageAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

void main() {
  group('Contact custom display name', () {
    test('displayName falls back to advertised name when unset', () {
      final c = _contact();
      expect(c.displayName, 'Advertised Name');
    });

    test('displayName prefers custom name', () {
      final c = _contact(customName: 'Gem');
      expect(c.displayName, 'Gem');
      expect(c.name, 'Advertised Name'); // advertised name untouched
    });

    test('blank/whitespace custom name counts as unset', () {
      expect(_contact(customName: '').displayName, 'Advertised Name');
      expect(_contact(customName: '   ').displayName, 'Advertised Name');
    });

    test('displayName trims surrounding whitespace', () {
      expect(_contact(customName: '  Gem  ').displayName, 'Gem');
    });

    test('copyWith preserves custom name when untouched', () {
      final c = _contact(customName: 'Gem');
      final refreshed = c.copyWith(
        pathLength: 0,
        path: Uint8List.fromList([0xAB]),
      );
      expect(refreshed.customName, 'Gem');
      expect(refreshed.displayName, 'Gem');
    });

    test('copyWith clears custom name on request', () {
      final c = _contact(customName: 'Gem');
      final cleared = c.copyWith(clearCustomName: true);
      expect(cleared.customName, isNull);
      expect(cleared.displayName, 'Advertised Name');
    });

    test('device refresh preserves custom name (advertised name changes ok)',
        () {
      final existing = _contact(customName: 'Gem');
      // Simulate the connector's refresh merge: incoming contact carries a new
      // advertised name and NO customName — preservation is copyWith-injective.
      final refreshed = existing.copyWith(
        name: 'New Advertised Name',
        customName: existing.customName,
      );
      expect(refreshed.name, 'New Advertised Name');
      expect(refreshed.displayName, 'Gem');
    });
  });
}
