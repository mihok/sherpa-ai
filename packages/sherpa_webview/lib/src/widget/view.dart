/// The inline MCP App widget and its fullscreen route.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../protocol/host_context.dart';
import 'controller.dart';

/// Renders an [McpAppController] inline in the chat, with host chrome the
/// View cannot draw over: a `Content from <server>` label, an expand
/// button (fullscreen route hosting the SAME WebView), a loading state and
/// an error state with retry and an optional [fallback] (normally the tool
/// result's text content, which servers must always provide).
///
/// The widget starts the controller when it mounts and asks the user for
/// network consent through the controller's callbacks first.
class McpAppView extends StatefulWidget {
  const McpAppView({
    super.key,
    required this.controller,
    this.initialHeight = 200,
    this.minHeight = 56,
    this.maxHeight,
    this.fallback,
    this.allowFullscreen = true,
  });

  final McpAppController controller;

  /// Height before the View reports its size.
  final double initialHeight;
  final double minHeight;

  /// Cap for the inline height; defaults to 70 % of the screen height. A
  /// taller View scrolls inside its frame.
  final double? maxHeight;

  /// Shown under the error message (e.g. the tool's text result).
  final Widget? fallback;

  final bool allowFullscreen;

  @override
  State<McpAppView> createState() => _McpAppViewState();
}

class _McpAppViewState extends State<McpAppView> {
  Route<void>? _route;

  McpAppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _install(_c);
  }

  @override
  void didUpdateWidget(McpAppView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      _uninstall(old.controller);
      _install(widget.controller);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    _c.updateEnvironment(
      theme: brightness == Brightness.dark ? McpAppTheme.dark : McpAppTheme.light,
      locale: Localizations.maybeLocaleOf(context)?.toLanguageTag(),
    );
  }

  void _install(McpAppController c) {
    c.displayModePresenter = _present;
    if (c.status == McpAppViewStatus.idle || c.status == McpAppViewStatus.suspended) {
      // After this build: start() notifies listeners.
      scheduleMicrotask(() {
        if (mounted && widget.controller == c) unawaited(c.start());
      });
    }
  }

  void _uninstall(McpAppController c) {
    if (c.displayModePresenter == _present) c.displayModePresenter = null;
  }

  @override
  void dispose() {
    _uninstall(_c);
    super.dispose();
  }

  Future<bool> _present(McpAppDisplayMode mode) async {
    if (!mounted) return false;
    switch (mode) {
      case McpAppDisplayMode.fullscreen:
        if (_c.displayMode == McpAppDisplayMode.fullscreen) return true;
        final nav = Navigator.maybeOf(context);
        if (nav == null) return false;
        final route = McpAppFullscreenRoute(controller: _c);
        _route = route;
        // Same frame as the push: the surface (GlobalKey) moves from this
        // slot into the route without recreating the WebView.
        _c.setDisplayMode(McpAppDisplayMode.fullscreen);
        unawaited(nav.push(route).whenComplete(() {
          if (_route == route) _route = null;
          _c.setDisplayMode(McpAppDisplayMode.inline);
        }));
        return true;
      case McpAppDisplayMode.inline:
        final route = _route;
        _c.setDisplayMode(McpAppDisplayMode.inline);
        if (route != null && route.isActive) {
          if (route.isCurrent) {
            route.navigator?.pop();
          } else {
            route.navigator?.removeRoute(route);
          }
        }
        return true;
      case McpAppDisplayMode.pip:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final status = _c.status;
        final inline = _c.displayMode == McpAppDisplayMode.inline;
        final live = status == McpAppViewStatus.loading || status == McpAppViewStatus.ready;
        final border = _c.session.resource.prefersBorder ?? true;
        return DecoratedBox(
          decoration: BoxDecoration(
            border: border ? Border.all(color: scheme.outlineVariant) : null,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                McpAppSourceLabel(
                  serverName: _c.session.serverName,
                  onExpand: widget.allowFullscreen && inline && live
                      ? () => unawaited(_c.requestDisplayMode(McpAppDisplayMode.fullscreen))
                      : null,
                ),
                _body(context, status, inline: inline),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context, McpAppViewStatus status, {required bool inline}) {
    final maxH = widget.maxHeight ?? MediaQuery.sizeOf(context).height * 0.7;
    final height = (_c.contentHeight ?? widget.initialHeight).clamp(widget.minHeight, maxH < widget.minHeight ? widget.minHeight : maxH);
    switch (status) {
      case McpAppViewStatus.error:
        return McpAppErrorPanel(message: _c.errorMessage ?? 'Something went wrong.', onRetry: _c.retry, fallback: widget.fallback);
      case McpAppViewStatus.closed:
        return const SizedBox(height: 0);
      case McpAppViewStatus.suspended:
        return SizedBox(
          height: height,
          child: Center(
            child: TextButton.icon(
              onPressed: () => unawaited(_c.start()),
              icon: const Icon(Icons.refresh),
              label: const Text('Reload interactive content'),
            ),
          ),
        );
      case McpAppViewStatus.idle || McpAppViewStatus.consent || McpAppViewStatus.starting:
        return SizedBox(
          height: widget.initialHeight.clamp(widget.minHeight, maxH < widget.minHeight ? widget.minHeight : maxH),
          child: McpAppLoading(
            label: status == McpAppViewStatus.consent ? 'Waiting for your network decision…' : 'Loading interactive content…',
          ),
        );
      case McpAppViewStatus.loading || McpAppViewStatus.ready:
        if (!inline) {
          return SizedBox(
            height: widget.minHeight,
            child: Center(
              child: TextButton.icon(
                onPressed: () => unawaited(_present(McpAppDisplayMode.inline)),
                icon: const Icon(Icons.close_fullscreen),
                label: const Text('Showing full screen — show here'),
              ),
            ),
          );
        }
        return LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _c.displayMode != McpAppDisplayMode.inline) return;
            _c.reportLayout(
              dimensions: McpAppContainerDimensions(width: width.isFinite ? width : null, maxHeight: maxH),
            );
          });
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                McpAppSurface(key: _c.surfaceKey, controller: _c),
                if (status == McpAppViewStatus.loading)
                  ColoredBox(
                    color: Theme.of(context).colorScheme.surface,
                    child: const McpAppLoading(label: 'Loading interactive content…'),
                  ),
              ],
            ),
          );
        });
    }
  }
}

