import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart' show respCodeContact, pushCodeNewAdvert;

/// Deterministic xorshift32 — reproducible failures, CI-safe.
int _next(int s) {
  s ^= (s << 13) & 0xFFFFFFFF;
  s ^= (s >> 17);
  s ^= (s << 5) & 0xFFFFFFFF;
  return s & 0xFFFFFFFF;
}

void main() {
  group('Contact.fromFrame fuzz', () {
    test('valid prefix + garbage tails never throw', () {
      int seed = 0xC0FFEE;
      for (var iter = 0; iter < 5000; iter++) {
        seed = _next(seed);
        final b = BytesBuilder();
        b.addByte(respCodeContact);
        b.add(Uint8List.fromList(List.generate(32, (i) {
          seed = _next(seed);
          return seed >> 24;
        })));
        b.addByte(1); // type
        b.addByte(0); // flags
        seed = _next(seed);
        b.addByte(seed >> 24); // arbitrary path_len byte
        b.add(Uint8List(64)); // path
        b.add(Uint8List(32)); // name
        b.add(Uint8List(24)); // timestamp + gps + lastmod region
        seed = _next(seed);
        final tailLen = seed % 6;
        for (var i = 0; i < tailLen; i++) {
          seed = _next(seed);
          b.addByte(seed >> 24);
        }
        final contact = Contact.fromFrame(b.toBytes());
        if (contact != null) {
          expect(contact.pathLength, lessThan(64));
        }
      }
    });

    test('truncation at every offset of a valid frame never throws', () {
      final b = BytesBuilder();
      b.addByte(respCodeContact);
      b.add(Uint8List.fromList(List.generate(32, (i) => 0x20 + i)));
      b.addByte(1);
      b.addByte(0);
      b.addByte(0x00);
      b.add(Uint8List(64));
      b.add(Uint8List.fromList('Fuzz Node'.codeUnits + List.filled(32 - 9, 0)));
      final ts = ByteData(4)..setUint32(0, 1700000000, Endian.little);
      b.add(ts.buffer.asUint8List());
      b.add(Uint8List(8));
      final lastmod = ByteData(4)..setUint32(0, 1700000000, Endian.little);
      b.add(lastmod.buffer.asUint8List());
      final tail = ByteData(3)..setInt16(0, -24, Endian.little);
      tail.setUint8(2, 0x01);
      b.add(tail.buffer.asUint8List());
      final frame = b.toBytes();

      for (var cut = 0; cut <= frame.length; cut++) {
        final contact = Contact.fromFrame(
          Uint8List.fromList(frame.sublist(0, cut)),
        );
        if (contact != null) {
          expect(contact.pathLength, lessThan(64));
        }
      }
    });

    test('zeroed and hostile public keys are rejected, not parsed', () {
      final b = BytesBuilder();
      b.addByte(respCodeContact);
      b.add(Uint8List(32)); // all-zero pubkey
      b.addByte(1);
      b.addByte(0);
      b.addByte(0);
      b.add(Uint8List(64 + 32 + 24));
      expect(Contact.fromFrame(b.toBytes()), isNull);
    });
  });
}
