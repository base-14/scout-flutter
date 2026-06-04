import 'package:flutter/material.dart';

/// Resolves screen name from a route using multiple strategies.
String? _extractScreenName(Route<dynamic> route) {
  // Strategy 1: explicit route name.
  final name = route.settings.name;
  if (name != null) return name;

  // Strategy 2 (Page-based routes) falls through to the post-frame subtree
  // walk, since Page subclasses' default toString returns diagnostic output
  // like `CupertinoPage<dynamic>("null", null, null)` or `Instance of '...'`,
  // not a useful screen name.
  return null;
}

/// A [NavigatorObserver] that automatically extracts screen names
/// from routes without requiring [RouteSettings].
///
/// Name resolution priority:
/// 1. route.settings.name (if user provided RouteSettings)
/// 2. Page child widget class name (covers go_router)
/// 3. Post-frame subtree walk to find top-level page widget runtimeType
/// 4. Route class name (last resort)
class AutoNameNavigatorObserver extends NavigatorObserver {
  final void Function(String screenName)? onScreenChanged;
  final void Function(String screenName, Duration loadTime)? onScreenLoadTime;
  final void Function(String screenName)? onScreenEnter;
  final void Function(String screenName, Duration timeSpent)? onScreenExit;

  /// The most recently resolved screen name.
  String? currentScreenName;

  /// Tracking state for view session duration.
  Stopwatch? _viewStopwatch;
  String? _activeViewName;

  AutoNameNavigatorObserver({
    this.onScreenChanged,
    this.onScreenLoadTime,
    this.onScreenEnter,
    this.onScreenExit,
  });

