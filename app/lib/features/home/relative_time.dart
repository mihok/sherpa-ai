/// Compact, glanceable timestamps for lists. English-only until the app is
/// localized (strings live here so the l10n pass finds them in one place).
library;

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// "Just now", "5 min", "3 h", "Yesterday", "Tue", "Mar 4", "Mar 4, 2025".
/// Both times are compared in local time.
String formatRelativeShort(DateTime then, DateTime now) {
  final t = then.toLocal();
  final n = now.toLocal();
  final diff = n.difference(t);
  if (diff.inSeconds < 60) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min';
  final days = _day(n).difference(_day(t)).inDays;
  if (days == 0) return '${diff.inHours} h';
  if (days == 1) return 'Yesterday';
  if (days < 7) return _weekdays[t.weekday - 1];
  final md = '${_months[t.month - 1]} ${t.day}';
  return t.year == n.year ? md : '$md, ${t.year}';
}

/// Spoken variant: "5 minutes ago", "3 hours ago", "yesterday".
String formatRelativeSpoken(DateTime then, DateTime now) {
  final t = then.toLocal();
  final n = now.toLocal();
  final diff = n.difference(t);
  String plural(int v, String unit) => '$v $unit${v == 1 ? '' : 's'} ago';
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return plural(diff.inMinutes, 'minute');
  final days = _day(n).difference(_day(t)).inDays;
  if (days == 0) return plural(diff.inHours, 'hour');
  if (days == 1) return 'yesterday';
  return 'on ${formatRelativeShort(then, now)}';
}

enum DateBucket {
  today('Today'),
  yesterday('Yesterday'),
  week('Previous 7 days'),
  month('Previous 30 days'),
  older('Older');

  const DateBucket(this.label);
  final String label;
}

DateBucket bucketFor(DateTime then, DateTime now) {
  final days = _day(now.toLocal()).difference(_day(then.toLocal())).inDays;
  if (days <= 0) return DateBucket.today;
  if (days == 1) return DateBucket.yesterday;
  if (days < 7) return DateBucket.week;
  if (days < 30) return DateBucket.month;
  return DateBucket.older;
}
