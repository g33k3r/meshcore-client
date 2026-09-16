import 'package:flutter/material.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/services/signal_log_service.dart';
import 'package:provider/provider.dart';

import 'snr_indicator.dart';

/// Signal Log — GeekCore field-test lens for one contact.
///
/// Live SNR/RSSI + the recent SNR trend with route-rotation markers, fed by
/// [SignalLogService] (message RX SNR, v90 device-measured path quality,
/// outgoing attempt routes). Strings hardcoded EN on purpose: this is a
/// dev/field-facing diagnostic, deliberately not part of the localized UX
/// surface (same rationale as TopologyDebugScreen).
class SignalLogSheet extends StatefulWidget {
  final Contact contact;

  const SignalLogSheet({super.key, required this.contact});

  static Future<void> show(BuildContext context, {required Contact contact}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SignalLogSheet(contact: contact),
    );
  }

  @override
  State<SignalLogSheet> createState() => _SignalLogSheetState();
}

class _SignalLogSheetState extends State<SignalLogSheet> {
  static const _windows = [
    (Duration(minutes: 5), '5m'),
    (Duration(minutes: 15), '15m'),
    (Duration(minutes: 60), '60m'),
  ];
  int _windowIndex = 1;

  Contact _resolveContact(MeshCoreConnector connector) {
    final live = connector.contacts
        .where((c) => c.publicKeyHex == widget.contact.publicKeyHex)
        .firstOrNull;
    return live ?? widget.contact;
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final service = context.watch<SignalLogService>();
    final contact = _resolveContact(connector);
    final samples = service.samplesFor(contact.publicKeyHex);
    final window = _windows[_windowIndex].$1;
    final series = SignalLogService.chartSeries(samples, window: window);
    final markers = SignalLogService.altMarkers(samples, window: window);
    final latest = samples.isEmpty ? null : samples.first;

    final snrNow = contact.pathQualityDb ?? latest?.snrDb;
    final rssiNow = latest?.rssiDbm;
    final hops = contact.pathLength < 0 ? null : contact.pathLength;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      builder: (context, scrollController) => SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Signal — ${contact.name.isEmpty ? 'unnamed' : contact.name}',
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (contact.hasAltPath ?? false)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Tooltip(
                      message: 'Alternate route available (v90+)',
                      child: Text('⇄ alt', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                IconButton(
                  tooltip: 'Clear log',
                  icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                  onPressed: samples.isEmpty
                      ? null
                      : () => service.clear(contact.publicKeyHex),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _Stat(
                  label: 'SNR now',
                  value: snrNow == null ? '—' : '${snrNow.toStringAsFixed(1)} dB',
                  icon: snrNow == null ? null : snrUiFromSNR(snrNow, connector.currentSf).icon,
                ),
                _Stat(label: 'RSSI', value: rssiNow == null ? '—' : '$rssiNow dBm'),
                _Stat(label: 'Hops', value: hops == null ? '—' : '$hops'),
                _Stat(
                  label: 'Samples',
                  value: '${samples.length}',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                for (var i = 0; i < _windows.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(_windows[i].$2),
                      selected: _windowIndex == i,
                      onSelected: (_) => setState(() => _windowIndex = i),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                const Spacer(),
                Text(
                  '${markers.length} alt-route sends',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              child: series.isEmpty
                  ? Center(
                      child: Text(
                        'No SNR samples in the last ${_windows[_windowIndex].$2}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  : SignalSparkline(series: series, markers: markers),
            ),
            const SizedBox(height: 12),
            ...samples.take(8).map((s) => _SampleRow(sample: s)),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;

  const _Stat({required this.label, required this.value, this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  value,
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (icon != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(icon, size: 16),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SampleRow extends StatelessWidget {
  final SignalSample sample;

  const _SampleRow({required this.sample});

  String _time(DateTime ts) {
    final now = DateTime.now();
    final d = now.difference(ts);
    if (d.inSeconds < 60) return '${d.inSeconds}s ago';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    return '${d.inHours}h ago';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snr = sample.snrDb == null ? '—' : '${sample.snrDb!.toStringAsFixed(1)} dB';
    final rssi = sample.rssiDbm == null ? '—' : '${sample.rssiDbm} dBm';
    final hops = sample.hopCount == null ? '—' : '${sample.hopCount}';
    final source = sample.usedAltRoute
        ? 'ALT ROUTE'
        : (sample.snrDb == null ? 'send' : 'rx');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(_time(sample.ts), style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              '$snr   $rssi   hops $hops',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Courier', 'monospace'],
              ),
            ),
          ),
          Text(
            source,
            style: theme.textTheme.bodySmall?.copyWith(
              color: sample.usedAltRoute ? Colors.orange : null,
              fontWeight: sample.usedAltRoute ? FontWeight.bold : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Minimal sparkline: grid lines + SNR line + alt-route marker dots +
/// min/max dB labels. One painter, no nesting.
class SignalSparkline extends StatelessWidget {
  final List<({double x, double y, double snrDb})> series;
  final List<double> markers;

  const SignalSparkline({super.key, required this.series, required this.markers});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CustomPaint(
      painter: _SignalSparklinePainter(
        series: series,
        markers: markers,
        lineColor: theme.colorScheme.primary,
        labelStyle: theme.textTheme.bodySmall!
            .copyWith(fontSize: 9, color: theme.colorScheme.outline),
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _SignalSparklinePainter extends CustomPainter {
  final List<({double x, double y, double snrDb})> series;
  final List<double> markers;
  final Color lineColor;
  final TextStyle labelStyle;

  _SignalSparklinePainter({
    required this.series,
    required this.markers,
    required this.lineColor,
    required this.labelStyle,
  });

  void _label(Canvas canvas, String text, Offset pos) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Grid: three faint horizontal lines.
    final grid = Paint()
      ..color = lineColor.withValues(alpha: 0.15)
      ..strokeWidth = 1;
    for (final frac in [0.0, 0.5, 1.0]) {
      canvas.drawLine(
        Offset(0, frac * size.height),
        Offset(size.width, frac * size.height),
        grid,
      );
    }

    if (series.isEmpty) return;

    final path = Path()
      ..moveTo(series.first.x * size.width, (1 - series.first.y) * size.height);
    for (final p in series) {
      path.lineTo(p.x * size.width, (1 - p.y) * size.height);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = lineColor,
    );

    for (final m in markers) {
      canvas.drawCircle(
        Offset(m * size.width, 8),
        3,
        Paint()..color = Colors.orange,
      );
    }

    // Min/max dB labels from the in-view series.
    double minSnr = series.first.snrDb;
    double maxSnr = minSnr;
    for (final p in series) {
      if (p.snrDb < minSnr) minSnr = p.snrDb;
      if (p.snrDb > maxSnr) maxSnr = p.snrDb;
    }
    _label(canvas, '${maxSnr.toStringAsFixed(1)} dB', const Offset(4, 2));
    _label(
      canvas,
      '${minSnr.toStringAsFixed(1)} dB',
      Offset(4, size.height - 14),
    );
  }

  @override
  bool shouldRepaint(_SignalSparklinePainter old) =>
      old.series != series || old.markers != markers;
}
