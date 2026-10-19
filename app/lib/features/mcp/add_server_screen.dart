import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../design/widgets/a11y.dart';
import '../../design/widgets/section_header.dart';
import '../../routing/routes.dart';
import '../../services/mcp/deep_link.dart';
import '../../services/mcp/mcp_records.dart';
import '../../services/mcp/server_probe.dart';
import '../../state/ui_preferences.dart';
import '../settings/settings_page.dart';
import 'state/mcp_providers.dart';
import 'widgets/mcp_widgets.dart';

/// Opens the camera and returns the scanned text. A seam for tests.
typedef McpCodeScanner = Future<String?> Function(BuildContext context);

final mcpCodeScannerProvider = Provider<McpCodeScanner>((ref) => McpScanPage.open);

/// Whether a camera scanner can be offered on this platform.
final mcpCanScanProvider = Provider<bool>(
  (ref) => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS),
);

/// Settings › Tools & servers › Add a server.
///
/// By address (validated with the URL policy, then probed so the user sees
/// which protocol era it speaks), from the MCP Registry, or from a QR code.
/// A deep link or a scanned code only fills the form: nothing is added
/// until the user confirms.
class AddServerScreen extends ConsumerStatefulWidget {
  const AddServerScreen({
    super.key,
    this.initialUrl,
    this.initialName,
    this.source = McpServerSource.url,
    this.registryName,
    this.description,
  });

  final String? initialUrl;
  final String? initialName;
  final McpServerSource source;
  final String? registryName;
  final String? description;

  @override
  ConsumerState<AddServerScreen> createState() => _AddServerScreenState();
}

sealed class _Check {
  const _Check();
}

final class _Idle extends _Check {
  const _Idle();
}

final class _Checking extends _Check {
  const _Checking();
}

final class _Checked extends _Check {
  const _Checked(this.url, this.local, this.report);

  final Uri url;
  final bool local;
  final McpProbeReport report;
}

final class _Invalid extends _Check {
  const _Invalid(this.message, {this.existingId});

  final String message;
  final String? existingId;
}

class _AddServerScreenState extends ConsumerState<AddServerScreen> {
  late final TextEditingController _url = TextEditingController(text: widget.initialUrl ?? '');
  late final TextEditingController _name = TextEditingController(text: widget.initialName ?? '');
  late McpServerSource _source = widget.source;
  bool? _local;
  _Check _check = const _Idle();
  bool _adding = false;

  bool get _fromOutside => _source == McpServerSource.link || _source == McpServerSource.qr;

  @override
  void initState() {
    super.initState();
    _url.addListener(_onUrlEdited);
  }

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  String _lastUrl = '';

  void _onUrlEdited() {
    if (_url.text == _lastUrl) return;
    _lastUrl = _url.text;
    if (_check is! _Idle) setState(() => _check = const _Idle());
  }

  bool get _localValue {
    final l = _local;
    if (l != null) return l;
    final u = Uri.tryParse(_url.text.contains('://') ? _url.text.trim() : 'https://${_url.text.trim()}');
    return u != null && u.host.isNotEmpty && McpUrlValidator.looksLocal(u);
  }

  Future<void> _runCheck() async {
    if (_check is _Checking) return;
    setState(() => _check = const _Checking());
    final rt = ref.read(mcpRuntimeProvider);
    final result = await ref.read(mcpUrlValidatorProvider).check(_url.text, local: _local);
    if (!mounted) return;
    final url = result.url;
    if (url == null) {
      ref.read(hapticsProvider).error();
      setState(() => _check = _Invalid(result.error!));
      return;
    }
    final existing = rt.serverForUrl(url);
    if (existing != null) {
      setState(() => _check = _Invalid('This server is already added as "${existing.name}".', existingId: existing.id));
      return;
    }
    final report = await ref.read(mcpProberProvider).probe(McpServerConfig(
          id: 'probe',
          name: _name.text.trim().isEmpty ? url.host : _name.text.trim(),
          url: url,
          allowLocalNetwork: result.local,
        ));
    if (!mounted) return;
    if (_name.text.trim().isEmpty && report.serverName != null) {
      final n = report.serverName!.trim();
      if (n.isNotEmpty) _name.text = n.length > 60 ? n.substring(0, 60) : n;
    }
    report.reachable || report.needsAuth ? ref.read(hapticsProvider).success() : ref.read(hapticsProvider).warning();
    setState(() => _check = _Checked(url, result.local, report));
  }

