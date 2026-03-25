import 'package:flutter/widgets.dart';

/// Annotate a widget subtree with a description for RUM action tracking.
///
/// When the global tap detector detects a tap inside this widget's subtree,
/// it uses [description] instead of extracting text from child widgets.
///
/// ```dart
/// RumUserActionAnnotation(
///   description: 'Add to cart',
///   child: MyCustomWidget(...),
/// )
/// ```
@immutable
class RumUserActionAnnotation extends StatelessWidget {
  /// The description to use for this action.
  final String description;

  /// Optional attributes to attach to the action span.
  final Map<String, Object?>? attributes;

  /// The child widget tree.
  final Widget child;

  const RumUserActionAnnotation({
    super.key,
    required this.description,
    required this.child,
    this.attributes,
  });

  @override
  Widget build(BuildContext context) => child;
}
