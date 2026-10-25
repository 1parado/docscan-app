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
    this.pending = false,
    this.dpi = 200,
    this.hintQuad,
  });

  final File file; // processed A4 JPEG, or the untouched capture while pending
  final String cropStatus; // cropped / kept / not_found / manual / pending
  List<List<double>>? manualCorners; // set by the adjust sheet

  /// The marker the viewfinder was showing when the shutter went, as flat
  /// normalized TLx,TLy..BLx,BLy. The full-resolution detector gets first
  /// refusal; this stands in only when it finds nothing.
  final List<double>? hintQuad;

  /// The A4 tier the pipeline chose for this page — the sheet is only as fine
  /// as the pixels the photo really carries.
  final int dpi;

  /// True while `file` is still the raw photo: the edge warp and the
  /// enhancement mode run at 下一步, not at import, so a page can be dropped or
  /// moved before the app spends an isolate on it.
  final bool pending;

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

  /// Queue a capture untouched. The picker and the shutter both hand a file
  /// here; the strip shows the raw photo until 下一步 runs the pipeline.
  void addPending(File source, {List<double>? hintQuad}) => state = [
        ...state,
        ScanPage(
          file: source,
          cropStatus: 'pending',
          pending: true,
          hintQuad: hintQuad,
        ),
      ];

  /// How many queued captures are waiting for the pipeline.
  int get pendingCount => state.where((p) => p.pending).length;

  /// Run every queued capture through the pipeline in list order, publishing
  /// each page as it lands so the strip visibly works its way along, and return
  /// the number of pages that came back with no detected edge.
  ///
  /// Sequentially on purpose: each page is its own isolate over a full-res
  /// photo, and a handful running at once is how a scanner gets killed.
  Future<int> processPending({void Function(int done, int total)? onProgress}) async {
    final next = [...state];
    final total = next.where((p) => p.pending).length;
    var done = 0;
    var missing = 0;
    for (var i = 0; i < next.length; i++) {
      final page = next[i];
      if (!page.pending) continue;
      // The cache dir is the OS's to reclaim; a capture that vanished mid
      // session drops out rather than failing the whole batch.
      if (!await page.file.exists()) {
        next.removeAt(i);
        i--;
        continue;
      }
      final fresh = await processBytes(
        await page.file.readAsBytes(),
        manualCorners: page.manualCorners,
        quadHint: page.hintQuad,
      );
      _discard(page);
      next[i] = fresh;
      if (fresh.cropStatus == 'not_found') missing++;
      state = [...next];
      onProgress?.call(++done, total);
    }
    return missing;
  }

  /// Re-crop one page in place from the adjust sheet's corners, whether or not
  /// it has been through the pipeline yet.
  Future<void> applyCorners(int index, List<List<double>> corners) async {
    final page = state[index];
    final fresh = await processBytes(
      await page.file.readAsBytes(),
      manualCorners: corners,
    );
    replaceAt(index, fresh);
  }

  /// Swap a page without changing its position — re-cropping page 2 of 3 must
  /// not silently move it to the end of the exported PDF.
  void replaceAt(int i, ScanPage page) {
    final next = [...state];
    if (i < 0 || i >= next.length) return;
    final old = next[i];
    if (!identical(old, page)) _discard(old);
    next[i] = page;
    state = next;
  }

  void removeAt(int i) {
    final next = [...state];
    final removed = next.removeAt(i);
    _discard(removed);
    state = next;
  }

  void reorder(int from, int to) {
    final next = [...state];
    final moved = next.removeAt(from);
    next.insert(to, moved);
    state = next;
  }

  void clear() {
    for (final p in state) {
      _discard(p);
    }
    state = [];
  }

  /// Each page is a full A4 JPEG in the cache dir; dropping the list without
  /// deleting the file leaves every scan ever taken sitting on the device.
  static void _discard(ScanPage page) {
    try {
      page.file.deleteSync();
    } catch (_) {
      // The OS may already have reclaimed the cache; nothing left to clean.
    }
  }

  Future<Directory> _tmpDir() async => getTemporaryDirectory();

  /// Process one raw photo (JPEG bytes) through the pipeline in an isolate.
  Future<ScanPage> processBytes(
    Uint8List bytes, {
    List<List<double>>? manualCorners,
    List<double>? quadHint,
  }) async {
    final m = _modeSetting;
    final crop = _autoCrop;
    final dir = await _tmpDir();
    final path = '${dir.path}/page_${DateTime.now().microsecondsSinceEpoch}.jpg';

    final result =
        await Isolate.run(() => _processImpl(bytes, path, m, crop, manualCorners, quadHint));

    return ScanPage(
      file: File(result.$1),
      cropStatus: result.$2,
      manualCorners: manualCorners,
      dpi: result.$3,
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
    ref.read(libraryProvider.notifier).add(doc);
    clear();
    return doc;
  }
}

// Runs inside an isolate: only plain data crosses the boundary.
(String, String, int) _processImpl(
  Uint8List bytes,
  String outPath,
  ScanModeSetting m,
  bool crop,
  List<List<double>>? manualCorners,
  List<double>? hintFlat,
) {
  final photo = decodeImage(bytes);
  // The marker came from the preview frame, so it is normalized; the photo it
  // would crop is the one the sensor wrote, at whatever size that turned out.
  List<List<double>>? hint;
  if (hintFlat != null && hintFlat.length == 8) {
    hint = [
      for (var i = 0; i < 4; i++)
        [hintFlat[i * 2] * photo.width, hintFlat[i * 2 + 1] * photo.height],
    ];
  }
  final (page, st) = processPage(
    photo,
    mode: ScanMode.values.byName(m.name),
    autoCrop: crop,
    manualCorners: manualCorners,
    quadHint: hint,
  );
  final dpi = a4DpiFor(page);
  File(outPath).writeAsBytesSync(encodeJpeg(toA4(page, dpi: dpi), quality: 88));
  return (outPath, st, dpi);
}

final sessionProvider = NotifierProvider<ScanSession, List<ScanPage>>(ScanSession.new);

/// Reactive library: bump after every add/rename/delete so the Docs tab and
/// the home recents stay in sync. (An IndexedStack tab never re-runs
/// initState, so the old "load once" approach never saw new exports.)
class Library extends Notifier<List<ScanDoc>> {
  @override
  List<ScanDoc> build() => [];

  Future<void> reload() async {
    state = await LibraryStore.load();
  }

  Future<void> add(ScanDoc doc) async {
    await LibraryStore.addDoc(doc);
    await reload();
  }

  Future<void> rename(ScanDoc doc, String title) async {
    await LibraryStore.rename(doc, title);
    await reload();
  }

  Future<void> delete(ScanDoc doc) async {
    await LibraryStore.delete(doc);
    await reload();
  }
}

final libraryProvider =
    NotifierProvider<Library, List<ScanDoc>>(Library.new);

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
        // Never fall back to the PDF here: Image.file would try to decode PDF
        // bytes as a JPEG. The list already checks existsSync() and paints a
        // placeholder when the cover is missing.
        firstPageImage: cover,
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
