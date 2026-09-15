import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart' show respCodeContact;

/// Builds a contact frame exactly as the g33k3r firmware's
/// writeContactRespFrame does, with the optional 3-byte path-quality tail.
Uint8List buildContactFrame({
  int respCode = 0x35, // any non-zero placeholder; test uses respCodeContact
  bool withTail = false,
  int snr4 = -24,
  bool altAvailable = true,
}) {
  final b = BytesBuilder();
  b.addByte(respCode);
  b.add(Uint8List.fromList(List.generate(32, (i) => 0x10 + i))); // pubkey
  b.addByte(1); // type
  b.addByte(0); // flags
  b.addByte(0x00); // out_path_len: 0 hops (direct)
  b.add(Uint8List(64)); // path
  b.add(Uint8List.fromList('Test Node'.codeUnits + List.filled(32 - 9, 0)));
  final ts = ByteData(4)..setUint32(0, 1700000000, Endian.little);
  b.add(ts.buffer.asUint8List()); // last_advert_timestamp
  final gps = ByteData(8); // zero lat/lon
  b.add(gps.buffer.asUint8List());
  final lastmod = ByteData(4)..setUint32(0, 1700000000, Endian.little);
  b.add(lastmod.buffer.asUint8List());
  if (withTail) {
    final tail = ByteData(3)..setInt16(0, snr4, Endian.little);
    tail.setUint8(2, altAvailable ? 0x01 : 0x00);
    b.add(tail.buffer.asUint8List());
  }
  return b.toBytes();
}

void main() {
  group('Contact.fromFrame path-quality tail (g33k3r dialect)', () {
    test('parses the 3-byte tail after the lastmod layout', () {
      final frame = buildContactFrame(respCode: respCodeContact, withTail: true, snr4: -24, altAvailable: true);
      final contact = Contact.fromFrame(frame);
      expect(contact, isNotNull);
      expect(contact!.pathQualitySnr4, -24);
      expect(contact.hasAltPath, isTrue);
      expect(contact.pathQualityDb, -6.0);
    });

    test('frames without the tail leave quality null (stock firmware)', () {
      final frame = buildContactFrame(respCode: respCodeContact, withTail: false);
      final contact = Contact.fromFrame(frame);
      expect(contact, isNotNull);
      expect(contact!.pathQualitySnr4, isNull);
      expect(contact.hasAltPath, isNull);
      expect(contact.pathQualityDb, isNull);
    });

    test('unmeasured sentinel maps to null dB', () {
      final frame = buildContactFrame(respCode: respCodeContact, withTail: true, snr4: -1000, altAvailable: false);
      final contact = Contact.fromFrame(frame);
      expect(contact!.pathQualitySnr4, -1000);
      expect(contact.pathQualityDb, isNull);
      expect(contact.hasAltPath, isFalse);
    });
  });
}