  Future<void> _add() async {
    final c = _check;
    if (c is! _Checked || _adding) return;
    setState(() => _adding = true);
    try {
      final config = await ref.read(mcpRuntimeProvider).addServer(
            url: c.url,
            name: _name.text,
            allowLocalNetwork: c.local,
            source: _source,
            registryName: widget.registryName,
            description: widget.description,
            verdict: c.report.verdict,
          );
      ref.read(hapticsProvider).success();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added ${config.name}')));
      context.go(Routes.toolServer(config.id));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _scan() async {
    final raw = await ref.read(mcpCodeScannerProvider)(context);
    if (!mounted || raw == null) return;
    final link = McpAddLink.parse(raw, source: McpServerSource.qr);
    if (link == null) {
      ref.read(hapticsProvider).error();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("That code doesn't contain a server address.")));
      return;
    }
    setState(() {
      _url.text = link.url;
      _lastUrl = link.url;
      if (link.name != null) _name.text = link.name!;
      _source = McpServerSource.qr;
      _local = null;
      _check = const _Idle();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final check = _check;
    final canScan = ref.watch(mcpCanScanProvider);
    final checked = check is _Checked ? check : null;
    final canAdd = checked != null && !_adding;
    return SettingsPage(
      title: _fromOutside ? 'Add this server?' : 'Add a server',
      bottom: Wrap(
        alignment: WrapAlignment.end,
        spacing: t.space.sm,
        runSpacing: t.space.sm,
        children: [
          if (_fromOutside) TextButton(onPressed: () => context.go(Routes.tools), child: const Text('Cancel')),
          OutlinedButton.icon(
            onPressed: check is _Checking ? null : () => unawaited(_runCheck()),
            icon: check is _Checking
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.network_check_rounded),
            label: Text(check is _Checking ? 'Checking…' : 'Check server'),
          ),
          FilledButton.icon(
            onPressed: canAdd ? () => unawaited(_add()) : null,
            icon: const Icon(Icons.add_rounded),
            label: Text(checked != null && !checked.report.reachable && !checked.report.needsAuth ? 'Add anyway' : 'Add server'),
          ),
        ],
      ),
      children: [
        if (_fromOutside) ...[
          SizedBox(height: t.space.md),
          SettingsPadding(
            child: NoteBox(
              title: _source == McpServerSource.qr ? 'From a scanned code' : 'From a link',
              icon: Icons.link_rounded,
              tone: NoteTone.warning,
              text: 'Something asked Sherpa to add this tool server. Nothing is added until you tap "Add server". '
                  'Only add servers you trust: the assistant may send them what you share in a chat.',
            ),
          ),
        ] else if (_source == McpServerSource.registry) ...[
          SizedBox(height: t.space.md),
          SettingsPadding(
            child: NoteBox(
              title: 'From the MCP Registry',
              text: 'Listed by its publisher${widget.registryName == null ? '' : ' as ${widget.registryName}'}. '
                  'The registry does not review servers; check that you trust it.',
            ),
          ),
        ] else ...[
          const SectionHeader('Find a server'),
          ListTile(
            leading: const Icon(Icons.travel_explore_rounded),
            title: const Text('Browse the MCP Registry'),
            subtitle: const Text('Public servers you can use from a phone'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go(Routes.toolRegistry),
          ),
          if (canScan)
            ListTile(
              leading: const Icon(Icons.qr_code_scanner_rounded),
              title: const Text('Scan a QR code'),
              subtitle: const Text('A code with a server address or an "Add to Sherpa" link'),
              onTap: () => unawaited(_scan()),
            ),
        ],
        const SectionHeader('Server'),
        SettingsPadding(
          child: TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'Server address',
              hintText: 'https://example.com/mcp',
              errorText: check is _Invalid ? check.message : null,
              errorMaxLines: 3,
              helperText: 'The MCP endpoint, often ending in /mcp (or /sse for older servers).',
              helperMaxLines: 2,
            ),
            onSubmitted: (_) => unawaited(_runCheck()),
          ),
        ),
        if (check is _Invalid && check.existingId != null)
          SettingsPadding(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => context.go(Routes.toolServer(check.existingId!)),
                child: const Text('Open it'),
              ),
            ),
          ),
        SizedBox(height: t.space.md),
        SettingsPadding(
          child: TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Name', helperText: 'How the server appears in Sherpa.'),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.router_outlined),
          title: const Text('Server on my network'),
          subtitle: const Text('Allows plain http and local addresses, for a server on this phone or your Wi-Fi. '
              'Never for an internet address.'),
          isThreeLine: true,
          value: _localValue,
          onChanged: (v) => setState(() {
            _local = v;
            _check = const _Idle();
          }),
        ),
        if (check is _Checked) ...[
          const SectionHeader('What Sherpa found'),
          SettingsPadding(
            child: Semantics(container: true, liveRegion: true, child: _ReportCard(report: check.report)),
          ),
        ],
        SizedBox(height: t.space.lg),
        SettingsPadding(
          child: Text(
            'New tools from a server you have not marked as trusted stay blocked until you review them.',
            style: muted,
          ),
        ),
      ],
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report});

  final McpProbeReport report;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    if (report.needsAuth) {
      return const NoteBox(
        title: 'Sign-in required',
        icon: Icons.lock_outline_rounded,
        text: 'The server answered and needs you to sign in. Add it, then tap "Sign in"; '
            'Sherpa shows you where you will sign in before opening anything.',
      );
    }
    final error = report.error;
    if (error != null) {
      return NoteBox(
        title: "Couldn't connect",
        icon: Icons.error_outline_rounded,
        tone: NoteTone.danger,
        text: '$error You can still add it if the server is only offline right now.',
      );
    }
    final lines = [
      if (report.eraLabel != null) ('Protocol', report.eraLabel!),
      if (report.serverName != null)
        ('Calls itself', '${report.serverName}${report.serverVersion == null || report.serverVersion!.isEmpty ? '' : ' ${report.serverVersion}'}'),
      if (report.toolCount != null) ('Tools', '${report.toolCount}'),
      if (report.hasResources || report.hasPrompts)
        ('Also offers', [if (report.hasResources) 'resources', if (report.hasPrompts) 'prompts'].join(' and ')),
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(t.space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle_rounded, color: t.semantic.success),
                SizedBox(width: t.space.sm),
                Expanded(child: Text('The server answered', style: Theme.of(context).textTheme.titleSmall)),
              ],
            ),
            for (final (k, v) in lines)
              Padding(
                padding: EdgeInsets.only(top: t.space.sm),
                child: Semantics(
                  label: '$k: $v',
                  excludeSemantics: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(k, style: Theme.of(context).textTheme.labelMedium),
                      Text(v),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Camera scanner for server codes (a bare https address or an
/// `sherpa://mcp/add` link); returns the first such code.
class McpScanPage extends StatefulWidget {
  const McpScanPage({super.key});

  static Future<String?> open(BuildContext context) =>
      Navigator.of(context).push<String>(MotionPageRoute(builder: (_) => const McpScanPage()));

  @override
  State<McpScanPage> createState() => _McpScanPageState();
}

class _McpScanPageState extends State<McpScanPage> {
  final MobileScannerController _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;
  bool _sawOther = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw != null && McpAddLink.parse(raw) != null) {
        _done = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
    if (!_sawOther) setState(() => _sawOther = true);
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Heading(level: 1, child: const Text('Scan a server code')),
        actions: [
          IconButton(tooltip: 'Flashlight', icon: const Icon(Icons.flashlight_on_outlined), onPressed: _controller.toggleTorch),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Semantics(
              label: 'Camera view',
              child: MobileScanner(
                controller: _controller,
                onDetect: _onDetect,
                errorBuilder: (context, error) => Center(
                  child: Padding(
                    padding: EdgeInsets.all(t.space.xl),
                    child: Text(
                      error.errorCode == MobileScannerErrorCode.permissionDenied
                          ? 'Sherpa is not allowed to use the camera. Allow it in your system settings, or type the address instead.'
                          : "The camera couldn't start. Go back and type the address instead.",
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(t.space.lg),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _sawOther
                    ? "That code doesn't contain a server address."
                    : 'Point the camera at a code with a tool server address. You confirm before anything is added.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
