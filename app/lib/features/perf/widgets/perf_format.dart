/// Number and label formatting for the performance lab (English until the
/// l10n pass). Written units are short ("tok/s"); spoken ones are words.
library;

import 'package:sherpa_core/sherpa_core.dart' show ThermalLevel;

/// "21.4 tok/s", "512 tok/s", "—".
String formatTps(double? v) {
  if (v == null || !v.isFinite || v <= 0) return '—';
  return v >= 100 ? '${v.round()} tok/s' : '${v.toStringAsFixed(1)} tok/s';
}

/// "21.4 tokens per second".
String spokenTps(double? v) {
  if (v == null || !v.isFinite || v <= 0) return 'not measured';
  return '${v >= 100 ? v.round() : v.toStringAsFixed(1)} tokens per second';
}

/// "280 ms", "1.24 s", "—".
String formatMs(double? ms) {
  if (ms == null || !ms.isFinite || ms <= 0) return '—';
  return ms >= 1000 ? '${(ms / 1000).toStringAsFixed(2)} s' : '${ms.round()} ms';
}

/// "4.21 s".
String formatSeconds(double? s) {
  if (s == null || !s.isFinite || s <= 0) return '—';
  return '${s.toStringAsFixed(s >= 10 ? 1 : 2)} s';
}

/// "18%".
String formatPercent(double f) => '${(f * 100).round()}%';

/// "just now", "4 min ago", "3 h ago", "Oct 18".
String formatWhen(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return formatDate(at);
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Oct 18".
String formatDate(DateTime at) {
  final l = at.toLocal();
  return '${_months[l.month - 1]} ${l.day}';
}

/// "Oct 18, 09:05".
String formatDateTime(DateTime at) {
  final l = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${formatDate(l)}, ${two(l.hour)}:${two(l.minute)}';
}

/// What a thermal level means to a person; null = not reported.
String thermalLabel(ThermalLevel? t) => switch (t) {
      null => 'Not reported',
      ThermalLevel.nominal => 'Normal',
      ThermalLevel.fair => 'Warm',
      ThermalLevel.serious => 'Hot',
      ThermalLevel.critical => 'Too hot',
    };

/// "Normal → Warm" (or one label when it didn't change).
String thermalChange(ThermalLevel? before, ThermalLevel? after) {
  if (before == null && after == null) return 'Not reported';
  if (before == after) return thermalLabel(before);
  return '${thermalLabel(before)} → ${thermalLabel(after)}';
}

/// The same in words ("Normal, then Warm") for screen readers.
String spokenThermalChange(ThermalLevel? before, ThermalLevel? after) {
  if (before == null && after == null) return 'not reported';
  if (before == after) return thermalLabel(before);
  return '${thermalLabel(before)}, then ${thermalLabel(after)}';
}
