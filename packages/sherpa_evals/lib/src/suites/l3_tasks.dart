/// L3 task definitions (MCPMark / τ-bench style): initial server state, the
/// scripted user's messages, a recorded ideal trajectory, and a
/// verification function over the final state.
library;

import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';

import '../runtime/state_servers.dart';

/// What the trajectory has seen so far: tool results by act label, parsed
/// from the text the model was shown (so a truncated or lost handle makes
/// the recorded trajectory fail, as it would a real model).
final class Seen {
  Seen(this._byLabel);

  final Map<String, String> _byLabel;

  bool has(String label) => _byLabel.containsKey(label);

  String text(String label) => _byLabel[label] ?? (throw StateError('no result for $label'));

  /// The result as JSON (a map), or `{}` when it is not JSON.
  JsonMap json(String label) {
    try {
      final v = jsonDecode(text(label));
      return v is Map ? v.cast<String, Object?>() : {'value': v};
    } on FormatException {
      return const {};
    }
  }

  /// The first element of list [key] in [label]'s result matching [where].
  JsonMap pick(String label, String key, bool Function(JsonMap item) where) {
    final list = (json(label)[key] as List?) ?? const [];
    for (final e in list) {
      if (e is Map && where(e.cast<String, Object?>())) return e.cast<String, Object?>();
    }
    throw StateError('no $key item in $label matches');
  }

  /// A `<key>: "value"` handle anywhere in [label]'s text (works on
  /// truncated JSON too).
  String handle(String label, String key) {
    final j = json(label)[key];
    if (j is String) return j;
    final m = RegExp('"$key"\\s*:\\s*"([^"]+)"').firstMatch(text(label));
    return m?[1] ?? (throw StateError('no $key in $label'));
  }
}

/// One planned tool call: [label] names its result for later acts.
final class Act {
  const Act(this.label, this.tool, this.args);

  final String label;

  /// Model-facing name (`<server>__<tool>`).
  final String tool;
  final JsonMap Function(Seen seen) args;
}

/// The reply to one user message: steps (each a batch of parallel calls),
/// then a final text.
final class AgentTurn {
  const AgentTurn(this.steps, this.reply);

  final List<List<Act>> steps;
  final String reply;
}

/// One L3 task.
final class StateTask {
  const StateTask({
    required this.id,
    required this.servers,
    required this.instruction,
    required this.ideal,
    required this.verify,
    this.seed,
    this.followUps = const [],
    this.worldSeed = 1,
  });

  final String id;
  final List<String> servers;

  /// The scripted user: the first message, then one follow-up after each
  /// reply that ends the agent's turn, in order.
  final String instruction;
  final List<String> followUps;
  final List<AgentTurn> ideal;

  /// Fills the initial state.
  final void Function(World w)? seed;

  /// Problems with the final state ([before] is the seeded state's
  /// snapshot); empty when the goal is met.
  final List<String> Function(World w, WorldSnapshot before) verify;
  final int worldSeed;

  List<String> get messages => [instruction, ...followUps];

  World freshWorld() {
    final w = World(seed: worldSeed)..stock(groceryCatalog);
    seed?.call(w);
    return w;
  }
}

/// The seeded state, for "nothing else changed" checks.
final class WorldSnapshot {
  WorldSnapshot(World w)
      : notes = {for (final n in w.notes.values) n.id: jsonEncode(n.toJson())},
        events = {for (final e in w.events.values) e.id: jsonEncode(e.toJson())},
        files = {...w.files},
        baskets = {for (final b in w.baskets.values) b.id: b.lines.map((l) => '${l.sku}x${l.quantity}').join(',')};

  final Map<String, String> notes;
  final Map<String, String> events;
  final Map<String, String> files;
  final Map<String, String> baskets;
}

/// Seeded notes other than [except] are unchanged, and no note was added
/// beyond [added].
List<String> otherNotesUnchanged(World w, WorldSnapshot s, {Set<String> except = const {}, int added = 0}) => [
      for (final e in s.notes.entries)
        if (!except.contains(e.key) && jsonEncode(w.notes[e.key]?.toJson()) != e.value) 'note ${e.key} changed or was deleted',
      if (w.notes.length != s.notes.length + added) 'expected ${s.notes.length + added} notes, found ${w.notes.length}',
    ];

