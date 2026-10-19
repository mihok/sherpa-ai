/// Stateful fake MCP servers for the long-horizon suites (L3, L4): notes,
/// calendar, files and a shopping basket with handles, all on
/// `DartMcpServer` and served in-process behind the real client stack
/// ([McpEnv]). The state lives in a [World] the verification functions
/// compare with the goal state after the run.
library;

import 'package:sherpa_core/sherpa_core.dart' show JsonMap;
import 'package:sherpa_mcp/sherpa_mcp.dart';

import 'mcp_env.dart';

final class Note {
  Note(this.id, this.title, this.body, {List<String>? tags}) : tags = tags ?? [];

  final String id;
  String title;
  String body;
  final List<String> tags;

  JsonMap toJson() => {'note_id': id, 'title': title, 'body': body, 'tags': tags};
}

final class CalendarEvent {
  CalendarEvent(this.id, this.title, this.date, this.time, {this.durationMin = 60, List<String>? attendees})
      : attendees = attendees ?? [];

  final String id;
  String title;
  String date;
  String time;
  int durationMin;
  final List<String> attendees;
  bool cancelled = false;

  JsonMap toJson() => {
        'event_id': id,
        'title': title,
        'date': date,
        'time': time,
        'duration_min': durationMin,
        'attendees': attendees,
        if (cancelled) 'cancelled': true,
      };
}

final class Product {
  const Product(this.sku, this.name, this.priceCents);

  final String sku;
  final String name;
  final int priceCents;

  JsonMap toJson() => {'sku': sku, 'name': name, 'price': '${(priceCents / 100).toStringAsFixed(2)} EUR'};
}

final class BasketLine {
  BasketLine(this.id, this.sku, this.quantity);

  final String id;
  final String sku;
  int quantity;
}

final class Basket {
  Basket(this.id);

  final String id;
  final List<BasketLine> lines = [];
  String? orderId;

  bool get open => orderId == null;
}

final class Order {
  Order(this.id, this.basketId, this.lines);

  final String id;
  final String basketId;

  /// sku → quantity at checkout.
  final Map<String, int> lines;
}

/// One state-changing call as the server applied it.
final class AppliedEffect {
  AppliedEffect(this.tool, this.args, this.idempotencyKey);

  final String tool;
  final JsonMap args;
  final String? idempotencyKey;

  @override
  String toString() => '$tool$args';
}

/// The state behind the four servers. Ids are deterministic per [seed] but
/// not sequential, so a model cannot guess a handle it never saw.
final class World {
  World({this.seed = 1});

  final int seed;
  final Map<String, Note> notes = {};
  final Map<String, CalendarEvent> events = {};
  final Map<String, String> files = {};
  final Map<String, Basket> baskets = {};
  final List<Order> orders = [];
  final Map<String, Product> catalog = {};
  final List<AppliedEffect> effects = [];
  int _n = 0;

  String newId(String prefix) {
    _n++;
    final v = (seed * 7919 + _n * 104729 + prefix.length * 31) % (36 * 36 * 36 * 36);
    return '${prefix}_${v.toRadixString(36).padLeft(4, '0')}';
  }

  void applied(String tool, JsonMap args, DartToolContext ctx) => effects.add(AppliedEffect(tool, args, ctx.idempotencyKey));

  Note addNote(String title, String body, {List<String>? tags}) {
    final n = Note(newId('note'), title, body, tags: tags);
    notes[n.id] = n;
    return n;
  }

  CalendarEvent addEvent(String title, String date, String time, {int durationMin = 60, List<String>? attendees}) {
    final e = CalendarEvent(newId('evt'), title, date, time, durationMin: durationMin, attendees: attendees);
    events[e.id] = e;
    return e;
  }

  Basket addBasket(Map<String, int> lines) {
    final b = Basket(newId('bsk'));
    for (final e in lines.entries) {
      b.lines.add(BasketLine(newId('line'), e.key, e.value));
    }
    baskets[b.id] = b;
    return b;
  }

  void stock(List<Product> products) {
    for (final p in products) {
      catalog[p.sku] = p;
    }
  }

