import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'scout_rum_config.dart';
import 'user_action_annotation.dart';

const _tapSlop = 20;
const _tapSlopSquared = _tapSlop * _tapSlop;

class _ElementDescription {
  final Element element;
  final String elementName;
  final String elementDescription;
  final bool tryForBetter;

  const _ElementDescription({
    required this.element,
    required this.elementName,
    required this.elementDescription,
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
  const _TreeAnnotation(this.description, [this.attributes]);
}

/// Detects taps globally via [GestureBinding.pointerRouter].
/// No widget wrapper needed — just call [start] after binding is initialized.
class GlobalTapDetector {
  final void Function(String elementName, String elementDescription)
      onTapDetected;
  final CustomGestureElementDetector? customGestureDetector;
  final _pointerDownPositions = <int, Offset>{};

  GlobalTapDetector({
    required this.onTapDetected,
    this.customGestureDetector,
  });

  void start() {
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handleEvent);
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
      onTapDetected(description.elementName, description.elementDescription);
    }
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
        final paintBounds =
            MatrixUtils.transformRect(transform, ro.paintBounds);

        if (!paintBounds.contains(globalPosition)) return;
      }

      final w = element.widget;
      if (w is RumUserActionAnnotation) {
        treeAnnotation = _TreeAnnotation(w.description, w.attributes);
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
          tryForBetter: false,
        );
      }
    }

    return best;
  }

  _TreeAnnotation? _findInnerText(Element element, bool allowText) {
    String? description;
    Map<String, Object?>? attributes;
    bool stopSiblings = false;

    void visitor(Element el) {
      if (stopSiblings) return;
      bool stop = false;
      final w = el.widget;

      if (w is RumUserActionAnnotation) {
        description = w.description;
        attributes = w.attributes;
        stop = true;
        stopSiblings = true;
      } else if (allowText && w is Text) {
        if (w.data?.isNotEmpty ?? false) {
          description = w.data!;
          stop = true;
        }
      } else if (w is Semantics) {
        if (w.properties.label?.isNotEmpty ?? false) {
          description = w.properties.label!;
          stop = true;
        }
      } else if (w is Icon) {
        if (w.semanticLabel?.isNotEmpty ?? false) {
          description = w.semanticLabel!;
          stop = true;
        }
      }

      if (!stop) {
        el.visitChildren(visitor);
      }
    }

    element.visitChildren(visitor);
    return _TreeAnnotation(description, attributes);
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
      treeAnnotation ??= _TreeAnnotation(w.value?.toString());
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
      return _ElementDescription(
        element: element,
        elementName: name,
        elementDescription: annotation?.description ?? 'unknown',
        tryForBetter: searchForBetter,
      );
    }
    return null;
  }
}