List<String> otherEventsUnchanged(World w, WorldSnapshot s, {Set<String> except = const {}, int added = 0}) => [
      for (final e in s.events.entries)
        if (!except.contains(e.key) && jsonEncode(w.events[e.key]?.toJson()) != e.value) 'event ${e.key} changed',
      if (w.events.length != s.events.length + added) 'expected ${s.events.length + added} events, found ${w.events.length}',
    ];

List<String> _orderIs(World w, Map<String, int> want, {String? basketId}) {
  if (w.orders.length != 1) return ['expected exactly 1 order, found ${w.orders.length}'];
  final o = w.orders.single;
  final out = <String>[];
  if (basketId != null && o.basketId != basketId) out.add('ordered basket ${o.basketId}, not $basketId');
  final got = jsonEncode(Map.fromEntries(o.lines.entries.toList()..sort((a, b) => a.key.compareTo(b.key))));
  final exp = jsonEncode(Map.fromEntries(want.entries.toList()..sort((a, b) => a.key.compareTo(b.key))));
  if (got != exp) out.add('ordered $got, wanted $exp');
  return out;
}

List<String> _eventIs(CalendarEvent? e, {String? title, String? date, String? time, int? duration, List<String> attendees = const []}) {
  if (e == null) return ['event missing'];
  return [
    if (e.cancelled) '${e.id} is cancelled',
    if (title != null && !mentions(e.title, title)) '${e.id} title "${e.title}" lacks "$title"',
    if (date != null && e.date != date) '${e.id} date ${e.date} != $date',
    if (time != null && e.time != time) '${e.id} time ${e.time} != $time',
    if (duration != null && e.durationMin != duration) '${e.id} duration ${e.durationMin} != $duration',
    for (final a in attendees)
      if (!e.attendees.any((x) => mentions(x, a))) '${e.id} attendees ${e.attendees} lack $a',
  ];
}

Act _a(String label, String tool, [JsonMap Function(Seen s)? args]) => Act(label, tool, args ?? (_) => const {});

bool _titled(JsonMap m, String t) => mentions('${m['title']}', t);