  Iterable<Note> notesTitled(String title) => notes.values.where((n) => _norm(n.title) == _norm(title));

  Iterable<CalendarEvent> get liveEvents => events.values.where((e) => !e.cancelled);
}

String _norm(String s) => s.trim().toLowerCase();

/// Case-insensitive containment, ignoring repeated whitespace.
bool mentions(String haystack, String needle) =>
    haystack.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').contains(needle.toLowerCase().replaceAll(RegExp(r'\s+'), ' '));

final RegExp _date = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final RegExp _time = RegExp(r'^\d{2}:\d{2}$');

String? _str(JsonMap a, String k) {
  final v = a[k];
  return v is String && v.trim().isNotEmpty ? v.trim() : null;
}

int? _int(JsonMap a, String k) {
  final v = a[k];
  return switch (v) {
    int() => v,
    num() when v == v.roundToDouble() => v.toInt(),
    String() => int.tryParse(v.trim()),
    _ => null,
  };
}

List<String> _strings(JsonMap a, String k) {
  final v = a[k];
  if (v is List) return [for (final e in v) if (e is String && e.trim().isNotEmpty) e.trim()];
  if (v is String && v.trim().isNotEmpty) return [for (final s in v.split(',')) if (s.trim().isNotEmpty) s.trim()];
  return const [];
}

const Map<String, Object?> _string = {'type': 'string'};

DartMcpServer notesServer(World w) => DartMcpServer(
      info: McpImplementation(name: 'notes', version: '1'),
      tools: [
        mcpTool('search_notes',
            description: 'Search notes by words in their title or body. Returns note ids, titles and a preview.',
            annotations: Hints.read,
            properties: {'query': {'type': 'string', 'description': 'Words to look for'}},
            required: ['query'], handler: (a, ctx) async {
          final q = _str(a, 'query') ?? '';
          final words = q.toLowerCase().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
          final hits = [
            for (final n in w.notes.values)
              if (words.any((x) => '${n.title} ${n.body}'.toLowerCase().contains(x)))
                {'note_id': n.id, 'title': n.title, 'preview': n.body.length > 60 ? '${n.body.substring(0, 60)}…' : n.body},
          ];
          return DartToolResult.json({'notes': hits});
        }),
        mcpTool('get_note',
            description: 'Read one note by its note_id.',
            annotations: Hints.read,
            properties: {'note_id': _string},
            required: ['note_id'], handler: (a, ctx) async {
          final n = w.notes[_str(a, 'note_id')];
          return n == null ? DartToolResult.error('No note with id ${a['note_id']}.') : DartToolResult.json(n.toJson());
        }),
        mcpTool('create_note',
            description: 'Create a new note. Returns its note_id.',
            annotations: Hints.write,
            properties: {
              'title': _string,
              'body': _string,
              'tags': {'type': 'array', 'items': _string},
            },
            required: ['title', 'body'], handler: (a, ctx) async {
          final title = _str(a, 'title');
          if (title == null) return DartToolResult.error('title is required.');
          w.applied('create_note', a, ctx);
          final n = w.addNote(title, (a['body'] as String?) ?? '', tags: _strings(a, 'tags'));
          return DartToolResult.json({'note_id': n.id, 'title': n.title});
        }),
        mcpTool('update_note',
            description: "Change a note. 'body' replaces the whole text; 'append' adds a new line at the end.",
            annotations: Hints.idempotentWrite,
            properties: {'note_id': _string, 'title': _string, 'body': _string, 'append': _string},
            required: ['note_id'], handler: (a, ctx) async {
          final n = w.notes[_str(a, 'note_id')];
          if (n == null) return DartToolResult.error('No note with id ${a['note_id']}.');
          if (_str(a, 'title') == null && a['body'] is! String && _str(a, 'append') == null) {
            return DartToolResult.error('Nothing to change: pass title, body or append.');
          }
          w.applied('update_note', a, ctx);
          if (_str(a, 'title') case final t?) n.title = t;
          if (a['body'] case final String b) n.body = b;
          if (_str(a, 'append') case final x?) n.body = n.body.isEmpty ? x : '${n.body}\n$x';
          return DartToolResult.json(n.toJson());
        }),
        mcpTool('delete_note',
            description: 'Delete a note.',
            annotations: Hints.destructive,
            properties: {'note_id': _string},
            required: ['note_id'], handler: (a, ctx) async {
          final id = _str(a, 'note_id');
          if (w.notes[id] == null) return DartToolResult.error('No note with id ${a['note_id']}.');
          w.applied('delete_note', a, ctx);
          w.notes.remove(id);
          return DartToolResult.json({'deleted': id});
        }),
      ],
    );