/// The slot that hosts the platform view. Keyed with
/// [McpAppController.surfaceKey], so moving it between the inline view and
/// the fullscreen route keeps the same WebView.
class McpAppSurface extends StatefulWidget {
  const McpAppSurface({super.key, required this.controller});

  final McpAppController controller;

  @override
  State<McpAppSurface> createState() => _McpAppSurfaceState();
}

class _McpAppSurfaceState extends State<McpAppSurface> {
  late final McpAppController _controller = widget.controller;

  // Inline: the WebView gets taps, long presses and horizontal drags; the
  // chat keeps vertical scrolling (no nested-scroll trap). Fullscreen: all.
  static final Set<Factory<OneSequenceGestureRecognizer>> _inline = {
    Factory<OneSequenceGestureRecognizer>(TapGestureRecognizer.new),
    Factory<OneSequenceGestureRecognizer>(LongPressGestureRecognizer.new),
    Factory<OneSequenceGestureRecognizer>(HorizontalDragGestureRecognizer.new),
  };
  static final Set<Factory<OneSequenceGestureRecognizer>> _all = {
    Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
  };

  @override
  void initState() {
    super.initState();
    _controller.attachSurface();
  }

  @override
  void dispose() {
    _controller.detachSurface();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final native = _controller.nativeView;
    if (native == null) return const SizedBox.expand();
    return Semantics(
      container: true,
      label: 'Interactive content from ${_controller.session.serverName}',
      child: native.build(
        context,
        gestureRecognizers: _controller.displayMode == McpAppDisplayMode.fullscreen ? _all : _inline,
      ),
    );
  }
}

/// The fullscreen route. It hosts the controller's surface while the
/// controller's display mode is fullscreen.
class McpAppFullscreenRoute extends MaterialPageRoute<void> {
  McpAppFullscreenRoute({required McpAppController controller})
      : super(builder: (_) => McpAppFullscreenPage(controller: controller), fullscreenDialog: true);
}

class McpAppFullscreenPage extends StatelessWidget {
  const McpAppFullscreenPage({super.key, required this.controller});

  final McpAppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final status = controller.status;
        final live = status == McpAppViewStatus.loading || status == McpAppViewStatus.ready;
        final showing = live && controller.displayMode == McpAppDisplayMode.fullscreen;
        return Scaffold(
          appBar: AppBar(
            leading: const CloseButton(),
            titleSpacing: 0,
            title: McpAppSourceLabel(serverName: controller.session.serverName, dense: false),
          ),
          body: LayoutBuilder(builder: (context, constraints) {
            final padding = MediaQuery.viewPaddingOf(context);
            if (showing) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (controller.displayMode != McpAppDisplayMode.fullscreen) return;
                controller.reportLayout(
                  dimensions: McpAppContainerDimensions(width: constraints.maxWidth, height: constraints.maxHeight),
                  insets: McpAppInsets(left: padding.left, right: padding.right, bottom: padding.bottom),
                );
              });
            }
            if (status == McpAppViewStatus.error) {
              return McpAppErrorPanel(message: controller.errorMessage ?? 'Something went wrong.', onRetry: controller.retry);
            }
            if (!showing) return const SizedBox.expand();
            return Stack(
              fit: StackFit.expand,
              children: [
                McpAppSurface(key: controller.surfaceKey, controller: controller),
                if (status == McpAppViewStatus.loading)
                  const ColoredBox(color: Colors.transparent, child: McpAppLoading(label: 'Loading interactive content…')),
              ],
            );
          }),
        );
      },
    );
  }
}

/// `Content from <server>`: drawn by the host, outside the WebView.
class McpAppSourceLabel extends StatelessWidget {
  const McpAppSourceLabel({super.key, required this.serverName, this.onExpand, this.dense = true});

  final String serverName;
  final VoidCallback? onExpand;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = (dense ? theme.textTheme.labelMedium : theme.textTheme.titleSmall)
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: dense ? 12 : 0, vertical: dense ? 4 : 0),
      child: Row(
        children: [
          Icon(Icons.widgets_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Content from $serverName',
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onExpand != null)
            IconButton(
              tooltip: 'Open full screen',
              icon: const Icon(Icons.open_in_full, size: 18),
              onPressed: onExpand,
            ),
        ],
      ),
    );
  }
}

class McpAppLoading extends StatelessWidget {
  const McpAppLoading({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
        label: label,
        liveRegion: true,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
              const SizedBox(height: 8),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );
}

class McpAppErrorPanel extends StatelessWidget {
  const McpAppErrorPanel({super.key, required this.message, this.onRetry, this.fallback});

  final String message;
  final Future<void> Function()? onRetry;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, color: theme.colorScheme.error, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(message, style: theme.textTheme.bodyMedium)),
              if (onRetry != null)
                TextButton(onPressed: () => unawaited(onRetry!()), child: const Text('Retry')),
            ],
          ),
          if (fallback != null) ...[const SizedBox(height: 8), fallback!],
        ],
      ),
    );
  }
}