  void _handlePush(Route<dynamic> route) {
    final stopwatch = Stopwatch()..start();
    final name = _extractScreenName(route);
    if (name != null) {
      // End tracking for the previous view, if any.
      if (_activeViewName != null) {
        _viewStopwatch?.stop();
        onScreenExit?.call(_activeViewName!, _viewStopwatch!.elapsed);
      }
      // Start tracking the new view.
      _activeViewName = name;
      _viewStopwatch = Stopwatch()..start();
      onScreenEnter?.call(name);

      currentScreenName = name;
      onScreenChanged?.call(name);
      // Measure load time after first frame renders.
      if (onScreenLoadTime != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onScreenLoadTime?.call(name, stopwatch.elapsed);
        });
      }
      return;
    }

    // Strategy 3: post-frame subtree walk.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      String resolvedName;
      if (route is ModalRoute) {
        final subtreeContext = route.subtreeContext;
        if (subtreeContext != null) {
          final widgetName = _findPageWidgetName(subtreeContext as Element);
          resolvedName = widgetName ?? route.runtimeType.toString();
        } else {
          resolvedName = route.runtimeType.toString();
        }
      } else {
        resolvedName = route.runtimeType.toString();
      }

      // End tracking for the previous view, if any.
      if (_activeViewName != null) {
        _viewStopwatch?.stop();
        onScreenExit?.call(_activeViewName!, _viewStopwatch!.elapsed);
      }
      // Start tracking the new view.
      _activeViewName = resolvedName;
      _viewStopwatch = Stopwatch()..start();
      onScreenEnter?.call(resolvedName);

      currentScreenName = resolvedName;
      onScreenChanged?.call(resolvedName);
      onScreenLoadTime?.call(resolvedName, stopwatch.elapsed);
    });
  }

  void _handlePop(Route<dynamic>? previousRoute) {
    if (previousRoute == null) return;

    // End tracking for the current (popped) view.
    if (_activeViewName != null) {
      _viewStopwatch?.stop();
      onScreenExit?.call(_activeViewName!, _viewStopwatch!.elapsed);
    }

    final name = _extractScreenName(previousRoute);
    if (name != null) {
      // Start tracking the previous view we're returning to.
      _activeViewName = name;
      _viewStopwatch = Stopwatch()..start();
      onScreenEnter?.call(name);

      currentScreenName = name;
      onScreenChanged?.call(name);
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _handlePush(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null) _handlePush(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _handlePop(previousRoute);
  }

  /// Walk the element subtree to find the first "meaningful" widget name.
  ///
  /// Skips known Flutter framework wrapper/internal widgets and returns the
  /// first widget type that looks like a user-defined page widget.
  static String? _findPageWidgetName(Element rootElement) {
    String? result;

    void visitor(Element element) {
      if (result != null) return;

      final widget = element.widget;
      final typeName = widget.runtimeType.toString();

      // Skip known Flutter framework widgets (both public and private).
      // This set covers layout, theming, navigation, animation, and
      // scaffold-related widgets that wrap user page content.
      if (_isFrameworkWidget(typeName)) {
        element.visitChildren(visitor);
        return;
      }

      result = typeName;
    }

    rootElement.visitChildren(visitor);
    return result;
  }

  /// Returns true if [typeName] is a known Flutter framework widget that
  /// should be skipped during the subtree walk.
  static bool _isFrameworkWidget(String typeName) {
    // Generic type suffixes (e.g. _ModalScope<dynamic>).
    final baseName =
        typeName.contains('<')
            ? typeName.substring(0, typeName.indexOf('<'))
            : typeName;

    const knownFrameworkWidgets = {
      // Layout
      'Scaffold', 'CupertinoPageScaffold', 'Material', 'Builder',
      'SafeArea', 'Padding', 'Center', 'SizedBox', 'Container',
      'Column', 'Row', 'Expanded', 'Flexible', 'Offstage',
      'RepaintBoundary', 'KeyedSubtree', 'IgnorePointer',
      'AbsorbPointer', 'Listener', 'PageStorage',
      // Theme / inherited
      'MediaQuery', 'Directionality', 'Title', 'AnimatedTheme',
      'Theme', 'CupertinoTheme', 'IconTheme', 'DefaultTextStyle',
      'DefaultSelectionStyle', 'InheritedCupertinoTheme',
      'Localizations', 'Banner', 'CheckedModeBanner', 'CustomPaint',
      // Focus / actions / shortcuts
      'Actions', 'Shortcuts', 'Focus', 'FocusScope',
      'FocusTraversalGroup', 'PrimaryScrollController',
      'TapRegionSurface', 'ShortcutRegistrar',
      // Scrolling
      'ScrollConfiguration', 'HeroControllerScope',
      'ScrollNotificationObserver', 'NotificationListener',
      'CustomScrollView', 'Scrollable', 'Viewport',
      'ShrinkWrappingViewport',
      // Animation / transitions
      'AnimatedBuilder', 'ListenableBuilder', 'AnimatedPhysicalModel',
      'AnimatedDefaultTextStyle', 'PhysicalModel',
      'DualTransitionBuilder', 'SnapshotWidget', 'Transform',
      'ScaleTransition', 'RotationTransition', 'Stack',
      'ValueListenableBuilder',
      // Navigation internals
      'Navigator', 'Overlay', 'TickerMode', 'Semantics',
      'RestorationScope', 'UnmanagedRestorationScope',
      'RootRestorationScope', 'WidgetsApp', 'SharedAppData',
      'ScaffoldMessenger', 'CustomMultiChildLayout', 'LayoutId',
      'Text', 'RichText',
    };

    if (knownFrameworkWidgets.contains(baseName)) return true;

    // Skip private Flutter framework widgets (prefixed with _) that are
    // clearly internal, identified by common framework-internal patterns.
    if (baseName.startsWith('_')) {
      const knownInternalPrefixes = [
        '_ModalScope',
        '_ModalScopeStatus',
        '_FocusInheritedScope',
        '_InheritedTheme',
        '_ActionsScope',
        '_ScaffoldScope',
        '_ScaffoldMessengerScope',
        '_LocalizationsScope',
        '_SharedAppModel',
        '_OverlayEntryWidget',
        '_Theater',
        '_RenderTheaterMarker',
        '_EffectiveTickerMode',
        '_FocusScopeWithExternalFocusNode',
        '_ShortcutRegistrarScope',
        '_InkFeatures',
        '_BodyBuilder',
        '_FloatingActionButtonTransition',
        '_ZoomPageTransition',
        '_ZoomEnterTransition',
        '_ZoomExitTransition',
        '_PageTransitionsThemeTransitions',
        '_ScrollNotificationObserverScope',
      ];
      for (final prefix in knownInternalPrefixes) {
        if (baseName == prefix) return true;
      }
    }

    return false;
  }
}
