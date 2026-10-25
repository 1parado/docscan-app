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
  final _selected = <ScanDoc>{};
  bool _selecting = false;

  // filters
  String _query = '';
  DateTimeRange? _range;

  // pagination
  static const _pageSize = 10;
  int _page = 0;

  List<ScanDoc> get _filtered {
    final docs = ref.read(libraryProvider);
    return docs.where((d) {
      if (_query.isNotEmpty &&
          !d.title.toLowerCase().contains(_query.toLowerCase())) {
        return false;
      }
      if (_range != null &&
          (d.createdAt.isBefore(_range!.start) ||
              d.createdAt.isAfter(_range!.end.add(const Duration(days: 1))))) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(libraryProvider.notifier).reload();
    });
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
      await ref.read(libraryProvider.notifier).rename(doc, name);
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
    final lib = ref.read(libraryProvider.notifier);
    final docs = _selected.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (var i = 0; i < docs.length; i++) {
      await lib.rename(docs[i], '$prefix${(i + 1).toString().padLeft(2, '0')}');
    }
    setState(() {
      _selected.clear();
      _selecting = false;
    });
  }

  Future<void> _batchDelete() async {
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 $n 个文档？'),
        content: const Text('选中的 PDF 将从设备上删除，无法恢复。'),
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
    if (ok != true) return;
    final lib = ref.read(libraryProvider.notifier);
    for (final doc in _selected.toList()) {
      await lib.delete(doc);
    }
    setState(() {
      _selected.clear();
      _selecting = false;
      _page = 0;
    });
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now.add(const Duration(days: 1)),
      initialDateRange: _range,
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(primary: Ds.clover),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _range = picked;
        _page = 0;
      });
    }
  }

  void _openViewer(ScanDoc doc) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PdfViewerPage(doc: doc),
    ));
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
      await ref.read(libraryProvider.notifier).delete(doc);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(libraryProvider);
    final all = _filtered;
    final pageCount = (all.length / _pageSize).ceil().clamp(1, 1 << 20);
    final safePage = _page.clamp(0, pageCount - 1);
    final pageDocs = all.skip(safePage * _pageSize).take(_pageSize).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(_selecting ? '已选 ${_selected.length}' : '文档'),
        actions: [
          if (_selecting) ...[
            TextButton(onPressed: _selected.isNotEmpty ? _batchRename : null,
                child: const Text('批量命名')),
            TextButton(
              onPressed: _selected.isNotEmpty ? _batchDelete : null,
              child: Text('删除', style: TextStyle(color: Ds.danger)),
            ),
            TextButton(
              onPressed: () => setState(() { _selected.clear(); _selecting = false; }),
              child: const Text('完成'),
            ),
          ] else
            IconButton(
              tooltip: '多选',
              onPressed: all.isNotEmpty ? () => setState(() => _selecting = true) : null,
              icon: const Icon(Icons.checklist),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (v) => setState(() { _query = v; _page = 0; }),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '按名称筛选',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      contentPadding: const EdgeInsets.symmetric(vertical: 9),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _pickDateRange,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: _range != null ? Ds.clover.withValues(alpha: 0.12) : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.date_range, size: 16,
                            color: _range != null ? Ds.clover : Ds.textDim),
                        const SizedBox(width: 5),
                        Text(_range == null
                                ? '日期'
                                : '${_range!.start.month}/${_range!.start.day}-${_range!.end.month}/${_range!.end.day}',
                            style: TextStyle(
                                fontSize: 12.5,
                                color: _range != null ? Ds.clover : Ds.textDim,
                                fontWeight: _range != null ? FontWeight.w600 : FontWeight.w400)),
                      ],
                    ),
                  ),
                ),
                if (_range != null || _query.isNotEmpty)
                  GestureDetector(
                    onTap: () => setState(() { _query = ''; _range = null; _page = 0; }),
                    child: const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.close, size: 18, color: Ds.textDim),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('${all.length} 个文档',
                style: const TextStyle(color: Ds.textDim, fontSize: 11.5)),
          ),
          Expanded(
            child: all.isEmpty
                ? _empty(context)
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    itemCount: pageDocs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final doc = pageDocs[i];
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
                          _openViewer(doc);
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
          ),
          if (pageCount > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: safePage > 0 ? () => setState(() => _page = safePage - 1) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  for (final p in pageSlots(safePage, pageCount))
                    if (p == null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text('…',
                            style: TextStyle(fontSize: 12.5, color: Ds.textDim)),
                      )
                    else
                      GestureDetector(
                        onTap: () => setState(() => _page = p),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: p == safePage ? Ds.clover : Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: p == safePage ? Ds.clover : Colors.black.withValues(alpha: 0.08)),
                          ),
                          child: Text('${p + 1}', style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: p == safePage ? FontWeight.w600 : FontWeight.w400,
                              color: p == safePage ? Colors.white : Ds.textDim)),
                        ),
                      ),
                  IconButton(
                    onPressed: safePage < pageCount - 1 ? () => setState(() => _page = safePage + 1) : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            )
          else
            SizedBox(height: MediaQuery.of(context).padding.bottom + 24),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final filtered = _query.isNotEmpty || _range != null;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(filtered ? Icons.search_off : Icons.folder_open,
              size: 52, color: Colors.black.withValues(alpha: 0.18)),
          const SizedBox(height: 12),
          Text(filtered ? '没有匹配的文档' : '还没有文档',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          const SizedBox(height: 4),
          Text(filtered ? '换个名称或日期范围试试' : '扫描完成后会出现在这里',
              style: const TextStyle(color: Ds.textDim, fontSize: 13)),
        ],
      ),
    );
  }

}

/// Page chips to show, capped at five slots whatever the library size:
/// first, gap, current, gap, last. The row that holds these has a fixed screen
/// width, so rendering one chip per page clipped off the edge from ~65 documents
/// onward (measured: 35px past the right edge at 7 pages, 1286px at 30).
List<int?> pageSlots(int current, int total) {
  if (total <= 5) return [for (var p = 0; p < total; p++) p];
  final keep = <int>{0, total - 1, current}.toList()..sort();
  final slots = <int?>[];
  for (var i = 0; i < keep.length; i++) {
    if (i > 0 && keep[i] - keep[i - 1] > 1) slots.add(null);
    slots.add(keep[i]);
  }
  return slots;
}

/// In-app PDF viewer: scrollable rendered pages, no external app.
class _PdfViewerPage extends StatelessWidget {
  const _PdfViewerPage({required this.doc});

  final ScanDoc doc;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.ink,
      appBar: AppBar(
        backgroundColor: Ds.ink,
        foregroundColor: Colors.white,
        title: Text(doc.title, style: const TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            tooltip: '分享',
            onPressed: () => Share.shareXFiles(
              [XFile(doc.pdfFile.path, mimeType: 'application/pdf')],
              subject: doc.title,
            ),
            icon: const Icon(Icons.ios_share),
          ),
        ],
      ),
      body: PdfPreview(
        build: (format) async => doc.pdfFile.readAsBytes(),
        allowPrinting: false,
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
        maxPageWidth: 700,
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

    // The row has to be one labelled element: gestures alone leave this
    // ROM exposing no node for the card at all, so neither TalkBack nor
    // uiautomator can tell one document from another.
    return Semantics(
      container: true,
      button: true,
      label: '${doc.title}，${date} · ${doc.pageCount} 页',
      onTap: onTap,
      onLongPress: onLongPress,
      child: GestureDetector(
        excludeFromSemantics: true,
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
                    ? Image.file(doc.firstPageImage, fit: BoxFit.cover, cacheWidth: 200)
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
    ),
  );
}
}
