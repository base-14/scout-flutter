import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'scout_rum_config.dart';
import 'user_action_annotation.dart';
import 'uuid.dart';

const _tapSlop = 20;
const _tapSlopSquared = _tapSlop * _tapSlop;

class _ElementDescription {
  final Element element;
  final String elementName;
  final String elementDescription;
  final String nameSource;
  final bool tryForBetter;

  const _ElementDescription({
    required this.element,
    required this.elementName,
    required this.elementDescription,
    required this.nameSource,
    this.tryForBetter = false,
  });

  bool betterThan(_ElementDescription? other) {
    if (other == null) return true;
    if (element.widget is GestureDetector) {
      if (other.element.widget is InkWell &&
          elementDescription != other.elementDescription) {
        return true;
      }
      return other.element.widget is GestureDetector;
    }
    return true;
  }
}

class _TreeAnnotation {
  final String? description;
  final Map<String, Object?>? attributes;

  /// Where the description came from:
  ///   'standard_attribute' — RumUserActionAnnotation / Semantics / Icon.semanticLabel
  ///   'text_content'       — Text widget's `data` field
  ///   'blank'              — none of the above; description is null / 'unknown'
  final String source;
  const _TreeAnnotation(this.description, this.source, [this.attributes]);
}

/// Tap details handed to [GlobalTapDetector.onTapDetected].
class TapDetails {
  final String elementName;
  final String elementDescription;

  /// 'standard_attribute' (a11y label / annotation), 'text_content'
  /// (matched Text widget), or 'blank' (nothing usable found).
  final String nameSource;

  /// Stable hash of the widget-runtime-type chain from the tapped
  /// element up to the root. Lets a backend group taps on the "same"
  /// element across sessions / re-renders without needing to know the
  /// component name.
  final String permanentId;

  /// Global tap position in logical pixels.
  final Offset position;

  const TapDetails({
    required this.elementName,
    required this.elementDescription,
    required this.nameSource,
    required this.permanentId,
    required this.position,
  });
}

/// Detects taps globally via [GestureBinding.pointerRouter].
/// No widget wrapper needed — just call [start] after binding is initialized.
class GlobalTapDetector {
  final void Function(TapDetails details) onTapDetected;
  final CustomGestureElementDetector? customGestureDetector;
  final _pointerDownPositions = <int, Offset>{};

  GlobalTapDetector({required this.onTapDetected, this.customGestureDetector});