/// The L3 tasks, in report order.
final List<StateTask> l3Tasks = [
  StateTask(
    id: 'notes.create_then_append',
    servers: ['notes'],
    seed: (w) => w
      ..addNote('Recipes', 'Shakshuka: eggs, tomatoes, cumin.')
      ..addNote('Ideas', 'Bike to work on Fridays.'),
    instruction: 'Create a note titled "Packing list" with the text "passport, charger, socks". '
        'Then add "sunscreen" to that note on a new line.',
    ideal: [
      AgentTurn([
        [_a('create', 'notes__create_note', (_) => {'title': 'Packing list', 'body': 'passport, charger, socks'})],
        [_a('append', 'notes__update_note', (s) => {'note_id': s.handle('create', 'note_id'), 'append': 'sunscreen'})],
      ], 'Created "Packing list" and added sunscreen.'),
    ],
    verify: (w, s) {
      final hits = w.notesTitled('Packing list').toList();
      if (hits.length != 1) return ['expected one "Packing list" note, found ${hits.length}'];
      return [
        for (final x in ['passport', 'charger', 'socks', 'sunscreen'])
          if (!mentions(hits.single.body, x)) 'note body lacks $x',
        ...otherNotesUnchanged(w, s, added: 1),
      ];
    },
  ),
  StateTask(
    id: 'notes.edit_existing',
    servers: ['notes'],
    worldSeed: 2,
    seed: (w) => w
      ..addNote('Book wishlist', 'Piranesi; The Overstory (lend to Ana on Tuesday).')
      ..addNote('Book club', "Next meeting: Tuesday 19:00 at Lena's. Book: The Overstory.")
      ..addNote('Groceries', 'milk, bread'),
    instruction: 'In my "Book club" note, the meeting moved from Tuesday to Thursday. Please update the note.',
    ideal: [
      AgentTurn([
        [_a('search', 'notes__search_notes', (_) => {'query': 'Book club'})],
        [_a('get', 'notes__get_note', (s) => {'note_id': s.pick('search', 'notes', (n) => n['title'] == 'Book club')['note_id']})],
        [
          _a('update', 'notes__update_note', (s) => {
                'note_id': s.json('get')['note_id'],
                'body': '${s.json('get')['body']}'.replaceAll('Tuesday', 'Thursday'),
              }),
        ],
      ], 'Updated: the book club now meets on Thursday.'),
    ],
    verify: (w, s) {
      final n = w.notesTitled('Book club').singleOrNull;
      if (n == null) return ['"Book club" note missing or duplicated'];
      return [
        if (!mentions(n.body, 'Thursday')) 'body lacks Thursday',
        if (mentions(n.body, 'Tuesday')) 'body still says Tuesday',
        for (final x in ['19:00', 'Lena', 'The Overstory'])
          if (!mentions(n.body, x)) 'body lost "$x"',
        ...otherNotesUnchanged(w, s, except: {n.id}),
      ];
    },
  ),
  StateTask(
    id: 'calendar.reschedule',
    servers: ['calendar'],
    worldSeed: 3,
    seed: (w) => w
      ..addEvent('Team standup', '2026-10-21', '09:00', durationMin: 15)
      ..addEvent('Dentist', '2026-10-21', '08:30', durationMin: 45)
      ..addEvent('Dinner with Sam', '2026-10-23', '19:30', durationMin: 120),
    instruction: 'Move my dentist appointment to 2026-10-23 at 15:00.',
    ideal: [
      AgentTurn([
        [_a('find', 'calendar__find_events', (_) => {'query': 'dentist'})],
        [
          _a('move', 'calendar__update_event', (s) => {
                'event_id': s.pick('find', 'events', (e) => _titled(e, 'dentist'))['event_id'],
                'date': '2026-10-23',
                'time': '15:00',
              }),
        ],
      ], 'Your dentist appointment is now on 2026-10-23 at 15:00.'),
    ],
    verify: (w, s) {
      final dentist = w.events.values.where((e) => mentions(e.title, 'dentist')).toList();
      if (dentist.length != 1) return ['expected one dentist event, found ${dentist.length}'];
      return [
        ..._eventIs(dentist.single, date: '2026-10-23', time: '15:00', duration: 45),
        ...otherEventsUnchanged(w, s, except: {dentist.single.id}),
      ];
    },
  ),
  StateTask(
    id: 'calendar.create_meeting',
    servers: ['calendar'],
    worldSeed: 4,
    seed: (w) => w.addEvent('Gym', '2026-10-21', '07:00'),
    instruction: 'Schedule a 30-minute call titled "Budget review" with Priya on 2026-10-21 at 09:30.',
    ideal: [
      AgentTurn([
        [
          _a('create', 'calendar__create_event', (_) => {
                'title': 'Budget review',
                'date': '2026-10-21',
                'time': '09:30',
                'duration_min': 30,
                'attendees': ['Priya'],
              }),
        ],
      ], 'Scheduled "Budget review" with Priya on 2026-10-21 at 09:30 for 30 minutes.'),
    ],
    verify: (w, s) {
      final fresh = w.events.values.where((e) => !s.events.containsKey(e.id)).toList();
      if (fresh.length != 1) return ['expected 1 new event, found ${fresh.length}'];
      return [
        ..._eventIs(fresh.single, title: 'budget review', date: '2026-10-21', time: '09:30', duration: 30, attendees: ['Priya']),
        ...otherEventsUnchanged(w, s, added: 1),
      ];
    },
  ),
  StateTask(
    id: 'calendar.ask_which_then_cancel',
    servers: ['calendar'],
    worldSeed: 5,
    seed: (w) => w
      ..addEvent('Sync with Omar', '2026-10-20', '14:00', durationMin: 30, attendees: ['Omar'])
      ..addEvent('Design review', '2026-10-22', '10:00', attendees: ['Omar', 'Priya'])
      ..addEvent('Sync with Omar', '2026-10-23', '11:00', durationMin: 30, attendees: ['Omar']),
    instruction: 'Cancel my sync with Omar.',
    followUps: ['The one on Friday, 2026-10-23.'],
    ideal: [
      AgentTurn([
        [_a('find', 'calendar__find_events', (_) => {'query': 'Sync with Omar'})],
      ], 'You have two syncs with Omar: 2026-10-20 at 14:00 and 2026-10-23 at 11:00. Which one should I cancel?'),
      AgentTurn([
        [
          _a('cancel', 'calendar__cancel_event', (s) => {
                'event_id': s.pick('find', 'events', (e) => _titled(e, 'sync with omar') && e['date'] == '2026-10-23')['event_id'],
              }),
        ],
      ], 'Cancelled the sync with Omar on 2026-10-23.'),
    ],
    verify: (w, s) {
      final syncs = w.events.values.where((e) => mentions(e.title, 'sync with omar')).toList();
      final fri = syncs.where((e) => e.date == '2026-10-23').singleOrNull;
      final tue = syncs.where((e) => e.date == '2026-10-20').singleOrNull;
      return [
        if (fri == null || !fri.cancelled) 'the Friday sync is not cancelled',
        if (tue == null || tue.cancelled) 'the Tuesday sync was cancelled',
        ...otherEventsUnchanged(w, s, except: {?fri?.id}),
      ];
    },
  ),
  StateTask(
    id: 'files.rename_and_index',
    servers: ['files'],
    worldSeed: 6,
    seed: (w) => w.files.addAll({
      '/docs/draft.md': '# Q3 report\nRevenue grew 12%.\n',
      '/docs/index.md': '# Index\n- notes.md\n',
      '/docs/notes.md': 'Meeting notes.\n',
    }),
    instruction: 'Rename /docs/draft.md to /docs/final.md, then add the line "- final.md" to /docs/index.md.',
    ideal: [
      AgentTurn([
        [_a('move', 'files__move_file', (_) => {'from': '/docs/draft.md', 'to': '/docs/final.md'})],
        [_a('index', 'files__append_file', (_) => {'path': '/docs/index.md', 'text': '- final.md'})],
      ], 'Renamed the draft to /docs/final.md and listed it in /docs/index.md.'),
    ],
    verify: (w, s) => [
      if (w.files.containsKey('/docs/draft.md')) '/docs/draft.md still exists',
      if (w.files['/docs/final.md'] != s.files['/docs/draft.md']) '/docs/final.md does not hold the draft',
      if (RegExp(r'^- final\.md\s*$', multiLine: true).allMatches(w.files['/docs/index.md'] ?? '').length != 1)
        'index.md does not list final.md exactly once',
      if (!(w.files['/docs/index.md'] ?? '').contains('- notes.md')) 'index.md lost its old entry',
      if (w.files['/docs/notes.md'] != s.files['/docs/notes.md']) 'notes.md changed',
      if (w.files.length != 3) 'expected 3 files, found ${w.files.length}',
    ],
  ),
  StateTask(
    id: 'shop.new_basket_checkout',
    servers: ['shop'],
    worldSeed: 7,
    instruction: 'Order 2 oat milk and 1 rye bread: put them in a new basket and check out.',
    ideal: [
      AgentTurn([
        [
          _a('milk', 'shop__search_products', (_) => {'query': 'oat milk'}),
          _a('bread', 'shop__search_products', (_) => {'query': 'rye bread'}),
        ],
        [_a('basket', 'shop__create_basket')],
        [
          _a('add1', 'shop__add_item', (s) => {
                'basket_id': s.handle('basket', 'basket_id'),
                'sku': s.pick('milk', 'products', (p) => mentions('${p['name']}', 'oat'))['sku'],
                'quantity': 2,
              }),
          _a('add2', 'shop__add_item', (s) => {
                'basket_id': s.handle('basket', 'basket_id'),
                'sku': s.pick('bread', 'products', (p) => mentions('${p['name']}', 'rye'))['sku'],
                'quantity': 1,
              }),
        ],
        [_a('checkout', 'shop__checkout', (s) => {'basket_id': s.handle('basket', 'basket_id')})],
      ], 'Ordered 2 oat milk and 1 rye bread.'),
    ],
    verify: (w, s) => _orderIs(w, {'milk-oat-1l': 2, 'bread-rye-500g': 1}),
  ),
  StateTask(
    id: 'shop.adjust_open_basket',
    servers: ['shop'],
    worldSeed: 8,
    seed: (w) => w.addBasket({'banana-1kg': 1, 'coffee-beans-500g': 1, 'eggs-10': 1}),
    instruction: 'In my open basket, remove the bananas and change the coffee to 2 bags, then check out.',
    ideal: [
      AgentTurn([
        [_a('list', 'shop__list_baskets')],
        [_a('view', 'shop__view_basket', (s) => {'basket_id': s.pick('list', 'baskets', (b) => b['status'] == 'open')['basket_id']})],
        [
          _a('rm', 'shop__remove_item', (s) => {
                'basket_id': s.json('view')['basket_id'],
                'line_id': s.pick('view', 'lines', (l) => '${l['sku']}'.startsWith('banana'))['line_id'],
              }),
          _a('qty', 'shop__update_item', (s) => {
                'basket_id': s.json('view')['basket_id'],
                'line_id': s.pick('view', 'lines', (l) => '${l['sku']}'.startsWith('coffee'))['line_id'],
                'quantity': 2,
              }),
        ],
        [_a('checkout', 'shop__checkout', (s) => {'basket_id': s.json('view')['basket_id']})],
      ], 'Removed the bananas, set coffee to 2 and placed the order.'),
    ],
    verify: (w, s) => _orderIs(w, {'coffee-beans-500g': 2, 'eggs-10': 1}, basketId: s.baskets.keys.single),
  ),
  StateTask(
    id: 'cross.offsite_note_to_events',
    servers: ['notes', 'calendar'],
    worldSeed: 9,
    seed: (w) {
      w.addNote(
        'Team offsite',
        'Plan for the offsite (each session lasts 90 minutes):\n'
            '- 2026-10-26 10:00 Kickoff\n- 2026-10-27 14:00 Workshop\n- 2026-10-28 09:00 Retro',
      );
      w.addEvent('Flight to Lisbon', '2026-10-25', '18:00', durationMin: 180);
    },
    instruction: 'Read my note "Team offsite" and create a calendar event for each session it lists, '
        'with the right title, date, time and length.',
    ideal: [
      AgentTurn([
        [_a('search', 'notes__search_notes', (_) => {'query': 'Team offsite'})],
        [_a('get', 'notes__get_note', (s) => {'note_id': s.pick('search', 'notes', (n) => _titled(n, 'team offsite'))['note_id']})],
        [
          for (final (i, (d, t, title)) in [('2026-10-26', '10:00', 'Kickoff'), ('2026-10-27', '14:00', 'Workshop'), ('2026-10-28', '09:00', 'Retro')].indexed)
            _a('ev$i', 'calendar__create_event', (s) {
              if (!mentions(s.text('get'), '$d $t $title')) throw StateError('session $title not in the note');
              return {'title': title, 'date': d, 'time': t, 'duration_min': 90};
            }),
        ],
      ], 'Created the three offsite sessions in your calendar.'),
    ],
    verify: (w, s) {
      final fresh = w.events.values.where((e) => !s.events.containsKey(e.id)).toList();
      final out = <String>[if (fresh.length != 3) 'expected 3 new events, found ${fresh.length}'];
      for (final (d, t, title) in [('2026-10-26', '10:00', 'Kickoff'), ('2026-10-27', '14:00', 'Workshop'), ('2026-10-28', '09:00', 'Retro')]) {
        final e = fresh.where((e) => mentions(e.title, title)).toList();
        if (e.length != 1) {
          out.add('expected one "$title" event, found ${e.length}');
        } else {
          out.addAll(_eventIs(e.single, date: d, time: t, duration: 90));
        }
      }
      return [...out, ...otherNotesUnchanged(w, s), ...otherEventsUnchanged(w, s, added: 3)];
    },
  ),
  StateTask(
    id: 'cross.groceries_note_to_order',
    servers: ['notes', 'shop'],
    worldSeed: 10,
    seed: (w) => w
      ..addNote('Groceries', '- 2 x cherry tomatoes\n- 1 x parmesan\n- 3 x penne pasta')
      ..addNote('Gift ideas', 'coffee beans for Dad'),
    instruction: 'Buy everything on my "Groceries" note in the quantities it lists: '
        'make a new basket, add each item, and check out.',
    ideal: [
      AgentTurn([
        [_a('search', 'notes__search_notes', (_) => {'query': 'Groceries'})],
        [_a('get', 'notes__get_note', (s) => {'note_id': s.pick('search', 'notes', (n) => _titled(n, 'groceries'))['note_id']})],
        [
          _a('p0', 'shop__search_products', (_) => {'query': 'cherry tomatoes'}),
          _a('p1', 'shop__search_products', (_) => {'query': 'parmesan'}),
          _a('p2', 'shop__search_products', (_) => {'query': 'penne pasta'}),
          _a('basket', 'shop__create_basket'),
        ],
        [
          for (final (i, (word, qty)) in [('tomatoes', 2), ('parmesan', 1), ('penne', 3)].indexed)
            _a('add$i', 'shop__add_item', (s) => {
                  'basket_id': s.handle('basket', 'basket_id'),
                  'sku': s.pick('p$i', 'products', (p) => mentions('${p['name']}', word))['sku'],
                  'quantity': qty,
                }),
        ],
        [_a('checkout', 'shop__checkout', (s) => {'basket_id': s.handle('basket', 'basket_id')})],
      ], 'Ordered everything on your Groceries note.'),
    ],
    verify: (w, s) => [
      ..._orderIs(w, {'tomatoes-500g': 2, 'parmesan-200g': 1, 'pasta-penne-500g': 3}),
      ...otherNotesUnchanged(w, s),
    ],
  ),
];