DartMcpServer calendarServer(World w) => DartMcpServer(
      info: McpImplementation(name: 'calendar', version: '1'),
      tools: [
        mcpTool('find_events',
            description: 'Find calendar events whose title or attendees match the query (and, optionally, on a date).',
            annotations: Hints.read,
            properties: {
              'query': {'type': 'string', 'description': 'Words in the title, or an attendee name'},
              'date': {'type': 'string', 'description': 'YYYY-MM-DD'},
            },
            required: ['query'], handler: (a, ctx) async {
          final words = (_str(a, 'query') ?? '').toLowerCase().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
          final date = _str(a, 'date');
          final hits = [
            for (final e in w.liveEvents)
              if ((date == null || e.date == date) &&
                  (words.isEmpty || words.any((x) => '${e.title} ${e.attendees.join(' ')}'.toLowerCase().contains(x))))
                e.toJson(),
          ];
          return DartToolResult.json({'events': hits});
        }),
        mcpTool('list_events',
            description: 'List the events on one day.',
            annotations: Hints.read,
            properties: {'date': {'type': 'string', 'description': 'YYYY-MM-DD'}},
            required: ['date'], handler: (a, ctx) async {
          final date = _str(a, 'date');
          return DartToolResult.json({
            'events': [for (final e in w.liveEvents) if (e.date == date) e.toJson()],
          });
        }),
        mcpTool('create_event',
            description: 'Create a calendar event. Returns its event_id.',
            annotations: Hints.write,
            properties: {
              'title': _string,
              'date': {'type': 'string', 'description': 'YYYY-MM-DD'},
              'time': {'type': 'string', 'description': 'HH:MM, 24-hour'},
              'duration_min': {'type': 'integer', 'description': 'Length in minutes (default 60)'},
              'attendees': {'type': 'array', 'items': _string},
            },
            required: ['title', 'date', 'time'], handler: (a, ctx) async {
          final title = _str(a, 'title');
          final date = _str(a, 'date');
          final time = _str(a, 'time');
          if (title == null || date == null || !_date.hasMatch(date) || time == null || !_time.hasMatch(time)) {
            return DartToolResult.error('title, date (YYYY-MM-DD) and time (HH:MM) are required.');
          }
          w.applied('create_event', a, ctx);
          final e = w.addEvent(title, date, time, durationMin: _int(a, 'duration_min') ?? 60, attendees: _strings(a, 'attendees'));
          return DartToolResult.json(e.toJson());
        }),
        mcpTool('update_event',
            description: 'Change an event: any of title, date, time, duration_min, attendees (replaces the list).',
            annotations: Hints.idempotentWrite,
            properties: {
              'event_id': _string,
              'title': _string,
              'date': {'type': 'string', 'description': 'YYYY-MM-DD'},
              'time': {'type': 'string', 'description': 'HH:MM, 24-hour'},
              'duration_min': {'type': 'integer'},
              'attendees': {'type': 'array', 'items': _string},
            },
            required: ['event_id'], handler: (a, ctx) async {
          final e = w.events[_str(a, 'event_id')];
          if (e == null || e.cancelled) return DartToolResult.error('No event with id ${a['event_id']}.');
          final date = _str(a, 'date');
          final time = _str(a, 'time');
          if (date != null && !_date.hasMatch(date)) return DartToolResult.error('date must be YYYY-MM-DD.');
          if (time != null && !_time.hasMatch(time)) return DartToolResult.error('time must be HH:MM.');
          w.applied('update_event', a, ctx);
          if (_str(a, 'title') case final t?) e.title = t;
          if (date != null) e.date = date;
          if (time != null) e.time = time;
          if (_int(a, 'duration_min') case final d?) e.durationMin = d;
          if (a.containsKey('attendees')) {
            e.attendees
              ..clear()
              ..addAll(_strings(a, 'attendees'));
          }
          return DartToolResult.json(e.toJson());
        }),
        mcpTool('cancel_event',
            description: 'Cancel (delete) an event.',
            annotations: Hints.destructive,
            properties: {'event_id': _string},
            required: ['event_id'], handler: (a, ctx) async {
          final e = w.events[_str(a, 'event_id')];
          if (e == null || e.cancelled) return DartToolResult.error('No event with id ${a['event_id']}.');
          w.applied('cancel_event', a, ctx);
          e.cancelled = true;
          return DartToolResult.json({'cancelled': e.id, 'title': e.title});
        }),
      ],
    );

