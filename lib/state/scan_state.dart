import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../scan/pipeline.dart';
import 'pdf_builder.dart';

/// One page in the working scan session.
class ScanPage {
  ScanPage({
    required this.file,
    this.cropStatus = 'kept',
    this.manualCorners,
  });

  final File file; // processed, A4-aligned page JPEG
  final String cropStatus; // cropped / kept / not_found / manual
  List<List<double>>? manualCorners; // set by the adjust sheet

  String get name => file.uri.pathSegments.last;
}

/// A finished document in the library.
class ScanDoc {
  ScanDoc({
    required this.id,
    required this.title,
    required this.pdfFile,
    required this.pageCount,
    required this.createdAt,
    required this.firstPageImage,
  });

  final String id;
  String title;
  final File pdfFile;
  final int pageCount;
  final DateTime createdAt;
  final File firstPageImage;
}

enum ScanModeSetting { color, gray, bw }

final prefsProvider = FutureProvider<SharedPreferences?>((ref) async {
  try {
    return await SharedPreferences.getInstance();
  } catch (_) {
    return null;
  }
});

/// Session state: pages waiting to be exported, mode, auto-crop.
class ScanSession extends Notifier<List<ScanPage>> {
  @override
  List<ScanPage> build() => [];

  ScanModeSetting _modeSetting = ScanModeSetting.color;
  ScanModeSetting get mode => _modeSetting;

  Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _modeSetting = ScanModeSetting.values.byName(prefs.getString('mode') ?? 'color');
    _autoCrop = prefs.getBool('autoCrop') ?? true;
    ref.notifyListeners();
  }

  Future<void> setMode(ScanModeSetting m) async {
    _modeSetting = m;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mode', m.name);
    ref.notifyListeners();
  }

  bool _autoCrop = true;
  bool get autoCrop => _autoCrop;

  Future<void> setAutoCrop(bool v) async {
    _autoCrop = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoCrop', v);
    ref.notifyListeners();
  }

  void add(ScanPage page) => state = [...state, page];

  void removeAt(int i) => state = [...state]..removeAt(i);

  void reorder(int from, int to) {
    final next = [...state];
    final moved = next.removeAt(from);
    next.insert(to, moved);
    state = next;
  }

  void clear() => state = [];

  Future<Directory> _tmpDir() async => getTemporaryDirectory();

  /// Process one raw photo (JPEG bytes) through the pipeline in an isolate.
  Future<ScanPage> processBytes(
    Uint8List bytes, {
    List<List<double>>? manualCorners,
  }) async {
    final m = _modeSetting;
    final crop = _autoCrop;
    final dir = await _tmpDir();
    final path = '${dir.path}/page_${DateTime.now().microsecondsSinceEpoch}.jpg';

    final result = await Isolate.run(() => _processImpl(bytes, path, m, crop, manualCorners));

    return ScanPage(
      file: File(result.$1),
      cropStatus: result.$2,
      manualCorners: manualCorners,
    );
  }

  /// Build the PDF and move the doc into the library.
  Future<ScanDoc> exportToLibrary(String title) async {
    final docs = await documentsDir();
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final docDir = Directory('${docs.path}/$id')..createSync(recursive: true);

    final pageFiles = state.map((p) => p.file.path).toList();
    final pdfFile = File('${docDir.path}/doc.pdf');
    final pdfBytes = await Isolate.run(() => buildPdf(pageFiles));
    await pdfFile.writeAsBytes(pdfBytes);

    final coverFile = File('${docDir.path}/cover.jpg');
    if (state.isNotEmpty) {
      await coverFile.writeAsBytes(await state.first.file.readAsBytes());
    }

    final doc = ScanDoc(
      id: id,
      title: title,
      pdfFile: pdfFile,
      pageCount: state.length,
      createdAt: DateTime.now(),
      firstPageImage: coverFile,
    );
    await LibraryStore.addDoc(doc);
    clear();
    return doc;
  }
}

// Runs inside an isolate: only plain data crosses the boundary.
(String, String) _processImpl(
  Uint8List bytes,
  String outPath,
  ScanModeSetting m,
  bool crop,
  List<List<double>>? manualCorners,
) {
  final photo = decodeImage(bytes);
  final (page, st) = processPage(
    photo,
    mode: ScanMode.values.byName(m.name),
    autoCrop: crop,
    manualCorners: manualCorners,
  );
  final a4 = toA4(page);
  File(outPath).writeAsBytesSync(encodeJpeg(a4, quality: 88));
  return (outPath, st);
}

final sessionProvider = NotifierProvider<ScanSession, List<ScanPage>>(ScanSession.new);

Future<Directory> documentsDir() async {
  final base = await getApplicationDocumentsDirectory();
  return Directory('${base.path}/docs')..createSync(recursive: true);
}

/// Library persistence: one directory per doc with doc.pdf + meta.txt.
/// The filesystem is the store — no database for a list of files.
class LibraryStore {
  static Future<List<ScanDoc>> load() async {
    final dir = await documentsDir();
    final docs = <ScanDoc>[];
    for (final d in dir.listSync().whereType<Directory>()) {
      final meta = File('${d.path}/meta.txt');
      final pdf = File('${d.path}/doc.pdf');
      final cover = File('${d.path}/cover.jpg');
      if (!meta.existsSync() || !pdf.existsSync()) continue;
      final lines = meta.readAsStringSync().split('\n');
      if (lines.length < 3) continue;
      docs.add(ScanDoc(
        id: d.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
        title: lines[0],
        pdfFile: pdf,
        pageCount: int.tryParse(lines[1]) ?? 0,
        createdAt: DateTime.tryParse(lines[2]) ?? DateTime.now(),
        firstPageImage: cover.existsSync() ? cover : pdf,
      ));
    }
    docs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return docs;
  }

  static Future<void> addDoc(ScanDoc doc) async {
    File('${doc.pdfFile.parent.path}/meta.txt').writeAsStringSync(
      [doc.title, doc.pageCount.toString(), doc.createdAt.toIso8601String()].join('\n'),
    );
    final canonical = File('${doc.pdfFile.parent.path}/doc.pdf');
    if (doc.pdfFile.path != canonical.path) {
      doc.pdfFile.renameSync(canonical.path);
    }
  }

  static Future<void> rename(ScanDoc doc, String title) async {
    doc.title = title;
    final meta = File('${doc.pdfFile.parent.path}/meta.txt');
    if (meta.existsSync()) {
      final lines = meta.readAsStringSync().split('\n');
      lines[0] = title;
      meta.writeAsStringSync(lines.join('\n'));
    }
  }

  static Future<void> delete(ScanDoc doc) async {
    final dir = doc.pdfFile.parent;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

/// Suggested auto title: 日期 + 当日序号, e.g. "10月24日 扫描 2".
Future<String> suggestedTitle() async {
  final now = DateTime.now();
  final docs = await LibraryStore.load();
  final todayCount = docs
      .where((d) =>
          d.createdAt.year == now.year &&
          d.createdAt.month == now.month &&
          d.createdAt.day == now.day)
      .length;
  return '${now.month}月${now.day}日 扫描 ${todayCount + 1}';
}
