// Signal Log — GeekCore field-test lens. Unit + integration tests.
//
// 1. Service semantics: record/coalesce/ring-cap/clear, newest-first reads.
// 2. Pure chart prep: window filter, normalization, flat-line padding,
//    alt-route marker extraction.
// 3. Connector integration: a primed connector fed a v3 message frame with
//    SNR/RSSI must land a sample for the known contact (the exact path
//    tomorrow's hardware validation exercises).
// 4. Sheet smoke: renders with live data.

import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/services/signal_log_service.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/widgets/signal_log_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    // In-memory drift so message persistence doesn't hit path_provider.
    BlobStore.overrideForTest(BlobStore(OffbandDatabase(NativeDatabase.memory())));
  });

  tearDown(() {
    BlobStore.clearTestOverride();
  });

  group('SignalLogService', () {
    test('records and reads newest-first', () {
      final svc = SignalLogService();
      final t0 = DateTime(2026, 9, 16, 12, 0, 0);
      svc.record('k', snrDb: -7.5, now: t0);
      svc.record('k', snrDb: -9.0, now: t0.add(const Duration(seconds: 10)));
      final samples = svc.samplesFor('k');
      expect(samples.length, 2);
      expect(samples.first.snrDb, -9.0);
      expect(samples.last.snrDb, -7.5);
    });

    test('coalesces identical samples within the window', () {
      final svc = SignalLogService();
      final t0 = DateTime(2026, 9, 16, 12, 0, 0);
      svc.record('k', snrDb: -7.5, rssiDbm: -80, hopCount: 1, now: t0);
      svc.record('k', snrDb: -7.6, rssiDbm: -80, hopCount: 1,
          now: t0.add(const Duration(seconds: 2))); // rounds to same -7.5
      expect(svc.samplesFor('k').length, 1);

      // Same values but outside the window: kept.
      svc.record('k', snrDb: -7.5, rssiDbm: -80, hopCount: 1,
          now: t0.add(const Duration(seconds: 4)));
      expect(svc.samplesFor('k').length, 2);

      // Different value inside the window: kept.
      svc.record('k', snrDb: -12.0, rssiDbm: -80, hopCount: 1,
          now: t0.add(const Duration(seconds: 5)));
      expect(svc.samplesFor('k').length, 3);
    });

    test('ring-caps at maxSamplesPerContact', () {
      final svc = SignalLogService(maxSamplesPerContact: 5);
      final t0 = DateTime(2026, 9, 16, 12, 0, 0);
      for (var i = 0; i < 20; i++) {
        svc.record('k', snrDb: -10.0 - i,
            now: t0.add(Duration(seconds: 10 * i)));
      }
      final samples = svc.samplesFor('k');
      expect(samples.length, 5);
      expect(samples.first.snrDb, -29.0); // newest kept
      expect(samples.last.snrDb, -25.0); // oldest retained
    });

    test('clear removes only the target contact', () {
      final svc = SignalLogService();
      final t0 = DateTime(2026, 9, 16, 12, 0, 0);
      svc.record('a', snrDb: -1, now: t0);
      svc.record('b', snrDb: -2, now: t0);
      svc.clear('a');
      expect(svc.samplesFor('a'), isEmpty);
      expect(svc.samplesFor('b'), isNotEmpty);
    });
  });

  group('chart prep', () {
    final t0 = DateTime(2026, 9, 16, 12, 0, 0);

    test('chartSeries normalizes x/y and orders oldest→newest', () {
      final samples = [
        SignalSample(ts: t0.add(const Duration(minutes: 10)), snrDb: -5.0),
        SignalSample(ts: t0, snrDb: -15.0),
        SignalSample(ts: t0.add(const Duration(minutes: 5)), snrDb: -10.0),
        SignalSample(ts: t0.add(const Duration(minutes: 3)), snrDb: null,
            usedAltRoute: true), // route marker: excluded from series
      ];
      final series = SignalLogService.chartSeries(
        samples,
        window: const Duration(minutes: 15),
        now: t0.add(const Duration(minutes: 15)),
      );
      expect(series.length, 3);
      expect(series.first.x, 0.0); // oldest at x=0
      expect(series.last.x, closeTo(10 / 15, 1e-9));
      expect(series.first.y, 0.0); // weakest at y=0
      final strongest = series.reduce((a, b) => a.snrDb > b.snrDb ? a : b);
      expect(strongest.y, 1.0);
      // Monotone x.
      for (var i = 1; i < series.length; i++) {
        expect(series[i].x >= series[i - 1].x, isTrue);
      }
    });

    test('chartSeries pads a flat line so it does not collapse', () {
      final samples = [
        SignalSample(ts: t0, snrDb: -7.0),
        SignalSample(ts: t0.add(const Duration(minutes: 5)), snrDb: -7.0),
      ];
      final series = SignalLogService.chartSeries(
        samples,
        window: const Duration(minutes: 15),
        now: t0.add(const Duration(minutes: 15)),
      );
      expect(series.length, 2);
      // With ±1 dB padding around a flat -7, points sit mid-chart.
      expect(series.first.y, 0.5);
      expect(series.last.y, 0.5);
    });

    test('altMarkers only include alt-route sends inside the window', () {
      final samples = [
        SignalSample(ts: t0, usedAltRoute: true),
        SignalSample(ts: t0.add(const Duration(minutes: 2)), usedAltRoute: false),
        SignalSample(ts: t0.add(const Duration(minutes: 4)), usedAltRoute: true),
        SignalSample(ts: t0.add(const Duration(hours: 2)), usedAltRoute: true),
      ];
      final now = t0.add(const Duration(minutes: 10));
      final markers = SignalLogService.altMarkers(
        samples,
        window: const Duration(minutes: 10),
        now: now,
      );
      expect(markers.length, 2);
      expect(markers.first, 0.0);
      expect(markers.last, closeTo(0.4, 1e-9));
    });
  });

  group('connector integration', () {
    final peerKey = List<int>.generate(32, (i) => 0x10 + i);
    final selfKey = List<int>.generate(32, (i) => 0x40 + i);
    late Uint8List contactFrame;

    Uint8List selfInfoFrame() => Uint8List.fromList([
          respCodeSelfInfo,
          1,
          20,
          20,
          ...selfKey,
          ..._u32(0),
          ..._u32(0),
          1,
          0,
          0,
          0,
          ..._u32(910250),
          ..._u32(500000),
          10,
          5,
          ...'sig-self'.codeUnits,
          0,
        ]);

    setUpAll(() {
      final nameField = List<int>.filled(maxNameSize, 0);
      final name = 'sig-peer'.codeUnits;
      nameField.setRange(0, name.length, name);
      contactFrame = Uint8List.fromList([
        respCodeContact,
        ...peerKey,
        1,
        0,
        0x00,
        ...List<int>.filled(maxPathSize, 0),
        ...nameField,
        ..._u32(1000),
      ]);
    });

    test('incoming v3 message with SNR/RSSI lands a sample', () async {
      final connector = MeshCoreConnector();
      final svc = SignalLogService();
      connector.initialize(
        retryService: MessageRetryService(),
        pathHistoryService: PathHistoryService(StorageService()),
        signalLogService: svc,
      );
      connector.handleFrameForTest(selfInfoFrame());
      connector.handleFrameForTest([respCodeContactsStart]);
      connector.handleFrameForTest(contactFrame);
      connector.handleFrameForTest([respCodeEndOfContacts]);
      expect(connector.contactsForTest, isNotEmpty,
          reason: 'primer contact must land first');

      // v3 message: [16][snr int8 = snr_dB*4][res1 flags][res2 rssi int8]
      // [prefix x6][path_len][txt_type][timestamp u32][text...]
      final snrByte = (-6.5 * 4).round(); // -26 → int8 0xE6
      final rssiByte = -60 & 0xFF; // 0xC4
      final frame = Uint8List.fromList([
        respCodeContactMsgRecvV3,
        snrByte & 0xFF,
        0x00, // res1: not outgoing
        rssiByte,
        ...peerKey.take(6),
        0xFF, // direct (flood sentinel)
        txtTypePlain,
        ..._u32(1700000000),
        ...'ping'.codeUnits,
      ]);
      await runZonedGuarded(() {
        connector.handleFrameForTest(frame);
      }, (e, st) {});
      // Downstream async work (drift/path_provider) explodes in unit tests —
      // same env-noise class the fuzz harness filters.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final peerHex = Contact.fromFrame(contactFrame)!.publicKeyHex;
      final samples = svc.samplesFor(peerHex);
      expect(samples, isNotEmpty,
          reason: 'message RX must feed the signal log');
      final msgSample = samples.firstWhere((s) => s.snrDb != null);
      expect(msgSample.snrDb, closeTo(-6.5, 0.01));
      expect(msgSample.rssiDbm, -60);
    });

    test('contact v90 tail quality feeds the log', () {
      final connector = MeshCoreConnector();
      final svc = SignalLogService();
      connector.initialize(
        retryService: MessageRetryService(),
        pathHistoryService: PathHistoryService(StorageService()),
        signalLogService: svc,
      );
      connector.handleFrameForTest(selfInfoFrame());
      connector.handleFrameForTest([respCodeContactsStart]);
      connector.handleFrameForTest(contactFrame);
      connector.handleFrameForTest([respCodeEndOfContacts]);
      final peerHex = Contact.fromFrame(contactFrame)!.publicKeyHex;
      final before = svc.samplesFor(peerHex).length;

      // Re-send the contact frame WITH a v90 tail: [int16 LE path_snr4][flags]
      final withTail = Uint8List.fromList([
        ...contactFrame,
        -20 & 0xFF, 0xFF, // int16 LE -20 → path_snr4 = -20 → -5.0 dB
        0x01, // flags bit0: alt available
      ]);
      connector.handleFrameForTest(withTail);

      final samples = svc.samplesFor(peerHex);
      expect(samples.length, greaterThan(before));
      expect(samples.first.snrDb, closeTo(-5.0, 0.01));
    });
  });

  group('SignalLogSheet smoke', () {
    testWidgets('renders header, stats and recent samples', (tester) async {
      final connector = MeshCoreConnector();
      final svc = SignalLogService();
      final now = DateTime.now();
      const smokeKey = 'aa';
      // The smoke contact's pubkey is 0xAA x32 → hex 'aaaa...' (64 chars).
      final smokeHex = smokeKey * 32;
      for (var i = 0; i < 5; i++) {
        svc.record(
          smokeHex,
          snrDb: -6.0 - i,
          rssiDbm: -70 - i,
          hopCount: 1,
          usedAltRoute: i == 3,
          now: now.subtract(Duration(minutes: 4 - i)),
        );
      }

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: connector),
            ChangeNotifierProvider.value(value: svc),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () =>
                      SignalLogSheet.show(context, contact: _SmokeContact()),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Signal —'), findsOneWidget);
      expect(find.textContaining('dB'), findsWidgets);
      expect(find.text('ALT ROUTE'), findsOneWidget);
      expect(find.text('1 alt-route sends'), findsOneWidget);
    });
  });
}

class _SmokeContact extends Contact {
  _SmokeContact()
      : super(
          publicKey: Uint8List.fromList(List.filled(32, 0xAA)),
          name: 'smoke',
          type: 1,
          pathLength: 0,
          path: Uint8List(0),
          lastSeen: DateTime.now(),
        );
}

List<int> _u32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
