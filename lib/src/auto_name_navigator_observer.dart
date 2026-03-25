import 'package:flutter/material.dart';

/// Resolves screen name from a route using multiple strategies.
String? _extractScreenName(Route<dynamic> route) {
  // Strategy 1: explicit route name.
  final name = route.settings.name;
  if (name != null) return name;

  // Strategy 2: Page-based routes (go_router, declarative nav).
  final settings = route.settings;
  try {
    if (settings is Page) {
      final pageString = settings.toString();
      if (pageString.isNotEmpty && pageString != 'null') {
        return pageString;
      }
    }
  } catch (_) {}

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

  AutoNameNavigatorObserver({this.onScreenChanged});

  void _handlePush(Route<dynamic> route) {
    final name = _extractScreenName(route);
    if (name != null) {
      onScreenChanged?.call(name);
      return;
    }

    // Strategy 3: post-frame subtree walk.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route is ModalRoute) {
        final subtreeContext = route.subtreeContext;
        if (subtreeContext != null) {
          final widgetName = _findPageWidgetName(subtreeContext as Element);
          final resolvedName = widgetName ?? route.runtimeType.toString();
          onScreenChanged?.call(resolvedName);
          return;
        }
      }
      // Strategy 4: route class name.
      onScreenChanged?.call(route.runtimeType.toString());
    });
  }

  void _handlePop(Route<dynamic>? previousRoute) {
    if (previousRoute == null) return;
    final name = _extractScreenName(previousRoute);
    if (name != null) {
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
