import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/tokens.dart';
import '../state/scan_state.dart';

/// The ◀ × ▶ row a page strip shows while it is being organised.
///
/// Both strips use it, and every action is the session's own: a delete really
/// drops the JPEG the pipeline wrote, a move goes through the same reorder the
/// exported PDF is built from.
class PageActions extends ConsumerWidget {
  const PageActions({super.key, required this.index, required this.count});

  final int index;
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.read(sessionProvider.notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActionDot(
          icon: Icons.chevron_left,
          label: '第 ${index + 1} 页前移',
          enabled: index > 0,
          onTap: () => session.reorder(index, index - 1),
        ),
        _ActionDot(
          icon: Icons.close,
          label: '删除第 ${index + 1} 页',
          danger: true,
          onTap: () => session.removeAt(index),
        ),
        _ActionDot(
          icon: Icons.chevron_right,
          label: '第 ${index + 1} 页后移',
          enabled: index < count - 1,
          onTap: () => session.reorder(index, index + 1),
        ),
      ],
    );
  }
}

class _ActionDot extends StatelessWidget {
  const _ActionDot({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final tint = danger ? Ds.danger : Ds.clover;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        // A disabled arrow still occupies its slot, so the row does not jump
        // when the first or the last page is being moved.
        onTap: enabled ? onTap : null,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: enabled ? 0.66 : 0.32),
            shape: BoxShape.circle,
            border: Border.all(color: tint.withValues(alpha: enabled ? 0.9 : 0.35), width: 1.2),
          ),
          child: Icon(icon, size: 16, color: enabled ? Colors.white : Colors.white38),
        ),
      ),
    );
  }
}
