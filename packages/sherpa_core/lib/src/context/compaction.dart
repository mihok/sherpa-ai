import 'package:meta/meta.dart';

import '../common/cancellation.dart';
import '../common/json.dart';
import '../model/message.dart';

/// Structured compaction note. Fixed sections (rather than free prose) keep
/// summaries faithful across repeated compactions and let small models
/// produce them via JSON-schema constrained decoding.
@immutable
final class CompactionSummary {
  const CompactionSummary({
    required this.goal,
    this.decisions = const [],
    this.constraints = const [],
    this.openTasks = const [],
    this.keyFacts = const [],
    this.filesAndUrls = const [],
    this.toolState = const [],
    this.userPreferences = const [],
    this.notes,
  });

  factory CompactionSummary.fromJson(JsonMap j) {
    List<String> list(String k) => (j.opt<List<Object?>>(k) ?? const []).cast<String>();
    return CompactionSummary(
      goal: j.opt<String>('goal') ?? '',
      decisions: list('decisions'),
      constraints: list('constraints'),
      openTasks: list('openTasks'),
      keyFacts: list('keyFacts'),
      filesAndUrls: list('filesAndUrls'),
      toolState: list('toolState'),
      userPreferences: list('userPreferences'),
      notes: j.opt<String>('notes'),
    );
  }

  /// JSON schema handed to the summarizer (also used for grammar decoding).
  static const JsonMap schema = {
    'type': 'object',
    'properties': {
      'goal': {'type': 'string'},
      'decisions': {'type': 'array', 'items': {'type': 'string'}},
      'constraints': {'type': 'array', 'items': {'type': 'string'}},
      'openTasks': {'type': 'array', 'items': {'type': 'string'}},
      'keyFacts': {'type': 'array', 'items': {'type': 'string'}},
      'filesAndUrls': {'type': 'array', 'items': {'type': 'string'}},
      'toolState': {'type': 'array', 'items': {'type': 'string'}},
      'userPreferences': {'type': 'array', 'items': {'type': 'string'}},
      'notes': {'type': 'string'},
    },
    'required': ['goal', 'decisions', 'openTasks', 'keyFacts'],
  };

  final String goal;
  final List<String> decisions;
  final List<String> constraints;
  final List<String> openTasks;
  final List<String> keyFacts;
  final List<String> filesAndUrls;
  final List<String> toolState;
  final List<String> userPreferences;
  final String? notes;

  /// Markdown rendering placed in the model context.
  String render() {
    final b = StringBuffer('## Summary of earlier conversation\n');
    void section(String title, List<String> items) {
      if (items.isEmpty) return;
      b.writeln('\n### $title');
      for (final i in items) {
        b.writeln('- $i');
      }
    }

    b.writeln('\n### Goal\n$goal');
    section('Decisions', decisions);
    section('Constraints', constraints);
    section('Open tasks', openTasks);
    section('Key facts', keyFacts);
    section('Files and URLs', filesAndUrls);
    section('Tool state', toolState);
    section('User preferences', userPreferences);
    if (notes != null && notes!.isNotEmpty) b.writeln('\n### Notes\n$notes');
    return b.toString();
  }

  JsonMap toJson() => compact({
        'goal': goal,
        'decisions': decisions,
        'constraints': constraints,
        'openTasks': openTasks,
        'keyFacts': keyFacts,
        'filesAndUrls': filesAndUrls,
        'toolState': toolState,
        'userPreferences': userPreferences,
        'notes': notes,
      });
}

@immutable
final class CompactionInput {
  const CompactionInput({
    required this.messages,
    this.previousSummary,
    this.taskStatement,
    this.maxSummaryTokens = 1024,
  });

  /// Verbatim turns being folded into the summary.
  final List<Message> messages;

  /// The summary these turns follow, merged rather than nested.
  final CompactionSummary? previousSummary;
  final String? taskStatement;
  final int maxSummaryTokens;
}

/// Pluggable summarization. Implementations may use the session model, a
/// cheaper/smaller model, or a deterministic extractor (tests, offline).
abstract interface class ContextStrategy {
  String get id;

  Future<CompactionSummary> summarize(CompactionInput input, {CancellationToken? cancel});
}
