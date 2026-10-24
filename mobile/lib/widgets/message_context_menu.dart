import 'dart:math';

import 'package:flutter/material.dart';

/// One menu row: icon, label, and the value returned when it is tapped (suffix ':destructive' paints it red).
typedef ContextMenuEntry = (IconData icon, String label, String value);

/// Telegram's message menu on phones: a reaction strip and a floating card next to the touched message,
/// instead of a bottom sheet. Returns the tapped entry's value, or `react:EMOJI` for a reaction.
Future<String?> showMessageContextMenu({
  required BuildContext context,
  required Offset anchor,
  required bool alignEnd,
  required List<ContextMenuEntry> items,
  List<String> reactions = const [],
}) =>
    showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (context, _, _) => _MessageContextMenu(anchor: anchor, alignEnd: alignEnd, items: items, reactions: reactions),
      transitionBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(opacity: curved, child: child);
      },
    );

class _MessageContextMenu extends StatelessWidget {
  const _MessageContextMenu({required this.anchor, required this.alignEnd, required this.items, required this.reactions});

  final Offset anchor;
  final bool alignEnd;
  final List<ContextMenuEntry> items;
  final List<String> reactions;

  static const _rowHeight = 52.0;
  static const _reactionHeight = 56.0;
  static const _gap = 8.0;
  static const _side = 16.0;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final top = media.padding.top + _gap;
    final bottom = size.height - media.padding.bottom - _gap;
    final width = min(300.0, size.width - _side * 2);
    final reactionsHeight = reactions.isEmpty ? 0.0 : _reactionHeight + _gap;
    final menuHeight = min(items.length * _rowHeight + 8, bottom - top - reactionsHeight);
    // Start the card at the touch, then pull it back on screen; the reactions sit right above it.
    final cardTop = (anchor.dy - 24).clamp(top + reactionsHeight, bottom - menuHeight);
    final scheme = Theme.of(context).colorScheme;
    final surface = Color.alphaBlend(scheme.primary.withValues(alpha: 0.06), scheme.surfaceContainerHigh);
    final horizontal = alignEnd ? (right: _side, left: null) : (right: null, left: _side);
    return Stack(
      children: [
        if (reactions.isNotEmpty)
          Positioned(
            left: horizontal.left,
            right: horizontal.right,
            top: cardTop - reactionsHeight,
            width: min(size.width - _side * 2, max(width, reactions.length * 46.0 + 16)),
            height: _reactionHeight,
            child: _Popped(
              alignEnd: alignEnd,
              child: Material(
                color: surface,
                elevation: 6,
                borderRadius: BorderRadius.circular(_reactionHeight / 2),
                clipBehavior: Clip.antiAlias,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final emoji in reactions)
                      InkResponse(
                        radius: 24,
                        onTap: () => Navigator.pop(context, 'react:$emoji'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Center(child: Text(emoji, style: const TextStyle(fontSize: 30))),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          left: horizontal.left,
          right: horizontal.right,
          top: cardTop,
          width: width,
          height: menuHeight,
          child: _Popped(
            alignEnd: alignEnd,
            child: Material(
              color: surface,
              elevation: 8,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [for (final entry in items) _row(context, entry)],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, ContextMenuEntry entry) {
    final (icon, label, value) = entry;
    final destructive = value.endsWith(':destructive');
    final color = destructive ? Theme.of(context).colorScheme.error : null;
    return InkWell(
      onTap: () => Navigator.pop(context, value),
      child: SizedBox(
        height: _rowHeight,
        child: Row(
          children: [
            const SizedBox(width: 18),
            Icon(icon, color: color ?? Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 18),
            Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, color: color))),
          ],
        ),
      ),
    );
  }
}

/// Grows out of the message side, like Telegram's popup.
class _Popped extends StatelessWidget {
  const _Popped({required this.alignEnd, required this.child});

  final bool alignEnd;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.85, end: 1),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutBack,
        builder: (context, scale, child) => Transform.scale(
          scale: scale,
          alignment: alignEnd ? Alignment.topRight : Alignment.topLeft,
          child: child,
        ),
        child: child,
      );
}
