// Hostile-frame fuzz harness for the connector dispatch surface.
//
// Every frame from every transport (BLE characteristic, USB serial, TCP) lands
// in _handleFrameInner with zero pre-validation — the first byte selects the
// handler and the handler trusts the rest. A malicious peer on the wire (or a
// corrupted radio link) therefore controls the full byte stream reaching ~40
// parsers. The firmware side got the same treatment (readFrom overread,
// updateContactFromFrame, radio/tuning guards); this is the client half.
//
// Contract: handleFrameForTest must never throw, synchronously or
// asynchronously, for ANY byte sequence. A hostile frame may desync app state
// (that is the app's problem to render sanely) but it must not crash the
// isolate or kill the transport subscription.
//
// Determinism: tails are generated from Random(code) / Random(1000 + code) so
// every failure is exactly reproducible by re-running with the same seed.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/connector/offband_device_ui.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every frame code the dispatcher recognizes, plus a few that fall through to
/// the default branch (must be no-ops).
const List<int> _knownCodes = [
  respCodeOk,
  respCodeErr,
  respCodeContactsStart,
  respCodeContact,
  respCodeEndOfContacts,
  respCodeSelfInfo,
  respCodeSent,
  respCodeContactMsgRecv,
  respCodeChannelMsgRecv,
  respCodeCurrTime,
  respCodeNoMoreMessages,
  respCodeExportContact,
  respCodeBattAndStorage,
  respCodeDeviceInfo,
  respCodeContactMsgRecvV3,
  respCodeChannelMsgRecvV3,
  respCodeChannelInfo,
  respCodeCustomVars,
  respCodeStats,
  respCodeAutoAddConfig,
  respCodeOffbandGps,
  cmdOffbandBlock,
  cmdOffbandFemLna,
  respCodeOffbandCaplog,
  cmdOffbandPktHash,
  pushCodeAdvert,
  pushCodePathUpdated,
  pushCodeSendConfirmed,
  pushCodeMsgWaiting,
  pushCodeLoginSuccess,
  pushCodeLoginFail,
  pushCodeStatusResponse,
  pushCodeLogRxData,
  pushCodeNewAdvert,
  pushCodeTelemetryResponse,
  respCodeOffbandDeviceUi,
  pushCodeChannelsChanged,
  // respCodeOffbandDeviceUi and any future codes ride the random sweep too.
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  // Errors that are not hostile-frame findings:
  // - "Not connected" StateErrors: handlers legitimately react to pushes by
  //   issuing follow-up requests; with no transport attached (test fixture)
  //   those throw by design. On a real device the hostile peer IS the
  //   transport, so this path cannot fire from frame input alone.
  // - MissingPluginException: path_provider/sqflite/etc. have no platform
  //   implementation in unit tests; on-device they exist.
  bool isEnvNoise(Object e) =>
      e.toString().contains('Not connected to a MeshCore device') ||
      e.toString().contains('MissingPluginException');

  Future<List<String>> sweepCode(int code) async {
    final connector = MeshCoreConnector();
    final failures = <String>[];
    final zoneErrors = <Object>[];

    // Three hostile tails: pseudorandom (two seeds), all-0x00 (zero lengths),
    // all-0xFF (maximal length fields / negative int8s).
    final tails = <String, List<int>>{
      'rand-a': List<int>.generate(96, (_) => Random(code).nextInt(256)),
      'rand-b': List<int>.generate(96, (_) => Random(1000 + code).nextInt(256)),
      'ff': List<int>.filled(96, 0xFF),
      'zero': List<int>.filled(96, 0x00),
    };

    for (final entry in tails.entries) {
      for (var len = 1; len <= 96; len++) {
        final frame = <int>[code, ...entry.value.take(len - 1)];
        await runZonedGuarded(() {
          connector.handleFrameForTest(frame);
        }, (e, st) => zoneErrors.add(e));
        // Drain microtasks + short timers so async fallout from unawaited()
        // handlers is attributed to this frame, not a later test.
        await Future<void>.delayed(Duration.zero);
      }
    }

    failures.addAll(
      zoneErrors.where((e) => !isEnvNoise(e)).map((e) => 'async: $e'),
    );
    return failures;
  }

  group('connector frame fuzz — truncation sweep', () {
    for (final code in _knownCodes) {
      test('code 0x${code.toRadixString(16).padLeft(2, '0')} survives hostile frames', () async {
        final failures = await sweepCode(code);
        expect(
          failures,
          isEmpty,
          reason: failures.take(5).join('\n'),
        );
      });
    }
  });

  test('unknown codes are inert no-ops', () async {
    final connector = MeshCoreConnector();
    final zoneErrors = <Object>[];
    final rng = Random(7);
    for (final code in [0x7F, 0x90, 0xFE, 0xFF, 42, 200]) {
      for (var i = 0; i < 50; i++) {
        final frame = List<int>.generate(1 + rng.nextInt(64), (_) => rng.nextInt(256));
        frame[0] = code;
        await runZonedGuarded(() {
          connector.handleFrameForTest(frame);
        }, (e, st) => zoneErrors.add(e));
        await Future<void>.delayed(Duration.zero);
      }
    }
    final real = zoneErrors.where((e) => !isEnvNoise(e)).toList();
    expect(real, isEmpty, reason: real.take(5).map((e) => '$e').join('\n'));
  });

  test('seeded garbage sweep across all codes', () async {
    final connector = MeshCoreConnector();
    final zoneErrors = <Object>[];
    final rng = Random(1337);
    // 20k frames: random code (skewing to dispatched ones), random length,
    // random bytes. Reproducible via seed 1337.
    for (var i = 0; i < 20000; i++) {
      final code = i % 3 == 0
          ? _knownCodes[rng.nextInt(_knownCodes.length)]
          : rng.nextInt(256);
      final frame = List<int>.generate(1 + rng.nextInt(160), (_) => rng.nextInt(256));
      frame[0] = code;
      await runZonedGuarded(() {
        connector.handleFrameForTest(frame);
      }, (e, st) => zoneErrors.add(e));
      if (i % 500 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // Only genuine hostile-frame findings count; env noise is filtered. Any
    // survivor is a crash a malicious BLE peer can trigger on a real phone.
    final real = zoneErrors.where((e) => !isEnvNoise(e)).toList();
    expect(real, isEmpty, reason: real.take(10).map((e) => '$e').join('\n'));
  });

  group('connector frame fuzz — primed (connected-state) sweep', () {
    // A bare connector short-circuits deep paths (_selfPublicKey == null,
    // empty contacts). A hostile peer on a real phone talks to a PRIMED
    // connector — self info known, contacts loaded — so that's the state the
    // fuzz must drive. Primers are minimal VALID frames; the fuzz is what
    // follows them.
    final selfKey = List<int>.generate(32, (i) => 0x40 + i);
    final peerKey = List<int>.generate(32, (i) => 0x10 + i);

    Uint8List selfInfoFrame() {
      final b = <int>[
        respCodeSelfInfo,
        1, // adv type
        20, // tx power
        20, // max tx
        ...selfKey,
        ..._u32(0), // lat
        ..._u32(0), // lon
        1, // multi acks
        0, // loc policy
        0, // telemetry
        0, // manual add
        ..._u32(910250), // freq
        ..._u32(500000), // bw
        10, // sf
        5, // cr
        ...'fuzz-self'.codeUnits,
        0,
      ];
      return Uint8List.fromList(b);
    }

    Uint8List contactFrame() {
      final nameField = List<int>.filled(maxNameSize, 0);
      final name = 'fuzz-peer'.codeUnits;
      nameField.setRange(0, name.length, name);
      final b = <int>[
        respCodeContact,
        ...peerKey,
        1, // type
        0, // flags
        0x00, // pathLen: 0 hops
        ...List<int>.filled(maxPathSize, 0), // path window (sliced to 0)
        ...nameField, // full 32-byte name window (readCStringGreedy)
        ..._u32(1000), // last advert timestamp
      ];
      return Uint8List.fromList(b);
    }

    /// Minimal VALID sync: CONTACTS_START → CONTACT → END_OF_CONTACTS.
    void primeContacts(MeshCoreConnector connector) {
      connector.handleFrameForTest([respCodeContactsStart]);
      connector.handleFrameForTest(contactFrame());
      connector.handleFrameForTest([respCodeEndOfContacts]);
    }

    test('primed state is actually reached (harness self-check)', () async {
      final connector = MeshCoreConnector();
      connector.handleFrameForTest(selfInfoFrame());
      primeContacts(connector);
      expect(connector.contactsForTest, isNotEmpty,
          reason: 'contact primer did not land — fuzz would be vacuous');
    });

    test('targeted known-contact DM fuzz (deep message path)', () async {
      final connector = MeshCoreConnector();
      connector.handleFrameForTest(selfInfoFrame());
      primeContacts(connector);
      final zoneErrors = <Object>[];
      final prefix = peerKey.take(6).toList();
      final rng = Random(99);
      // [7|16][prefix x6][garbage...] — the shape a hostile radio uses to
      // reach the message-content parser for a KNOWN contact. Full
      // truncation sweep plus random tails.
      for (final code in [respCodeContactMsgRecv, respCodeContactMsgRecvV3]) {
        for (var tail = 0; tail <= 96; tail++) {
          final frame = <int>[
            code,
            ...prefix,
            ...List<int>.generate(tail, (_) => rng.nextInt(256)),
          ];
          await runZonedGuarded(() {
            connector.handleFrameForTest(frame);
          }, (e, st) => zoneErrors.add(e));
          await Future<void>.delayed(Duration.zero);
        }
        for (var i = 0; i < 3000; i++) {
          final frame = <int>[
            code,
            ...prefix,
            ...List<int>.generate(rng.nextInt(90), (_) => rng.nextInt(256)),
          ];
          await runZonedGuarded(() {
            connector.handleFrameForTest(frame);
          }, (e, st) => zoneErrors.add(e));
          if (i % 250 == 0) await Future<void>.delayed(Duration.zero);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final real = zoneErrors.where((e) => !isEnvNoise(e)).toList();
      expect(real, isEmpty,
          reason: real.take(10).map((e) => '$e').join('\n'));
    });

    test('targeted known-contact channel-message fuzz', () async {
      final connector = MeshCoreConnector();
      connector.handleFrameForTest(selfInfoFrame());
      primeContacts(connector);
      final zoneErrors = <Object>[];
      final rng = Random(101);
      for (final code in [respCodeChannelMsgRecv, respCodeChannelMsgRecvV3]) {
        for (var i = 0; i < 3000; i++) {
          final frame = <int>[
            code,
            ...List<int>.generate(rng.nextInt(120), (_) => rng.nextInt(256)),
          ];
          await runZonedGuarded(() {
            connector.handleFrameForTest(frame);
          }, (e, st) => zoneErrors.add(e));
          if (i % 250 == 0) await Future<void>.delayed(Duration.zero);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final real = zoneErrors.where((e) => !isEnvNoise(e)).toList();
      expect(real, isEmpty,
          reason: real.take(10).map((e) => '$e').join('\n'));
    });

    test('primed full garbage sweep', () async {
      final connector = MeshCoreConnector();
      connector.handleFrameForTest(selfInfoFrame());
      primeContacts(connector);
      final zoneErrors = <Object>[];
      final rng = Random(4242);
      for (var i = 0; i < 20000; i++) {
        final code = i % 3 == 0
            ? _knownCodes[rng.nextInt(_knownCodes.length)]
            : rng.nextInt(256);
        final frame = List<int>.generate(1 + rng.nextInt(160), (_) => rng.nextInt(256));
        frame[0] = code;
        await runZonedGuarded(() {
          connector.handleFrameForTest(frame);
        }, (e, st) => zoneErrors.add(e));
        if (i % 500 == 0) await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final real = zoneErrors.where((e) => !isEnvNoise(e)).toList();
      expect(real, isEmpty,
          reason: real.take(10).map((e) => '$e').join('\n'));
    });
  });
}

List<int> _u32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
