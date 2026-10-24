import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../pages/docs_page.dart';
import '../pages/home_page.dart';

/// Root shell: two tabs (扫描/文档) as a top segmented control — quiet,
/// iOS-style, no floating bar. Content owns the full screen below it.
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
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // Top tab switcher
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _tabChip(0, Icons.document_scanner_outlined, Icons.document_scanner, '扫描'),
                        _tabChip(1, Icons.folder_outlined, Icons.folder, '文档'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: const [HomePage(), DocsPage()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabChip(int i, IconData outline, IconData filled, String label) {
    final active = _tab == i;
    return GestureDetector(
      onTap: () => setState(() => _tab = i),
      child: AnimatedContainer(
        duration: Ds.durFast,
        curve: Ds.curve,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Ds.clover.withValues(alpha: 0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(active ? filled : outline, size: 17,
                color: active ? Ds.clover : Ds.textDim),
            const SizedBox(width: 7),
            Text(label, style: TextStyle(
              fontSize: 14,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active ? Ds.clover : Ds.textDim,
            )),
          ],
        ),
      ),
    );
  }
}
