import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../pages/docs_page.dart';
import '../pages/home_page.dart';

/// Root shell: two tabs (Scan, Docs) with a liquid-glass floating tab bar.
/// Direct switch (no nested navigator) keeps startup light.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [HomePage(), DocsPage()],
      ),
      // extendBody stays true for the glass effect, but pages budget their
      // own bottom padding (96px) above the bar.
      extendBody: true,
      bottomNavigationBar: _GlassTabBar(
        index: _tab,
        onChanged: (i) => setState(() => _tab = i),
      ),
    );
  }
}

class _GlassTabBar extends StatelessWidget {
  const _GlassTabBar({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Glass(
            radius: Ds.radius,
            dark: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _tabButton(0, Icons.document_scanner_outlined, Icons.document_scanner, '扫描'),
                  _tabButton(1, Icons.folder_outlined, Icons.folder, '文档'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabButton(int i, IconData outline, IconData filled, String label) {
    final active = index == i;
    return GestureDetector(
      onTap: () => onChanged(i),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: Ds.durFast,
        curve: Ds.curve,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
        decoration: BoxDecoration(
          color: active ? Colors.white.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(Ds.radiusSmall),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(active ? filled : outline, size: 20,
                color: active ? Colors.white : Colors.white.withValues(alpha: 0.6)),
            const SizedBox(width: 7),
            Text(label, style: TextStyle(
              fontSize: 14.5,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active ? Colors.white : Colors.white.withValues(alpha: 0.6),
            )),
          ],
        ),
      ),
    );
  }
}