  void start() {
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handleEvent);
  }

  void stop() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_handleEvent);
  }

  void _handleEvent(PointerEvent event) {
    if (event is PointerDownEvent) {
      _pointerDownPositions[event.pointer] = event.position;
    } else if (event is PointerUpEvent) {
      final downPos = _pointerDownPositions.remove(event.pointer);
      if (downPos != null) {
        final delta = event.position - downPos;
        if (delta.distanceSquared < _tapSlopSquared) {
          _detectTapAt(event.position);
        }
      }
    } else if (event is PointerCancelEvent) {
      _pointerDownPositions.remove(event.pointer);
    }
  }

  void _detectTapAt(Offset globalPosition) {
    final description = _detectElementAtPosition(globalPosition);
    if (description != null) {
      onTapDetected(
        TapDetails(
          elementName: description.elementName,
          elementDescription: description.elementDescription,
          nameSource: description.nameSource,
          permanentId: _buildPermanentId(description.element),
          position: globalPosition,
        ),
      );
    }
  }

  /// djb2-hash of the widget runtime-type chain (deepest first, up to
  /// 8 ancestors). Stable across re-renders and builds — different
  /// elements with the same lineage produce the same hash, which is
  /// exactly the grouping behaviour `target.permanent_id` is meant to
  /// give backend dashboards.
  String _buildPermanentId(Element element) {
    final parts = <String>[element.widget.runtimeType.toString()];
    element.visitAncestorElements((ancestor) {
      parts.add(ancestor.widget.runtimeType.toString());
      return parts.length < 8;
    });
    return djb2Hash(parts.reversed.join('>'));
  }

  _ElementDescription? _detectElementAtPosition(Offset globalPosition) {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return null;

    _ElementDescription? best;
    _TreeAnnotation? treeAnnotation;

    void visitor(Element element) {
      if (best?.tryForBetter == false) return;

      final ro = element.renderObject;
      // If this element has a RenderBox, check bounds. If the position is
      // outside, prune the entire subtree.
      if (ro != null && ro is RenderBox && ro.hasSize) {
        final transform = ro.getTransformTo(null);
        final paintBounds = MatrixUtils.transformRect(
          transform,
          ro.paintBounds,
        );

        if (!paintBounds.contains(globalPosition)) return;
      }

      final w = element.widget;
      if (w is RumUserActionAnnotation) {
        treeAnnotation = _TreeAnnotation(
          w.description,
          'standard_attribute',
          w.attributes,
        );
      } else {
        final candidate = _classifyElement(element, treeAnnotation);
        if (candidate != null && candidate.betterThan(best)) {
          best = candidate;
        }
      }

      if (best?.tryForBetter != false) {
        element.visitChildElements(visitor);
      }
      treeAnnotation = null;
    }

    rootElement.visitChildElements(visitor);

    // Fallback: if best match has "unknown" label, search subtree for text.
    if (best != null && best!.elementDescription == 'unknown') {
      final fallback = _findInnerText(best!.element, true);
      if (fallback?.description != null) {
        best = _ElementDescription(
          element: best!.element,
          elementName: best!.elementName,
          elementDescription: fallback!.description!,
          nameSource: fallback.source,
          tryForBetter: false,
        );
      }
    }

    return best;
  }

  _TreeAnnotation? _findInnerText(Element element, bool allowText) {
    String? description;
    Map<String, Object?>? attributes;
    String source = 'blank';
    bool stopSiblings = false;

    void visitor(Element el) {
      if (stopSiblings) return;
      bool stop = false;
      final w = el.widget;

      if (w is RumUserActionAnnotation) {
        description = w.description;
        attributes = w.attributes;
        source = 'standard_attribute';
        stop = true;
        stopSiblings = true;
      } else if (allowText && w is Text) {
        if (w.data?.isNotEmpty ?? false) {
          description = w.data!;
          source = 'text_content';
          stop = true;
        }
      } else if (w is Semantics) {
        if (w.properties.label?.isNotEmpty ?? false) {
          description = w.properties.label!;
          source = 'standard_attribute';
          stop = true;
        }
      } else if (w is Icon) {
        if (w.semanticLabel?.isNotEmpty ?? false) {
          description = w.semanticLabel!;
          source = 'standard_attribute';
          stop = true;
        }
      }

      if (!stop) {
        el.visitChildren(visitor);
      }
    }

    element.visitChildren(visitor);
    return _TreeAnnotation(description, source, attributes);
  }

  _ElementDescription? _classifyElement(
    Element element,
    _TreeAnnotation? treeAnnotation,
  ) {
    final w = element.widget;
    String? name;
    bool searchForBetter = false;
    bool searchForText = true;

    final custom = customGestureDetector?.call(w);
    if (custom != null) {
      name = custom.elementName;
      searchForBetter = custom.searchForBetter;
      searchForText = custom.searchForText;
    } else if (w is ButtonStyleButton) {
      if (w.enabled) name = 'Button';
    } else if (w is MaterialButton) {
      if (w.enabled) name = 'Button';
    } else if (w is CupertinoButton) {
      if (w.enabled) name = 'Button';
    } else if (w is IconButton) {
      if (w.onPressed != null) {
        name = 'IconButton';
        searchForText = false;
      }
    } else if (w is Tab) {
      name = 'Tab';
    } else if (w is BottomNavigationBar) {
      if (w.onTap != null) name = 'BottomNavigationBarItem';
    } else if (w is Radio) {
      name = 'Radio';
      // Use the radio's value as the description; mark as a derived
      // attribute rather than an explicit a11y label.
      treeAnnotation ??= _TreeAnnotation(w.value?.toString(), 'text_content');
    } else if (w is Switch) {
      name = 'Switch';
    } else if (w is InkWell) {
      if (w.onTap != null) {
        name = 'InkWell';
        searchForBetter = true;
        searchForText = false;
      }
    } else if (w is GestureDetector) {
      if (w.onTap != null) {
        name = 'GestureDetector';
        searchForBetter = true;
        searchForText = false;
      }
    }

    if (name != null) {
      final annotation =
          treeAnnotation ?? _findInnerText(element, searchForText);
      final desc = annotation?.description ?? 'unknown';
      return _ElementDescription(
        element: element,
        elementName: name,
        elementDescription: desc,
        nameSource:
            desc == 'unknown' ? 'blank' : (annotation?.source ?? 'blank'),
        tryForBetter: searchForBetter,
      );
    }
    return null;
  }
}
