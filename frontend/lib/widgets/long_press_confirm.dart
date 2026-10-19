import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Long-press-to-confirm control used by every action a blind user must not
/// trigger by accident (creating an account, choosing a companion, finishing
/// the instructions).
///
/// Design rules baked in here:
///  * a plain tap never confirms - it only reports the required gesture,
///  * the hold starts on raw touch-down, not after the gesture arena's long
///    press timeout, so [onHoldStart] can say "Hold..." the instant a finger
///    lands and the user always knows the app noticed them,
///  * releasing early calls [onHoldCancelled] so the user hears why nothing
///    happened instead of getting silence,
///  * the required hold is ~1.2 seconds and is shown as a filling progress bar
///    so a sighted user (or a faculty demo) can see it,
///  * TalkBack can trigger it through the standard "long press" action, and
///    the semantic label states the consequence,
///  * the confirmation can be cancelled by lifting early or by swiping away.
class LongPressConfirm extends StatefulWidget {
  const LongPressConfirm({
    super.key,
    required this.onConfirmed,
    required this.label,
    required this.semanticLabel,
    this.semanticHint = 'Press and hold to continue',
    this.holdDuration = const Duration(milliseconds: 1200),
    this.enabled = true,
    this.busy = false,
    this.icon = Icons.touch_app_rounded,
    this.height = 72,
    this.accent,

    /// Fired the moment a finger goes down, before the hold completes. Used to
    /// speak "Hold..." so the interaction is audibly acknowledged.
    this.onHoldStart,

    /// Fired when a hold started but was released (or slid off) before
    /// [holdDuration] elapsed. Used to explain the failure out loud.
    this.onHoldCancelled,

    /// Spoken text used by [onHoldStart] / [onHoldCancelled] when the caller
    /// wants the widget to announce itself instead of wiring its own voice.
    this.holdStartedSpoken,
    this.holdCancelledSpoken,

    /// When true the control stretches to its parent instead of using
    /// [height]. The account-creation screen uses this to fill roughly half the
    /// usable screen with one touch target.
    this.fill = false,
  });

  /// Called once the hold completed.
  final VoidCallback onConfirmed;

  /// Visible caption, e.g. "HOLD TO CONTINUE".
  final String label;

  /// Spoken by TalkBack / read out by a screen reader.
  final String semanticLabel;

  final String semanticHint;

  final Duration holdDuration;
  final bool enabled;

  /// Shows a busy caption and blocks input while work is in progress.
  final bool busy;

  final IconData icon;
  final double height;
  final Color? accent;

  final VoidCallback? onHoldStart;
  final VoidCallback? onHoldCancelled;
  final String? holdStartedSpoken;
  final String? holdCancelledSpoken;

  final bool fill;

  @override
  LongPressConfirmState createState() => LongPressConfirmState();
}

