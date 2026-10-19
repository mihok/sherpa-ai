/// Number formatting for the model screens. One unit system everywhere:
/// binary units labelled "GB"/"MB", the same as the device-fit engine's
/// own messages ("Needs about 4.6 GB…"), so a size on a card and a size in
/// a fit reason never disagree. English-only until the l10n pass.
library;

const int _kib = 1024;
const int _mib = 1024 * 1024;
const int _gib = 1024 * 1024 * 1024;

/// "812 MB", "2.4 GB", "18 GB".
String formatBytes(int bytes) {
  if (bytes >= _gib) {
    final g = bytes / _gib;
    return '${g >= 10 ? g.round() : g.toStringAsFixed(1)} GB';
  }
  if (bytes >= _mib) return '${(bytes / _mib).round()} MB';
  if (bytes >= _kib) return '${(bytes / _kib).round()} KB';
  return '$bytes B';
}

/// "1.2 of 4.6 GB": both sides in the larger unit so the numbers compare.
String formatBytesOf(int done, int total) {
  if (total >= _gib) {
    final t = total / _gib;
    final d = done / _gib;
    final digits = t >= 10 ? 0 : 1;
    return '${d.toStringAsFixed(digits)} of ${t.toStringAsFixed(digits)} GB';
  }
  return '${(done / _mib).round()} of ${(total / _mib).round()} MB';
}

/// "3.1 MB/s", "640 KB/s".
String formatSpeed(double bytesPerSecond) {
  if (bytesPerSecond >= _mib) return '${(bytesPerSecond / _mib).toStringAsFixed(1)} MB/s';
  return '${(bytesPerSecond / _kib).round()} KB/s';
}

/// "6 min left", "1 h 20 min left", "under a minute left".
String formatEta(Duration d) {
  if (d.inSeconds < 60) return 'under a minute left';
  if (d.inMinutes < 60) return '${d.inMinutes} min left';
  final h = d.inHours;
  final m = d.inMinutes % 60;
  return m == 0 ? '$h h left' : '$h h $m min left';
}

/// "1.2M", "48K", "184".
String formatCount(int n) {
  if (n >= 1000000) {
    final v = n / 1000000;
    return '${v >= 10 ? v.round() : v.toStringAsFixed(1)}M';
  }
  if (n >= 1000) {
    final v = n / 1000;
    return '${v >= 10 ? v.round() : v.toStringAsFixed(1)}K';
  }
  return '$n';
}

/// "4K", "32K", "128K" tokens.
String formatContext(int tokens) {
  if (tokens >= 1024 && tokens % 1024 == 0) return '${tokens ~/ 1024}K';
  if (tokens >= 1000) return '${(tokens / 1000).round()}K';
  return '$tokens';
}

/// "2.4 bits/weight".
String formatBpwShort(double v) => '${v.toStringAsFixed(1)} bits/weight';

/// "7.6B", "1B", "270M".
String formatParams(int n) {
  final b = n / 1e9;
  if (b >= 10) return '${b.round()}B';
  if (b >= 1) return '${_trim(b.toStringAsFixed(1))}B';
  return '${(n / 1e6).round()}M';
}

String _trim(String s) => s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
