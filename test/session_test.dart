import 'dart:io';

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
}