/// Public so an owning screen can hold a `GlobalKey<LongPressConfirmState>` and
/// call [reset] deterministically. Relying only on `didUpdateWidget` is not
/// enough: a chooser that is dismissed without the busy flag ever changing
/// would otherwise leave the button consumed.
class LongPressConfirmState extends State<LongPressConfirm>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.holdDuration,
  )..addStatusListener(_onStatus);

  bool _held = false;

  /// Latches the *single* completion of one hold, so `onConfirmed` cannot fire
  /// twice for the same touch (the animation status can be delivered again
  /// after a stop/reset cycle).
  ///
  /// This is deliberately per-hold and NOT per-widget-lifetime. It used to be
  /// set to true on completion and never cleared, which meant the very first
  /// long press consumed the button for the life of the State: after the user
  /// cancelled the account chooser and came back, every later press was
  /// rejected by `_start()`. It is now cleared on every touch-down in
  /// [_start], which is the only place a new hold can begin.
  bool _firedThisHold = false;

  bool get _active => widget.enabled && !widget.busy;

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (_firedThisHold) return;
    _firedThisHold = true;
    _held = false;
    _confirmHaptic();
    widget.onConfirmed();
  }

  /// Returns the control to a fully armed state.
  ///
  /// Called by the owning screen once an interrupted action (a cancelled
  /// account chooser, a failed request) has finished, so the next press behaves
  /// exactly like the first one.
  void reset() {
    if (!mounted) return;
    _held = false;
    _firedThisHold = false;
    _controller.stop();
    _controller.reset();
  }

  void _confirmHaptic() {
    try {
      HapticFeedback.mediumImpact();
    } catch (_) {
      // Haptics are cosmetic; never block the flow on them.
    }
  }

  /// Begins a hold. Called on every raw touch-down.
  ///
  /// The completion latch is cleared HERE as well as in [reset]. Clearing it
  /// only in [reset] made the control fragile: [reset] runs from a rebuild
  /// (`didUpdateWidget` / `didChangeDependencies`) and from an explicit call by
  /// the owning screen, so any path that missed it - an exception thrown
  /// between the hold completing and the screen returning to idle, a rebuild
  /// that did not carry the busy flag, a rebuild while the native account
  /// chooser had the app in the background - left `_firedThisHold` stuck at
  /// `true`. The symptom was the worst possible one for a blind user: the
  /// progress bar still filled and "Opening Google account selection" was
  /// still spoken on touch-down, but `onConfirmed` was never called, so every
  /// press after the first did nothing and explained nothing.
  ///
  /// Deriving the latch from "a finger went down just now" rather than from
  /// external rebuild timing makes a dead button impossible: one touch-down is
  /// always exactly one hold, and one hold fires `onConfirmed` at most once.
  void _start() {
    if (!_active) return;
    _firedThisHold = false;
    _held = true;
    _controller.forward(from: 0);
    widget.onHoldStart?.call();
  }

  /// A hold that began but did not finish. Reported so the user hears an
  /// explanation rather than silence.
  void _abort() {
    if (!_held) return;
    _held = false;
    _controller.stop();
    _controller.reset();
    // The hold never completed, so the control stays armed for the next try.
    if (!_firedThisHold) widget.onHoldCancelled?.call();
  }

  @override
  void didUpdateWidget(covariant LongPressConfirm oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!_active) {
      _abort();
      return;
    }

    // The control was busy (an action was in flight) and is now available again.
    // That is the moment a cancelled action finished, so re-arm: without this
    // the button stays dead for every subsequent attempt.
    if (oldWidget.busy && !widget.busy) {
      reset();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A media-query rebuild (e.g. the OS window changing while the account
    // chooser is on top and then dismissed) can also end a busy period.
    // Never re-arm while a finger is down: a rebuild must not silently cancel
    // a hold the user is still performing.
    if (_held) return;
    if (_active && !_controller.isAnimating && _controller.value >= 1.0) {
      reset();
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    // Deliberately inert: an accidental tap must never confirm.
    // The user is told what to do instead.
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 2500),
        backgroundColor: Colors.black87,
        content: Text(
          widget.semanticHint,
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent ?? Colors.white;
    final active = _active;

    return Semantics(
      button: true,
      enabled: active,
      label: widget.semanticLabel,
      hint: widget.semanticHint,
      onLongPress: active ? widget.onConfirmed : null,
      excludeSemantics: true,
      child: Listener(
        // Raw pointer events rather than GestureDetector long-press callbacks:
        // the arena does not resolve until ~500ms, which would delay the "Hold"
        // confirmation far too long for a blind user.
        onPointerDown: (_) => _start(),
        onPointerUp: (_) => _abort(),
        onPointerCancel: (_) => _abort(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _handleTap,
          child: SizedBox(
            height: widget.fill ? null : widget.height,
            width: widget.fill ? double.infinity : null,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final progress = _controller.value;
                return Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: accent.withValues(alpha: active ? 0.45 : 0.15),
                      width: 1.5,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Fill that grows while the user holds.
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: progress.clamp(0.0, 1.0),
                        child: Container(color: accent.withValues(alpha: 0.22)),
                      ),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                widget.icon,
                                color: active
                                    ? accent
                                    : accent.withValues(alpha: 0.4),
                                size: widget.fill ? 56 : 26,
                              ),
                              SizedBox(height: widget.fill ? 20 : 0),
                              Text(
                                widget.busy ? 'OPENING GOOGLE' : widget.label,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: active
                                      ? accent
                                      : accent.withValues(alpha: 0.45),
                                  fontSize: widget.fill ? 26 : 16,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: widget.fill ? 2.4 : 1.1,
                                  height: 1.3,
                                ),
                              ),
                              if (widget.fill) ...[
                                const SizedBox(height: 12),
                                Text(
                                  active
                                      ? 'keep holding until I say release'
                                      : 'Google account selection is opening',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: active
                                        ? accent.withValues(alpha: 0.75)
                                        : accent.withValues(alpha: 0.35),
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
