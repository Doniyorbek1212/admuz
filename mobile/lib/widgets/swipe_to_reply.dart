import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Telegram's swipe-to-reply: drag a message to the left, a reply arrow grows in, past the threshold
/// the phone ticks, and letting go starts a reply while the message springs back.
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({super.key, required this.onReply, required this.child});

  final VoidCallback onReply;
  final Widget child;

  static const threshold = 64.0;
  static const maxDrag = 96.0;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> with SingleTickerProviderStateMixin {
  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 200))
    ..addListener(() => setState(() => _offset = _releasedAt * (1 - Curves.easeOut.transform(_back.value))));
  double _offset = 0; // Leftward drag distance, 0..maxDrag.
  double _releasedAt = 0;
  bool _armed = false;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _onUpdate(DragUpdateDetails details) {
    if (_back.isAnimating) _back.stop();
    // Resistance grows towards the end, like Telegram.
    final next = (_offset - details.delta.dx * (1 - _offset / (SwipeToReply.maxDrag * 1.4))).clamp(0.0, SwipeToReply.maxDrag);
    final armed = next >= SwipeToReply.threshold;
    if (armed && !_armed) HapticFeedback.lightImpact();
    setState(() {
      _offset = next;
      _armed = armed;
    });
  }

  void _onEnd(DragEndDetails _) {
    if (_armed) widget.onReply();
    _armed = false;
    _releasedAt = _offset;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final progress = min(1.0, _offset / SwipeToReply.threshold);
    final primary = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _onUpdate,
      onHorizontalDragEnd: _onEnd,
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          if (_offset > 0)
            Positioned(
              right: 12,
              child: Opacity(
                opacity: progress,
                child: Transform.scale(
                  scale: 0.5 + 0.5 * progress,
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: _armed ? primary : Colors.black26,
                    child: const Icon(Icons.reply_rounded, color: Colors.white, size: 20),
                  ),
                ),
              ),
            ),
          Transform.translate(offset: Offset(-_offset, 0), child: widget.child),
        ],
      ),
    );
  }
}
