import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

void main() {
  test('tokenize splits snake/camel case, drops stop words, stems plurals and -ing', () {
    expect(Bm25Index.tokenize('github__createIssue for the repos'), ['github', 'create', 'issue', 'repo']);
    expect(Bm25Index.tokenize('Searching HTTPServer logs'), ['search', 'http', 'server', 'log']);
    expect(Bm25Index.stem('libraries'), 'library');
    expect(Bm25Index.stem('class'), 'class');
  });

  test('ranks by field-weighted relevance, ties by insertion order', () {
    final index = Bm25Index([
      const Bm25Document(id: 'mail__send', fields: {'name': 'mail__send send', 'description': 'Send an email message', 'params': 'to subject body'}),
      const Bm25Document(id: 'gh__create_issue', fields: {'name': 'gh__create_issue', 'description': 'Open a new issue in a GitHub repository', 'params': 'repo title body'}),
      const Bm25Document(id: 'gh__list_issues', fields: {'name': 'gh__list_issues', 'description': 'List issues of a repository', 'params': 'repo state'}),
      const Bm25Document(id: 'cal__add', fields: {'name': 'cal__add', 'description': 'Add a calendar event', 'params': 'title when'}),
    ]);
    expect(index.search('create a github issue').first.id, 'gh__create_issue');
    expect(index.search('email').single.id, 'mail__send');
    expect([for (final h in index.search('issues')) h.id], ['gh__list_issues', 'gh__create_issue']);
    expect(index.search('weather'), isEmpty);
    expect(index.search('issue', filter: (id) => id != 'gh__list_issues').single.id, 'gh__create_issue');
    expect(index.search('the and of'), isEmpty, reason: 'stop words only');
  });

  test('reciprocal rank fusion and cosine similarity', () {
    expect(reciprocalRankFusion([
      ['a', 'b', 'c'],
      ['b', 'c', 'a'],
    ]), ['b', 'a', 'c']);
    expect(reciprocalRankFusion([
      ['x', 'y'],
      ['y', 'x'],
    ]), ['x', 'y'], reason: 'ties break by first appearance');
    expect(cosineSimilarity([1, 0], [1, 0]), closeTo(1, 1e-9));
    expect(cosineSimilarity([1, 0], [0, 1]), 0);
    expect(cosineSimilarity([1], [1, 2]), 0);
  });
}
