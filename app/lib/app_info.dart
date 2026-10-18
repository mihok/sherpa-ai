import 'package:flutter/services.dart' show FlutterVersion;

/// Build facts shown on the About screen.
///
/// The app version comes from `--dart-define=SHERPA_VERSION=x.y.z+n` in
/// release builds (CI passes the pubspec version), falling back to the
/// pubspec version at the time of writing. Flutter and Dart versions are
/// stamped by the Flutter tool itself.
abstract final class AppInfo {
  static const String version = String.fromEnvironment('SHERPA_VERSION', defaultValue: '0.1.0+1');
  static const String name = 'Sherpa';
  static const String license = 'MIT';

  static String get flutterVersion => FlutterVersion.version ?? 'unknown';
  static String get dartVersion => FlutterVersion.dartVersion ?? 'unknown';
  static String? get frameworkRevision => FlutterVersion.frameworkRevision;
}
