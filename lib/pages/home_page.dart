import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../design/tokens.dart';
import '../state/scan_state.dart';
import 'adjust_page.dart';
import 'camera_page.dart';
import 'result_page.dart';

/// Scan tab: the entry. One big camera card + the working session strip.
/// Everything lives in the bottom third for thumb reach.
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _busy = false;
  String? _flash; // transient status line

  Future<void> _shoot() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const CameraPage(),
        fullscreenDialog: true,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickFromAlbum() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picker = ImagePicker();
      final picked = await picker.pickMultiImage(imageQuality: 92);
      if (picked.isEmpty) return;
      final session = ref.read(sessionProvider.notifier);
      for (final x in picked) {
        final bytes = await x.readAsBytes();
        final page = await session.processBytes(Uint8List.fromList(bytes));
        session.add(page);
        if (mounted) {
          setState(() => _flash = page.cropStatus == 'not_found'
              ? '未检测到边缘，已按原图处理'
              : null);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = ref.watch(sessionProvider);
    final session = ref.read(sessionProvider.notifier);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('DocScan', style: Theme.of(context).appBarTheme.titleTextStyle!.copyWith(
                        fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('离线扫描 · 透视校正 · 导出 PDF',
                      style: TextStyle(color: Ds.textDim, fontSize: 13)),
                ],
              ),
            ),
            const Spacer(),
            // Working session strip
            if (pages.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 20, bottom: 10),
                child: Row(
                  children: [
                    Text('已拍 ${pages.length} 页',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    if (_flash != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: Text(_flash!, style: const TextStyle(color: Ds.danger, fontSize: 12.5)),
                      ),
                    const Spacer(),
                    TextButton(
                      onPressed: pages.isEmpty ? null : () => _openResult(context),
                      child: const Text('下一步'),
                    ),
                    TextButton(
                      onPressed: () => session.clear(),
                      child: Text('清空', style: TextStyle(color: Ds.textDim)),
                    ),
                  ],
                ),
              ),
            if (pages.isNotEmpty)
              SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: pages.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => _PageThumb(index: i),
                ),
              ),
            // Controls
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Row(
                children: [
                  Expanded(
                    child: _ModeSwitch(session: session),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 24 + MediaQuery.of(context).padding.bottom * 0.4),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: GestureDetector(
                      onTap: _shoot,
                      child: Container(
                        height: 92,
                        decoration: BoxDecoration(
                          color: Ds.clover,
                          borderRadius: BorderRadius.circular(Ds.radius),
                          boxShadow: [BoxShadow(color: Ds.clover.withValues(alpha: 0.28), blurRadius: 24, offset: const Offset(0, 8))],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _busy
                                ? const SizedBox(
                                    width: 20, height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                                : const Icon(Icons.photo_camera_outlined, color: Colors.white),
                            const SizedBox(width: 10),
                            Text(_busy ? '处理中…' : '拍摄',
                                style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: GestureDetector(
                      onTap: _pickFromAlbum,
                      child: Container(
                        height: 92,
                        decoration: BoxDecoration(
                          color: Ds.glassFill,
                          borderRadius: BorderRadius.circular(Ds.radius),
                          border: Border.all(color: Ds.stroke, width: 0.8),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.photo_library_outlined, color: Ds.text),
                            SizedBox(width: 8),
                            Text('相册', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openResult(BuildContext context) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ResultPage()));
    if (mounted) setState(() => _flash = null);
  }
}

class _ModeSwitch extends ConsumerWidget {
  const _ModeSwitch({required this.session});

  final ScanSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(sessionProvider.notifier).mode;
    return Glass(
      radius: Ds.radiusSmall,
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          for (final m in ScanModeSetting.values)
            Expanded(
              child: GestureDetector(
                onTap: () => session.setMode(m),
                child: AnimatedContainer(
                  duration: Ds.durFast,
                  curve: Ds.curve,
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: mode == m ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: mode == m
                        ? [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 6, offset: const Offset(0, 2))]
                        : null,
                  ),
                  child: Text(
                    switch (m) { ScanModeSetting.color => '彩色', ScanModeSetting.gray => '灰度', ScanModeSetting.bw => '黑白' },
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: mode == m ? FontWeight.w600 : FontWeight.w400,
                      color: mode == m ? Ds.cloverDim : Ds.textDim,
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () => session.setAutoCrop(!session.autoCrop),
            child: AnimatedContainer(
              duration: Ds.durFast,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: session.autoCrop ? Ds.clover.withValues(alpha: 0.12) : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.crop_free, size: 15,
                      color: session.autoCrop ? Ds.clover : Ds.textDim),
                  const SizedBox(width: 5),
                  Text('智能裁边', style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: session.autoCrop ? Ds.clover : Ds.textDim)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PageThumb extends ConsumerWidget {
  const _PageThumb({required this.index});

  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pages = ref.watch(sessionProvider);
    final page = pages[index];
    final session = ref.read(sessionProvider.notifier);

    return Dismissible(
      key: ValueKey(page.name),
      direction: DismissDirection.up,
      onDismissed: (_) => session.removeAt(index),
      background: const ColoredBox(color: Colors.transparent),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(page.file, width: 84, height: 112, fit: BoxFit.cover),
          ),
          Positioned(
            left: 4, top: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.62),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text('${index + 1}',
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
            ),
          ),
          // Manual crop entry
          Positioned(
            right: 4, top: 4,
            child: GestureDetector(
              onTap: () async {
                final updated = await Navigator.of(context).push<List<List<double>>?>(
                  MaterialPageRoute(builder: (_) => AdjustPage(pageIndex: index)),
                );
                if (updated != null) {
                  final p = pages[index];
                  final newPage = await session.processBytes(
                    await p.file.readAsBytes(),
                    manualCorners: updated,
                  );
                  session.removeAt(index);
                  session.add(newPage);
                }
              },
              child: Container(
                width: 22, height: 22,
                decoration: BoxDecoration(
                  color: page.manualCorners != null ? Ds.clover : Colors.black.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: const Icon(Icons.crop, size: 13, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
