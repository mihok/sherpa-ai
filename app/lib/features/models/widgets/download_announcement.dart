import '../../../design/widgets/a11y.dart' show progressMilestone;
import '../../../services/downloads/downloads.dart';

/// What a screen reader announces about a download (through a
/// `LiveAnnouncement`): every phase change, and while bytes move only each
/// 25 % milestone, never the running byte count.
String downloadAnnouncement(String name, JobPhase phase, {double? progress}) => switch (phase) {
      JobPhase.queued => '$name: queued',
      JobPhase.waitingForWifi => '$name: waiting for Wi-Fi',
      JobPhase.waitingForNetwork => '$name: waiting for a connection',
      JobPhase.resolving => '$name: connecting to Hugging Face',
      JobPhase.downloading => '$name: downloading, ${progressMilestone(progress)}%',
      JobPhase.verifying => '$name: checking the download',
      JobPhase.installing => '$name: adding to your library',
      JobPhase.paused => '$name: paused',
      JobPhase.failed => '$name: download stopped',
      JobPhase.done => '$name: verified and ready',
    };