DartMcpServer filesServer(World w) => DartMcpServer(
      info: McpImplementation(name: 'files', version: '1'),
      tools: [
        mcpTool('list_dir',
            description: 'List the files in a directory.',
            annotations: Hints.read,
            properties: {'path': {'type': 'string', 'description': 'Absolute directory path, e.g. /docs'}},
            required: ['path'], handler: (a, ctx) async {
          var dir = _str(a, 'path') ?? '/';
          if (!dir.endsWith('/')) dir = '$dir/';
          return DartToolResult.json({
            'files': [for (final f in w.files.keys.toList()..sort()) if (f.startsWith(dir)) f],
          });
        }),
        mcpTool('read_file',
            description: 'Read a text file.',
            annotations: Hints.read,
            properties: {'path': _string},
            required: ['path'], handler: (a, ctx) async {
          final text = w.files[_str(a, 'path')];
          return text == null ? DartToolResult.error('No such file: ${a['path']}') : DartToolResult.text(text);
        }),
        mcpTool('write_file',
            description: 'Create or overwrite a text file with the given content.',
            annotations: Hints.idempotentWrite,
            properties: {'path': _string, 'content': _string},
            required: ['path', 'content'], handler: (a, ctx) async {
          final path = _str(a, 'path');
          if (path == null || !path.startsWith('/')) return DartToolResult.error('path must be absolute.');
          w.applied('write_file', a, ctx);
          w.files[path] = (a['content'] as String?) ?? '';
          return DartToolResult.json({'path': path, 'bytes': w.files[path]!.length});
        }),
        mcpTool('append_file',
            description: 'Append text to the end of a file (a newline is added before it if needed).',
            annotations: Hints.write,
            properties: {'path': _string, 'text': _string},
            required: ['path', 'text'], handler: (a, ctx) async {
          final path = _str(a, 'path');
          final old = w.files[path];
          if (old == null) return DartToolResult.error('No such file: ${a['path']}');
          w.applied('append_file', a, ctx);
          final text = (a['text'] as String?) ?? '';
          w.files[path!] = old.isEmpty || old.endsWith('\n') ? '$old$text' : '$old\n$text';
          return DartToolResult.json({'path': path, 'bytes': w.files[path]!.length});
        }),
        mcpTool('move_file',
            description: 'Move or rename a file.',
            annotations: Hints.write,
            properties: {'from': _string, 'to': _string},
            required: ['from', 'to'], handler: (a, ctx) async {
          final from = _str(a, 'from');
          final to = _str(a, 'to');
          if (from == null || !w.files.containsKey(from)) return DartToolResult.error('No such file: ${a['from']}');
          if (to == null || !to.startsWith('/')) return DartToolResult.error('to must be an absolute path.');
          if (w.files.containsKey(to)) return DartToolResult.error('$to already exists.');
          w.applied('move_file', a, ctx);
          w.files[to] = w.files.remove(from)!;
          return DartToolResult.json({'from': from, 'to': to});
        }),
        mcpTool('delete_file',
            description: 'Delete a file.',
            annotations: Hints.destructive,
            properties: {'path': _string},
            required: ['path'], handler: (a, ctx) async {
          final path = _str(a, 'path');
          if (!w.files.containsKey(path)) return DartToolResult.error('No such file: ${a['path']}');
          w.applied('delete_file', a, ctx);
          w.files.remove(path);
          return DartToolResult.json({'deleted': path});
        }),
      ],
    );

