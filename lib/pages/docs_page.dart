import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../design/tokens.dart';
import '../state/scan_state.dart';

/// Docs tab: the library. Rename by long-press, batch rename via multi-select,
/// print / share / delete per doc. Auto-naming matches 日期+序号.
class DocsPage extends ConsumerStatefulWidget {
  const DocsPage({super.key});

  @override
  ConsumerState<DocsPage> createState() => _DocsPageState();
}

class _DocsPageState extends ConsumerState<DocsPage> {
  List<ScanDoc>? _docs;
  final _selected = <ScanDoc>{};
  bool _selecting = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final docs = await LibraryStore.load();
    if (mounted) setState(() => _docs = docs);
  }

  Future<void> _renameOne(ScanDoc doc) async {
    final ctrl = TextEditingController(text: doc.title);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Ds.clover),
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await LibraryStore.rename(doc, name);
      _reload();
    }
  }

  Future<void> _batchRename() async {
    final ctrl = TextEditingController();
    final prefix = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('批量重命名（${_selected.length} 个）'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '前缀，如「合同」'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Ds.clover),
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    if (prefix == null || prefix.isEmpty) return;
    final docs = _selected.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (var i = 0; i < docs.length; i++) {
      await LibraryStore.rename(docs[i], '$prefix${(i + 1).toString().padLeft(2, '0')}');
    }
    setState(() {
      _selected.clear();
      _selecting = false;
    });
    _reload();
  }

  Future<void> _delete(ScanDoc doc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「${doc.title}」？'),
        content: const Text('PDF 将从设备上删除，无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Ds.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await LibraryStore.delete(doc);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final docs = _docs;

    return Scaffold(
      appBar: AppBar(
        title: Text(_selecting ? '已选 ${_selected.length}' : '文档'),
        actions: [
          if (_selecting) ...[
            TextButton(onPressed: _selected.isNotEmpty ? _batchRename : null,
                child: const Text('批量命名')),
            TextButton(
              onPressed: () => setState(() { _selected.clear(); _selecting = false; }),
              child: const Text('完成'),
            ),
          ] else
            IconButton(
              tooltip: '多选',
              onPressed: docs != null && docs.isNotEmpty ? () => setState(() => _selecting = true) : null,
              icon: const Icon(Icons.checklist),
            ),
        ],
      ),
      body: docs == null
          ? const Center(child: CircularProgressIndicator(color: Ds.clover))
          : docs.isEmpty
              ? _empty(context)
              : ListView.separated(
                  padding: EdgeInsets.only(
                      left: 16, right: 16, top: 4,
                      bottom: 100 + MediaQuery.of(context).padding.bottom),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final doc = docs[i];
                    return _DocCard(
                      doc: doc,
                      selecting: _selecting,
                      selected: _selected.contains(doc),
                      onTap: () {
                        if (_selecting) {
                          setState(() {
                            _selected.contains(doc) ? _selected.remove(doc) : _selected.add(doc);
                          });
                        } else {
                          _openDoc(doc);
                        }
                      },
                      onLongPress: () => _renameOne(doc),
                      onDelete: () => _delete(doc),
                      onShare: () => Share.shareXFiles(
                        [XFile(doc.pdfFile.path, mimeType: 'application/pdf')],
                        subject: doc.title,
                      ),
                      onPrint: () => Printing.layoutPdf(
                        onLayout: (format) async => doc.pdfFile.readAsBytes(),
                      ),
                    );
                  },
                ),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.folder_open, size: 52, color: Colors.black.withValues(alpha: 0.18)),
          const SizedBox(height: 12),
          const Text('还没有文档', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          const SizedBox(height: 4),
          const Text('扫描完成后会出现在这里', style: TextStyle(color: Ds.textDim, fontSize: 13)),
        ],
      ),
    );
  }

  Future<void> _openDoc(ScanDoc doc) async {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('分享 PDF'),
              onTap: () {
                Navigator.pop(context);
                Share.shareXFiles([XFile(doc.pdfFile.path, mimeType: 'application/pdf')],
                    subject: doc.title);
              },
            ),
            ListTile(
              leading: const Icon(Icons.print_outlined),
              title: const Text('打印'),
              onTap: () {
                Navigator.pop(context);
                Printing.layoutPdf(onLayout: (format) async => doc.pdfFile.readAsBytes());
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(context);
                _renameOne(doc);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Ds.danger),
              title: Text('删除', style: TextStyle(color: Ds.danger)),
              onTap: () {
                Navigator.pop(context);
                _delete(doc);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DocCard extends StatelessWidget {
  const _DocCard({
    required this.doc,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onDelete,
    required this.onShare,
    required this.onPrint,
  });

  final ScanDoc doc;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;
  final VoidCallback onShare;
  final VoidCallback onPrint;

  @override
  Widget build(BuildContext context) {
    final date = '${doc.createdAt.month}月${doc.createdAt.day}日 '
        '${doc.createdAt.hour.toString().padLeft(2, '0')}:${doc.createdAt.minute.toString().padLeft(2, '0')}';

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: Ds.durFast,
        curve: Ds.curve,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(Ds.radiusSmall),
          border: selected ? Border.all(color: Ds.clover, width: 2) : Border.all(color: Colors.black.withValues(alpha: 0.06)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 3))],
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(Ds.radiusSmall)),
              child: SizedBox(
                width: 64, height: 84,
                child: doc.firstPageImage.existsSync()
                    ? Image.file(doc.firstPageImage, fit: BoxFit.cover)
                    : const ColoredBox(color: Ds.frost),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(doc.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    const SizedBox(height: 3),
                    Text('$date · ${doc.pageCount} 页',
                        style: const TextStyle(color: Ds.textDim, fontSize: 12.5)),
                  ],
                ),
              ),
            ),
            if (!selecting)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(icon: const Icon(Icons.ios_share, size: 20), onPressed: onShare,
                      tooltip: '分享'),
                  IconButton(icon: Icon(Icons.delete_outline, size: 20, color: Ds.danger),
                      onPressed: onDelete, tooltip: '删除'),
                ],
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 14),
                child: Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected ? Ds.clover : Ds.textDim,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
