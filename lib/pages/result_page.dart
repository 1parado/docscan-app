import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../design/tokens.dart';
import '../state/scan_state.dart';

/// Result / export page: page strip, title field (pre-filled with the auto
/// name), export button. Motion: pages rise in staggered.
class ResultPage extends ConsumerStatefulWidget {
  const ResultPage({super.key});

  @override
  ConsumerState<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends ConsumerState<ResultPage> {
  final _titleCtrl = TextEditingController();
  bool _exporting = false;
  ScanDoc? _done;

  @override
  void initState() {
    super.initState();
    suggestedTitle().then((t) {
      if (mounted) _titleCtrl.text = t;
    });
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final title = _titleCtrl.text.trim().isEmpty
          ? await suggestedTitle()
          : _titleCtrl.text.trim();
      final doc = await ref.read(sessionProvider.notifier).exportToLibrary(title);
      if (mounted) setState(() => _done = doc);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = ref.watch(sessionProvider);
    final done = _done;

    return Scaffold(
      appBar: AppBar(title: Text(done == null ? '导出 PDF' : '完成')),
      body: done != null ? _doneView(context, done) : _exportView(context, pages),
    );
  }

  Widget _exportView(BuildContext context, List<ScanPage> pages) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Text('${pages.length} 页 · A4 · 200dpi',
              style: const TextStyle(color: Ds.textDim, fontSize: 13)),
        ),
        // Page strip
        SizedBox(
          height: 190,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(20),
            itemCount: pages.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) => _ResultThumb(index: i, delay: i * 0.05),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('文档名', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 8),
              TextField(
                controller: _titleCtrl,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  hintText: '10月24日 扫描 1',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Ds.radiusSmall),
                    borderSide: const BorderSide(color: Ds.stroke),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Ds.radiusSmall),
                    borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.1)),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.of(context).padding.bottom * 0.4),
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: GestureDetector(
              onTap: _export,
              child: Container(
                decoration: BoxDecoration(
                  color: Ds.clover,
                  borderRadius: BorderRadius.circular(Ds.radius),
                  boxShadow: [BoxShadow(color: Ds.clover.withValues(alpha: 0.3), blurRadius: 22, offset: const Offset(0, 8))],
                ),
                child: Center(
                  child: _exporting
                      ? const SizedBox(
                          width: 22, height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                      : const Text('保存到文档',
                            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _doneView(BuildContext context, ScanDoc doc) {
    return Column(
      children: [
        const Spacer(),
        Container(
          width: 72, height: 72,
          decoration: const BoxDecoration(color: Ds.clover, shape: BoxShape.circle),
          child: const Icon(Icons.check, color: Colors.white, size: 36),
        ),
        const SizedBox(height: 20),
        Text(doc.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('${doc.pageCount} 页 · PDF 已保存', style: const TextStyle(color: Ds.textDim)),
        const Spacer(),
        Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.of(context).padding.bottom * 0.4),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 54,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                    child: const Text('回首页'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 54,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Ds.clover),
                    onPressed: () => Share.shareXFiles(
                      [XFile(doc.pdfFile.path, mimeType: 'application/pdf')],
                      subject: doc.title,
                    ),
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: const Text('分享 PDF'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ResultThumb extends ConsumerWidget {
  const _ResultThumb({required this.index, required this.delay});

  final int index;
  final double delay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pages = ref.watch(sessionProvider);
    final page = pages[index];

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Ds.durEmph,
      curve: Interval(delay.clamp(0.0, 0.9), 1.0, curve: Ds.curve),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 18 * (1 - t)), child: child),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            Image.file(page.file, height: 190, fit: BoxFit.cover, cacheHeight: 570),
            Positioned(
              left: 8, bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text('${index + 1}',
                    style: const TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