DartMcpServer shopServer(World w) {
  JsonMap view(Basket b) {
    var total = 0;
    return {
      'basket_id': b.id,
      'status': b.open ? 'open' : 'ordered',
      'lines': [
        for (final l in b.lines)
          () {
            final p = w.catalog[l.sku];
            total += (p?.priceCents ?? 0) * l.quantity;
            return {'line_id': l.id, 'sku': l.sku, 'name': p?.name ?? l.sku, 'quantity': l.quantity};
          }(),
      ],
      'total': '${(total / 100).toStringAsFixed(2)} EUR',
      if (b.orderId != null) 'order_id': b.orderId,
    };
  }

  DartToolResult? openBasket(JsonMap a, void Function(Basket b) use) {
    final b = w.baskets[_str(a, 'basket_id')];
    if (b == null) return DartToolResult.error('No basket with id ${a['basket_id']}.');
    if (!b.open) return DartToolResult.error('Basket ${b.id} is already checked out (order ${b.orderId}).');
    use(b);
    return null;
  }

  return DartMcpServer(
    info: McpImplementation(name: 'shop', version: '1'),
    tools: [
      mcpTool('search_products',
          description: 'Search the grocery catalog. Returns product skus, names and prices.',
          annotations: Hints.read,
          properties: {'query': _string},
          required: ['query'], handler: (a, ctx) async {
        final words = (_str(a, 'query') ?? '').toLowerCase().split(RegExp(r'\s+')).where((x) => x.length > 1).toList();
        final hits = [
          for (final p in w.catalog.values)
            if (words.any((x) => p.name.toLowerCase().contains(x) || p.sku.contains(x))) p.toJson(),
        ];
        return DartToolResult.json({'products': hits.take(6).toList()});
      }),
      mcpTool('list_baskets',
          description: 'List your baskets (open and checked out).',
          annotations: Hints.read,
          handler: (a, ctx) async => DartToolResult.json({
                'baskets': [for (final b in w.baskets.values) {'basket_id': b.id, 'status': b.open ? 'open' : 'ordered', 'lines': b.lines.length}],
              })),
      mcpTool('create_basket',
          description: 'Start a new empty basket. Returns its basket_id.',
          annotations: Hints.write,
          handler: (a, ctx) async {
        w.applied('create_basket', a, ctx);
        final b = w.addBasket(const {});
        return DartToolResult.json({'basket_id': b.id});
      }),
      mcpTool('view_basket',
          description: 'Show the lines of a basket.',
          annotations: Hints.read,
          properties: {'basket_id': _string},
          required: ['basket_id'], handler: (a, ctx) async {
        final b = w.baskets[_str(a, 'basket_id')];
        return b == null ? DartToolResult.error('No basket with id ${a['basket_id']}.') : DartToolResult.json(view(b));
      }),
      mcpTool('add_item',
          description: 'Add a product (by sku) to a basket. Returns the new line_id.',
          annotations: Hints.write,
          properties: {'basket_id': _string, 'sku': _string, 'quantity': {'type': 'integer', 'minimum': 1}},
          required: ['basket_id', 'sku', 'quantity'], handler: (a, ctx) async {
        final sku = _str(a, 'sku');
        final qty = _int(a, 'quantity');
        if (sku == null || !w.catalog.containsKey(sku)) return DartToolResult.error('Unknown sku ${a['sku']}; use search_products.');
        if (qty == null || qty < 1) return DartToolResult.error('quantity must be a positive integer.');
        late BasketLine line;
        final err = openBasket(a, (b) {
          w.applied('add_item', a, ctx);
          line = BasketLine(w.newId('line'), sku, qty);
          b.lines.add(line);
        });
        return err ?? DartToolResult.json({'line_id': line.id, 'sku': sku, 'quantity': qty});
      }),
      mcpTool('update_item',
          description: 'Change the quantity of a basket line.',
          annotations: Hints.idempotentWrite,
          properties: {'basket_id': _string, 'line_id': _string, 'quantity': {'type': 'integer', 'minimum': 1}},
          required: ['basket_id', 'line_id', 'quantity'], handler: (a, ctx) async {
        final qty = _int(a, 'quantity');
        if (qty == null || qty < 1) return DartToolResult.error('quantity must be a positive integer.');
        String? missing;
        final err = openBasket(a, (b) {
          final l = b.lines.where((l) => l.id == _str(a, 'line_id')).firstOrNull;
          if (l == null) {
            missing = 'No line ${a['line_id']} in basket ${b.id}.';
            return;
          }
          w.applied('update_item', a, ctx);
          l.quantity = qty;
        });
        if (err != null) return err;
        if (missing != null) return DartToolResult.error(missing!);
        return DartToolResult.json(view(w.baskets[_str(a, 'basket_id')]!));
      }),
      mcpTool('remove_item',
          description: 'Remove a line from a basket.',
          annotations: Hints.destructive,
          properties: {'basket_id': _string, 'line_id': _string},
          required: ['basket_id', 'line_id'], handler: (a, ctx) async {
        String? missing;
        final err = openBasket(a, (b) {
          final before = b.lines.length;
          final keep = b.lines.where((l) => l.id != _str(a, 'line_id')).toList();
          if (keep.length == before) {
            missing = 'No line ${a['line_id']} in basket ${b.id}.';
            return;
          }
          w.applied('remove_item', a, ctx);
          b.lines
            ..clear()
            ..addAll(keep);
        });
        if (err != null) return err;
        if (missing != null) return DartToolResult.error(missing!);
        return DartToolResult.json(view(w.baskets[_str(a, 'basket_id')]!));
      }),
      mcpTool('checkout',
          description: 'Place the order for a basket (charges the saved card). Returns the order_id.',
          annotations: Hints.send,
          properties: {'basket_id': _string},
          required: ['basket_id'], handler: (a, ctx) async {
        late Order order;
        String? empty;
        final err = openBasket(a, (b) {
          if (b.lines.isEmpty) {
            empty = 'Basket ${b.id} is empty.';
            return;
          }
          w.applied('checkout', a, ctx);
          // Quantities add up per sku: a duplicated line must show in the order.
          final lines = <String, int>{};
          for (final l in b.lines) {
            lines[l.sku] = (lines[l.sku] ?? 0) + l.quantity;
          }
          order = Order(w.newId('ord'), b.id, lines);
          b.orderId = order.id;
          w.orders.add(order);
        });
        if (err != null) return err;
        if (empty != null) return DartToolResult.error(empty!);
        return DartToolResult.json({'order_id': order.id, 'basket_id': order.basketId, 'items': order.lines});
      }),
    ],
  );
}

