import 'package:flutter/foundation.dart';

/// One signal observation for a contact.
///
/// Sources: incoming message frames (snr/rssi of the arriving flood),
/// v90+ contact tails (device-measured path quality), and outgoing send
/// attempts (route marker: primary vs alternate).
@immutable
class SignalSample {
  final DateTime ts;

  /// LoRa SNR in dB at reception (null when this sample is only a route
  /// marker for an outgoing attempt).
  final double? snrDb;

  /// Receiver RSSI in dBm (null when unknown).
  final int? rssiDbm;

  /// Flood hop count for the route in effect (null when unknown).
  final int? hopCount;

  /// True when an outgoing attempt used the alternate path.
  final bool usedAltRoute;

  const SignalSample({
    required this.ts,
    this.snrDb,
    this.rssiDbm,
    this.hopCount,
    this.usedAltRoute = false,
  });
}

/// In-memory per-contact ring of recent signal samples.
///
/// Field-test lens for the GeekCore quality stack: SNR trend + route
/// rotation markers over time. Deliberately NOT persisted — a field session
/// lives in RAM, and skipping storage keeps the surface tiny. Ring-capped so
/// a long session cannot grow without bound.
class SignalLogService extends ChangeNotifier {
  final Map<String, List<SignalSample>> _samples = {};
  final int maxSamplesPerContact;

  SignalLogService({this.maxSamplesPerContact = 200});

  int _version = 0;
  int get version => _version;

  /// Record a sample. Coalesces bursts: if the newest sample for the contact
  /// is younger than [coalesceWindow] and carries the same rounded values,
  /// it is dropped (contact syncs and message floods otherwise flood the log
  /// with identical points).
  static const coalesceWindow = Duration(seconds: 3);

  void record(
    String contactPubKeyHex, {
    double? snrDb,
    int? rssiDbm,
    int? hopCount,
    bool usedAltRoute = false,
    DateTime? now,
  }) {
    final ts = now ?? DateTime.now();
    final list = _samples.putIfAbsent(contactPubKeyHex, () => []);

    if (list.isNotEmpty) {
      final last = list.last;
      final sameValues = _roundHalf(last.snrDb) == _roundHalf(snrDb) &&
          last.rssiDbm == rssiDbm &&
          last.hopCount == hopCount &&
          last.usedAltRoute == usedAltRoute;
      if (sameValues && ts.difference(last.ts) < coalesceWindow) return;
    }

    list.add(SignalSample(
      ts: ts,
      snrDb: snrDb,
      rssiDbm: rssiDbm,
      hopCount: hopCount,
      usedAltRoute: usedAltRoute,
    ));
    if (list.length > maxSamplesPerContact) {
      list.removeRange(0, list.length - maxSamplesPerContact);
    }
    _version++;
    notifyListeners();
  }

  /// Newest-first copy of the samples for a contact.
  List<SignalSample> samplesFor(String contactPubKeyHex) {
    final list = _samples[contactPubKeyHex];
    if (list == null) return const [];
    return List.unmodifiable(list.reversed);
  }

  void clear(String contactPubKeyHex) {
    if (_samples.remove(contactPubKeyHex) != null) {
      _version++;
      notifyListeners();
    }
  }

  void clearAll() {
    _samples.clear();
    _version++;
    notifyListeners();
  }

  static double? _roundHalf(double? v) =>
      v == null ? null : (v * 2).roundToDouble() / 2;

  // ── Chart data prep (pure, unit-tested) ─────────────────────────────────

  /// Normalized chart series for the sparkline: oldest → newest within
  /// [window] of [now]. X in 0..1 across the window, Y in 0..1 where 0 is
  /// the weakest and 1 the strongest SNR in view (0.5 dB rounded, padding
  /// included). Samples without SNR are skipped here — they are route
  /// markers and are surfaced separately by [altMarkers].
  static List<({double x, double y, double snrDb})> chartSeries(
    List<SignalSample> samples, {
    required Duration window,
    DateTime? now,
  }) {
    final end = now ?? DateTime.now();
    final start = end.subtract(window);
    final inWindow = samples
        .where((s) =>
            !s.ts.isBefore(start) &&
            !s.ts.isAfter(end) &&
            s.snrDb != null)
        .toList()
      ..sort((a, b) => a.ts.compareTo(b.ts));
    if (inWindow.isEmpty) return const [];

    double minSnr = inWindow.first.snrDb!;
    double maxSnr = minSnr;
    for (final s in inWindow) {
      if (s.snrDb! < minSnr) minSnr = s.snrDb!;
      if (s.snrDb! > maxSnr) maxSnr = s.snrDb!;
    }
    // Padding so a flat line doesn't collapse to a single pixel row.
    if (maxSnr - minSnr < 2) {
      minSnr -= 1;
      maxSnr += 1;
    }

    final windowMs = window.inMilliseconds;
    return [
      for (final s in inWindow)
        (
          x: s.ts.difference(start).inMilliseconds / windowMs,
          y: (s.snrDb! - minSnr) / (maxSnr - minSnr),
          snrDb: s.snrDb!,
        )
    ];
  }

  /// X positions (0..1) of alternate-route markers within [window] — outgoing
  /// attempts that used the alternate path. Overlay dots on the sparkline.
  static List<double> altMarkers(
    List<SignalSample> samples, {
    required Duration window,
    DateTime? now,
  }) {
    final end = now ?? DateTime.now();
    final start = end.subtract(window);
    final windowMs = window.inMilliseconds;
    return [
      for (final s in samples)
        if (s.usedAltRoute && !s.ts.isBefore(start) && !s.ts.isAfter(end))
          s.ts.difference(start).inMilliseconds / windowMs,
    ];
  }
}
