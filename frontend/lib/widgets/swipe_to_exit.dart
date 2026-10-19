import 'package:flutter/material.dart';

/// Adds an accessible right-to-left swipe to dismiss the current module.
///
/// A [Listener] is deliberately used instead of a drag [GestureDetector]. It
/// observes pointers without entering Flutter's gesture arena, so camera
/// controls, horizontal lists and controls inside a module keep working.
/// [NavigatorState.maybePop] honours each route's PopScope; an in-progress UPI
/// payment or a safety confirmation therefore cannot be dismissed by mistake.
class SwipeToExit extends StatefulWidget {
  const SwipeToExit({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<SwipeToExit> createState() => _SwipeToExitState();
}

class _SwipeToExitState extends State<SwipeToExit> {
  int? _pointer;
  Offset? _start;
  DateTime? _startedAt;

  static const double _minimumHorizontalDistance = 90;
  static const Duration _maximumGestureDuration = Duration(seconds: 1);

  void _onDown(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _start = event.position;
    _startedAt = DateTime.now();
  }

  void _onUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;

    final start = _start;
    final startedAt = _startedAt;
    _clear();
    if (start == null || startedAt == null) return;

    final movement = event.position - start;
    final isQuickEnough = DateTime.now().difference(startedAt) <=
        _maximumGestureDuration;
    final isRightToLeft = movement.dx <= -_minimumHorizontalDistance;
    final isMostlyHorizontal = movement.dx.abs() > movement.dy.abs() * 1.5;
    if (!isQuickEnough || !isRightToLeft || !isMostlyHorizontal) return;

    final navigator = widget.navigatorKey.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.maybePop();
    }
  }

  void _clear() {
    _pointer = null;
    _start = null;
    _startedAt = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerUp: _onUp,
      onPointerCancel: (_) => _clear(),
      child: widget.child,
    );
  }
}
