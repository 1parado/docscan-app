import 'dart:io';

import 'package:docscan_app/state/scan_state.dart';
import 'package:docscan_app/widgets/page_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The ◀ × ▶ row is the only way a page can be moved or dropped, so these cases
/// check that each control acts on exactly the page it is drawn on — and that
/// the control is addressable by what its label says, which is also how the ADB
/// suite has to aim at it on a real device.
class FixedSession extends ScanSession {
  FixedSession(this.initial);

  final List<ScanPage> initial;

  @override
  List<ScanPage> build() => [...initial];
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('docscan_actions_test');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  List<ScanPage> pagesNamed(int n) => List.generate(
        n,
        (i) => ScanPage(
          file: File('${tmp.path}/p$i.jpg')..writeAsBytesSync([1, 2, 3]),
          cropStatus: 'cropped',
        ),
      );

  /// One container for both sides of every assertion: the widget under test and
  /// the session it actually mutates.
  Future<ProviderContainer> pumpStrip(
    WidgetTester tester,
    List<ScanPage> pages, {
    int index = 1,
  }) async {
    final container = ProviderContainer(
      overrides: [sessionProvider.overrideWith(() => FixedSession(pages))],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(child: PageActions(index: index, count: pages.length)),
        ),
      ),
    ));
    return container;
  }

  /// The list as one readable order string, with the extension dropped so
  /// 'p0.p2' means page 0 then page 2 rather than two half-names.
  String order(ProviderContainer container) => container
      .read(sessionProvider)
      .map((p) => p.name.replaceAll('.jpg', ''))
      .join('.');

  testWidgets('the row carries one labelled control per action', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpStrip(tester, pagesNamed(3));

    for (final label in ['第 2 页前移', '删除第 2 页', '第 2 页后移']) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }
    handle.dispose();
  });

  testWidgets('× removes only its own page and deletes its file', (tester) async {
    final handle = tester.ensureSemantics();
    final pages = pagesNamed(3);
    final container = await pumpStrip(tester, pages);

    await tester.tap(find.bySemanticsLabel('删除第 2 页'));
    await tester.pump();

    expect(order(container), 'p0.p2');
    expect(pages[1].file.existsSync(), isFalse, reason: 'the dropped JPEG leaked');
    expect(pages[0].file.existsSync(), isTrue);
    expect(pages[2].file.existsSync(), isTrue);
    handle.dispose();
  });

  testWidgets('◀ moves the page one step toward the front', (tester) async {
    final handle = tester.ensureSemantics();
    final pages = pagesNamed(3);
    final container = await pumpStrip(tester, pages, index: 1);

    await tester.tap(find.bySemanticsLabel('第 2 页前移'));
    await tester.pump();

    expect(order(container), 'p1.p0.p2');
    expect(pages.every((p) => p.file.existsSync()), isTrue,
        reason: 'moving a page must not delete anything');
    handle.dispose();
  });

  testWidgets('▶ moves the page one step toward the back', (tester) async {
    final handle = tester.ensureSemantics();
    final pages = pagesNamed(3);
    final container = await pumpStrip(tester, pages, index: 1);

    await tester.tap(find.bySemanticsLabel('第 2 页后移'));
    await tester.pump();

    expect(order(container), 'p0.p2.p1');
    handle.dispose();
  });

  testWidgets('the arrow that would run off the list is inert', (tester) async {
    final handle = tester.ensureSemantics();
    final pages = pagesNamed(3);
    final container = await pumpStrip(tester, pages, index: 0);

    await tester.tap(find.bySemanticsLabel('第 1 页前移'));
    await tester.pump();

    expect(order(container), 'p0.p1.p2', reason: 'the first page has no earlier place');
    expect(find.byIcon(Icons.chevron_left), findsOneWidget,
        reason: 'the disabled arrow still holds its slot so the row does not jump');
    handle.dispose();
  });
}
