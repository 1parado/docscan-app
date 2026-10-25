import 'dart:io';
import 'dart:typed_data';

import 'package:docscan_app/state/scan_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The session holds page files, so these cases assert two things the widget
/// tree cannot see: that a page keeps its position when re-cropped, and that
/// leaving the session actually removes the JPEGs it wrote.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('docscan_session_test');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  ScanPage pageNamed(String name) {
    final f = File('${tmp.path}/$name.jpg')..writeAsBytesSync([1, 2, 3]);
    return ScanPage(file: f, cropStatus: 'cropped');
  }

  /// A capture sitting in the queue: the file is the untouched photo.
  File rawNamed(String name) => File('${tmp.path}/$name.jpg')..writeAsBytesSync([9, 8, 7]);

  ScanSession sessionOf(ProviderContainer container) =>
      container.read(sessionProvider.notifier);

  test('replaceAt keeps the page in place', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = sessionOf(container);
    s.add(pageNamed('a'));
    s.add(pageNamed('b'));
    s.add(pageNamed('c'));

    final replacement = pageNamed('b2');
    s.replaceAt(1, replacement);

    expect(container.read(sessionProvider).map((p) => p.file.path),
        [contains('a.jpg'), contains('b2.jpg'), contains('c.jpg')],
        reason: 're-cropping the middle page must not move it to the end');
  });

  test('replaceAt and clear delete the page files they drop', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = sessionOf(container);
    final a = pageNamed('a');
    final b = pageNamed('b');
    s.add(a);
    s.add(b);

    s.replaceAt(0, pageNamed('a2'));
    expect(a.file.existsSync(), isFalse, reason: 'the replaced page file leaked');
    expect(b.file.existsSync(), isTrue);

    s.clear();
    expect(container.read(sessionProvider), isEmpty);
    expect(File('${tmp.path}/a2.jpg').existsSync(), isFalse);
    expect(b.file.existsSync(), isFalse, reason: '清空 left full-size JPEGs behind');
  });

  test('removeAt deletes only the removed page', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = sessionOf(container);
    final a = pageNamed('a');
    final b = pageNamed('b');
    s.add(a);
    s.add(b);

    s.removeAt(0);
    expect(a.file.existsSync(), isFalse);
    expect(b.file.existsSync(), isTrue);
    expect(container.read(sessionProvider).length, 1);
  });

  test('a queued capture waits for the pipeline', () {
    final fake = FakePipeline(tmp);
    final container = ProviderContainer(overrides: [sessionProvider.overrideWith(() => fake)]);
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).addPending(rawNamed('a'));
    container.read(sessionProvider.notifier).addPending(rawNamed('b'));

    expect(fake.processed, isEmpty, reason: 'selecting a photo must not process it');
    expect(container.read(sessionProvider).every((p) => p.pending), isTrue);
    expect(fake.pendingCount, 2);
  });

  test('processPending works the queue in order and reports the pages with no edge', () async {
    final fake = FakePipeline(tmp, notFoundOnCalls: {1});
    final container = ProviderContainer(overrides: [sessionProvider.overrideWith(() => fake)]);
    addTearDown(container.dispose);
    final s = container.read(sessionProvider.notifier);
    final a = rawNamed('a'), b = rawNamed('b'), c = rawNamed('c');
    s.addPending(a);
    s.addPending(b);
    s.addPending(c);

    final seen = <String>[];
    final missing =
        await s.processPending(onProgress: (done, total) => seen.add('$done/$total'));

    expect(missing, 1);
    expect(fake.processed, ['out_0', 'out_1', 'out_2'], reason: 'page order is PDF order');
    expect(seen, ['1/3', '2/3', '3/3'], reason: 'the strip needs progress, not a freeze');
    expect(container.read(sessionProvider).map((p) => p.name), ['out_0.jpg', 'out_1.jpg', 'out_2.jpg']);
    expect(container.read(sessionProvider).every((p) => !p.pending), isTrue);
    for (final raw in [a, b, c]) {
      expect(raw.existsSync(), isFalse, reason: 'the raw copy leaked in the cache dir');
    }
  });

  test('the marker the viewfinder was showing travels to the pipeline', () async {
    final fake = FakePipeline(tmp);
    final container = ProviderContainer(overrides: [sessionProvider.overrideWith(() => fake)]);
    addTearDown(container.dispose);
    final s = container.read(sessionProvider.notifier);
    final quad = [0.1, 0.1, 0.9, 0.12, 0.88, 0.9, 0.12, 0.86];

    s.addPending(rawNamed('a'), hintQuad: quad);
    s.addPending(rawNamed('b'));
    await s.processPending();

    expect(fake.hints, [quad, null], reason: 'a shot without a marker must not borrow one');
  });

  test('processPending leaves a page that already went through the pipeline', () async {
    final fake = FakePipeline(tmp);
    final container = ProviderContainer(overrides: [sessionProvider.overrideWith(() => fake)]);
    addTearDown(container.dispose);
    final s = container.read(sessionProvider.notifier);
    final queued = rawNamed('a');
    final done = pageNamed('done');
    s.addPending(queued);
    s.add(done);

    expect(await s.processPending(), 0);
    expect(fake.processed, ['out_0']);
    expect(container.read(sessionProvider).last, same(done));
  });

  test('a capture whose cache file vanished drops out of the queue', () async {
    final fake = FakePipeline(tmp);
    final container = ProviderContainer(overrides: [sessionProvider.overrideWith(() => fake)]);
    addTearDown(container.dispose);
    final s = container.read(sessionProvider.notifier);
    s.addPending(rawNamed('a'));
    s.addPending(rawNamed('b'));
    File('${tmp.path}/a.jpg').deleteSync();

    expect(await s.processPending(), 0);
    expect(container.read(sessionProvider).length, 1);
    expect(fake.processed, ['out_0'], reason: 'only the surviving capture is processed');
  });

  test('applyCorners re-crops one queued page without moving it', () async {
    final fake = FakePipeline(tmp);
    final container = ProviderContainer(overrides: [sessionProvider.overrideWith(() => fake)]);
    addTearDown(container.dispose);
    final s = container.read(sessionProvider.notifier);
    s.addPending(rawNamed('a'));
    final b = rawNamed('b');
    s.addPending(b);

    await s.applyCorners(1, [
      [0.1, 0.1],
      [0.9, 0.1],
      [0.9, 0.9],
      [0.1, 0.9]
    ]);

    final pages = container.read(sessionProvider);
    expect(pages[1].pending, isFalse, reason: 'a hand-cropped page is done');
    expect(pages[1].manualCorners, isNotNull);
    expect(pages[0].pending, isTrue, reason: 'the other page still waits its turn');
    expect(b.existsSync(), isFalse);
  });
}

/// The real pipeline wants an isolate, a JPEG decoder and path_provider's cache
/// directory — none of which a session queue test is about. Everything else,
/// including the ordering and the file deleting, is production code.
class FakePipeline extends ScanSession {
  FakePipeline(this.tmp, {this.notFoundOnCalls = const {}});

  final Directory tmp;

  /// Which output, counted from zero, comes back with no detected edge.
  final Set<int> notFoundOnCalls;
  final List<String> processed = [];

  /// The viewfinder markers that reached the pipeline, in call order.
  final List<List<double>?> hints = [];

  @override
  Future<ScanPage> processBytes(
    Uint8List bytes, {
    List<List<double>>? manualCorners,
    List<double>? quadHint,
  }) async {
    final name = 'out_${processed.length}${manualCorners == null ? '' : '_manual'}';
    processed.add(name);
    hints.add(quadHint);
    return ScanPage(
      file: File('${tmp.path}/$name.jpg')..writeAsBytesSync([4, 5, 6]),
      cropStatus: notFoundOnCalls.contains(processed.length - 1) ? 'not_found' : 'cropped',
      manualCorners: manualCorners,
    );
  }
}