/// Builds the named servers over [w].
Map<String, DartMcpServer> stateServers(World w, Iterable<String> ids) => {
      for (final id in ids)
        id: switch (id) {
          'notes' => notesServer(w),
          'calendar' => calendarServer(w),
          'files' => filesServer(w),
          'shop' => shopServer(w),
          _ => throw ArgumentError.value(id, 'ids', 'unknown state server'),
        },
    };

/// A grocery catalog with near-duplicates (oat vs. soy milk, rye vs. white
/// bread), so picking a sku takes reading the search result.
const List<Product> groceryCatalog = [
  Product('milk-oat-1l', 'Oat milk 1 l', 229),
  Product('milk-soy-1l', 'Soy milk 1 l', 199),
  Product('milk-whole-1l', 'Whole milk 1 l', 139),
  Product('bread-rye-500g', 'Rye bread 500 g', 289),
  Product('bread-white-750g', 'White bread 750 g', 199),
  Product('banana-1kg', 'Bananas 1 kg', 179),
  Product('coffee-beans-500g', 'Coffee beans 500 g', 899),
  Product('coffee-ground-250g', 'Ground coffee 250 g', 549),
  Product('eggs-10', 'Free-range eggs, 10', 349),
  Product('tomatoes-500g', 'Cherry tomatoes 500 g', 299),
  Product('pasta-penne-500g', 'Penne pasta 500 g', 129),
  Product('parmesan-200g', 'Parmesan 200 g', 499),
];
