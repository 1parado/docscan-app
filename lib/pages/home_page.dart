import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../design/tokens.dart';
import '../state/scan_state.dart';
import 'adjust_page.dart';
import 'camera_page.dart';
import 'result_page.dart';

/// Scan tab: recent docs hero + capture controls in the thumb zone.
/// Layout budget respects the floating tab bar (~88px + safe area).
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _busy = false;
  String? _flash;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(libraryProvider.notifier).reload();
    });
  }

  Future<void> _shoot() async {
    if (_busy) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const CameraPage(),
      fullscreenDialog: true,
    ));
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
        if (mounted && page.cropStatus == 'not_found') {
          setState(() => _flash = '有照片未检测到边缘，可在缩略图上手动裁剪');
        }
      }
      if (mounted) _openResult(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = ref.watch(sessionProvider);
    final session = ref.read(sessionProvider.notifier);
    final recent = ref.watch(libraryProvider);
    final pad = MediaQuery.of(context).padding;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------- Header ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Row(
                children: [
                  Container(
                    width: 34, height: 34,
                    decoration: BoxDecoration(
                      color: Ds.clover,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(Icons.document_scanner, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 10),
                  const Text('DocScan',
                      style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.3)),
                ],
              ),
            ),
            // Mode + auto-crop right under the header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: _ModeSwitch(session: session),
            ),

            // ---------- Recent strip (has content? show it : show intro) ----------
            Expanded(
              child: pages.isNotEmpty
                  ? _SessionView(pages: pages, flash: _flash)
                  : _IdleView(recent: recent),
            ),

            // ---------- Capture controls (thumb zone) ----------
            Padding(
              padding: EdgeInsets.fromLTRB(20, 10, 20, 24 + pad.bottom * 0.4),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: GestureDetector(
                      onTap: _shoot,
                      child: Container(
                        height: 58,
                        decoration: BoxDecoration(
                          color: Ds.clover,
                          borderRadius: BorderRadius.circular(29),
                        ),
                        child: Center(
                          child: _busy
                              ? const SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                              : const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.photo_camera_outlined, color: Colors.white, size: 21),
                                    SizedBox(width: 9),
                                    Text('拍摄',
                                        style: TextStyle(color: Colors.white, fontSize: 16.5, fontWeight: FontWeight.w600)),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: GestureDetector(
                      onTap: _pickFromAlbum,
                      child: Container(
                        height: 58,
                        decoration: BoxDecoration(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(29),
                          border: Border.all(color: Ds.clover.withValues(alpha: 0.45), width: 1.4),
                        ),
                        child: const Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.photo_library_outlined, color: Ds.clover, size: 20),
                              SizedBox(width: 8),
                              Text('相册', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w500, color: Ds.clover)),
                            ],
                          ),
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

/// Empty / idle state: quiet hint + recent docs preview.
class _IdleView extends StatelessWidget {
  const _IdleView({required this.recent});

  final List<ScanDoc> recent;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (recent.isNotEmpty) ...[
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.only(left: 20, bottom: 10),
            child: Text('最近的文档',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Ds.textDim)),
          ),
          SizedBox(
            height: 128,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: recent.length.clamp(0, 6),
              separatorBuilder: (_, __) => const SizedBox(width: 16),
              itemBuilder: (context, i) {
                final doc = recent[i];
                return Container(
                  width: 96,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        doc.firstPageImage.existsSync()
                            ? Image.file(doc.firstPageImage, fit: BoxFit.cover)
                            : const ColoredBox(color: Ds.frost),
                        Positioned(
                          left: 0, right: 0, bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                                  colors: [Colors.transparent, Colors.black.withValues(alpha: 0.5)]),
                            ),
                            child: Text(doc.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 9.5)),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

/// Active session view: page thumbnails + clear/next actions.
class _SessionView extends ConsumerWidget {
  const _SessionView({required this.pages, required this.flash});

  final List<ScanPage> pages;
  final String? flash;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.read(sessionProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Spacer(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Row(
            children: [
              Text('已拍 ${pages.length} 页',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              if (flash != null)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text(flash!,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Ds.danger, fontSize: 12)),
                  ),
                ),
              const Spacer(),
              TextButton(
                onPressed: () => session.clear(),
                child: Text('清空', style: TextStyle(color: Ds.textDim, fontSize: 13.5)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.clover,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                ),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ResultPage())),
                child: const Text('下一步'),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 128,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: pages.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) => _PageThumb(index: i),
          ),
        ),
      ],
    );
  }
}

class _ModeSwitch extends ConsumerWidget {
  const _ModeSwitch({required this.session});

  final ScanSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(sessionProvider.notifier).mode;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
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
                    color: mode == m ? Ds.clover.withValues(alpha: 0.1) : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    switch (m) { ScanModeSetting.color => '彩色', ScanModeSetting.gray => '灰度', ScanModeSetting.bw => '黑白' },
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: mode == m ? FontWeight.w600 : FontWeight.w400,
                      color: mode == m ? Ds.clover : Ds.textDim,
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(width: 2),
          GestureDetector(
            onTap: () => session.setAutoCrop(!session.autoCrop),
            child: AnimatedContainer(
              duration: Ds.durFast,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: session.autoCrop ? Ds.clover.withValues(alpha: 0.1) : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.crop_free, size: 15,
                      color: session.autoCrop ? Ds.clover : Ds.textDim),
                  const SizedBox(width: 5),
                  Text('裁边', style: TextStyle(
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

    return GestureDetector(
      onTap: () async {
        final updated = await Navigator.of(context).push<List<List<double>>?>(
          MaterialPageRoute(builder: (_) => AdjustPage(pageIndex: index)),
        );
        if (updated != null) {
          final p = pages[index];
          final bytes = await p.file.readAsBytes();
          final newPage = await session.processBytes(bytes, manualCorners: updated);
          session.removeAt(index);
          session.add(newPage);
        }
      },
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.file(page.file, width: 92, height: 124, fit: BoxFit.cover),
          ),
          Positioned(
            left: 5, top: 5,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text('${index + 1}',
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
            ),
          ),
          Positioned(
            right: 4, top: 4,
            child: Container(
              width: 24, height: 24,
              decoration: BoxDecoration(
                color: page.manualCorners != null ? Ds.clover : Colors.black.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.crop, size: 13, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
