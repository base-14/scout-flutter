import 'package:flutter/widgets.dart';

/// Per-screen scroll-depth aggregator. Wraps a subtree with a
/// `NotificationListener<ScrollNotification>` and computes
/// `display.scroll.*` summary attributes the SDK can attach to the
/// active `screen_view` root span.
///
/// Updates flow through the supplied [onMetrics] callback so the SDK's
/// span emitter can pick them up without this widget knowing about
/// OTel internals.
///
/// Wrap your `MaterialApp` (or whichever root widget you use) with
/// `ScoutFlutter.observeScroll(child: MyApp())` to enable it — one
/// line, applies to every scroll view in the app via Flutter's
/// notification bubbling.
class ScoutScrollObserver extends StatefulWidget {
  const ScoutScrollObserver({
    super.key,
    required this.child,
    required this.onMetrics,
    this.onRouteChange,
  });

  final Widget child;

  /// Fired on every scroll event with the current screen's aggregated
  /// scroll metrics. Called frequently — the SDK throttles its own
  /// downstream span attribute writes.
  final void Function(ScoutScrollMetrics metrics) onMetrics;

  /// Optional hook called when the SDK detects a screen change so the
  /// observer can reset accumulators. Wired via [resetForScreen].
  final void Function(String? screen)? onRouteChange;

  /// Reset the observer's accumulators — call from your navigation
  /// observer when a new screen is entered so each screen reports its
  /// own max-depth.
  static void resetForScreen(BuildContext context) {
    final state = context.findAncestorStateOfType<_ScoutScrollObserverState>();
    state?._reset();
  }

  /// Stateless reset entry-point for SDK code that doesn't have a
  /// BuildContext (e.g. the navigator observer). Use the global handle.
  static _ScoutScrollObserverState? _activeState;
  static void resetGlobal() => _activeState?._reset();

  @override
  State<ScoutScrollObserver> createState() => _ScoutScrollObserverState();
}

class ScoutScrollMetrics {
  /// Largest scroll position reached, in logical pixels (scrollOffset + viewport).
  final double maxDepth;

  /// `scrollOffset` (top of viewport) at the moment [maxDepth] was reached.
  final double maxDepthScrollTop;

  /// Largest `maxScrollExtent + viewportDimension` ever observed for this screen.
  final double maxScrollHeight;

  /// Milliseconds from when this screen started until [maxScrollHeight] was reached.
  final int maxScrollHeightTimeMs;

  const ScoutScrollMetrics({
    required this.maxDepth,
    required this.maxDepthScrollTop,
    required this.maxScrollHeight,
    required this.maxScrollHeightTimeMs,
  });
}

class _ScoutScrollObserverState extends State<ScoutScrollObserver> {
  double _maxDepth = 0;
  double _maxDepthScrollTop = 0;
  double _maxScrollHeight = 0;
  int _maxScrollHeightAt = 0;
  DateTime _screenStartedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    ScoutScrollObserver._activeState = this;
  }

  @override
  void dispose() {
    if (identical(ScoutScrollObserver._activeState, this)) {
      ScoutScrollObserver._activeState = null;
    }
    super.dispose();
  }

  void _reset() {
    setState(() {
      _maxDepth = 0;
      _maxDepthScrollTop = 0;
      _maxScrollHeight = 0;
      _maxScrollHeightAt = 0;
      _screenStartedAt = DateTime.now();
    });
  }

  bool _onScroll(ScrollNotification n) {
    final metrics = n.metrics;
    final viewport = metrics.viewportDimension;
    final offset = metrics.pixels.clamp(0.0, double.maxFinite);
    final depth = offset + viewport;
    final scrollHeight = metrics.maxScrollExtent + viewport;
    var changed = false;
    if (depth > _maxDepth) {
      _maxDepth = depth;
      _maxDepthScrollTop = offset;
      changed = true;
    }
    if (scrollHeight > _maxScrollHeight) {
      _maxScrollHeight = scrollHeight;
      _maxScrollHeightAt =
          DateTime.now().difference(_screenStartedAt).inMilliseconds;
      changed = true;
    }
    if (changed) {
      widget.onMetrics(
        ScoutScrollMetrics(
          maxDepth: _maxDepth,
          maxDepthScrollTop: _maxDepthScrollTop,
          maxScrollHeight: _maxScrollHeight,
          maxScrollHeightTimeMs: _maxScrollHeightAt,
        ),
      );
    }
    return false; // never consume — host scroll behaviour unchanged
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: widget.child,
    );
  }
}
