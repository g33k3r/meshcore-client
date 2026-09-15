import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

/// Deterministic xorshift32 — reproducible failures, CI-safe.
int _next(int s) {
  s ^= (s << 13) & 0xFFFFFFFF;
  s ^= (s >> 17);
  s ^= (s << 5) & 0xFFFFFFFF;
  return s & 0xFFFFFFFF;
}

void main() {
  group('BufferReader fuzz', () {
    test('every method survives seeded garbage and overreads', () {
      int seed = 0xBADF00D;
      for (var iter = 0; iter < 20000; iter++) {
        seed = _next(seed);
        final len = seed % 64;
        final data = Uint8List(len);
        for (var i = 0; i < len; i++) {
          seed = _next(seed);
          data[i] = seed >> 24;
        }
        final reader = BufferReader(data);
        // exercise the read surface against exhaustion
        for (var op = 0; op < 8; op++) {
          seed = _next(seed);
          try {
            switch (seed % 6) {
              case 0:
                reader.readByte();
              case 1:
                seed = _next(seed);
                reader.readBytes(seed % 40);
              case 2:
                reader.skipBytes(seed % 40);
              case 3:
                reader.readCStringGreedy(32);
              case 4:
                reader.readCString();
              case 5:
                seed = _next(seed);
                reader.readCString(maxLength: seed % 33);
            }
          } on RangeError {
            // expected on exhaustion — the contract
          } on Exception {
            rethrow; // anything else is a bug
          }
        }
      }
    });

    test('parseOffbandFemLnaReply survives hostile frames', () {
      int seed = 0xFEED5EED;
      for (var iter = 0; iter < 2000; iter++) {
        seed = _next(seed);
        final len = seed % 8;
        final data = Uint8List(len);
        for (var i = 0; i < len; i++) {
          seed = _next(seed);
          data[i] = seed >> 24;
        }
        final r = parseOffbandFemLnaReply(data);
        if (r != null) {
          expect(data.length, greaterThanOrEqualTo(3));
        }
      }
    });
  });
}
