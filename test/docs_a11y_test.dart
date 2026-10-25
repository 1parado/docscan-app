import 'dart:io';

import 'package:docscan_app/pages/docs_page.dart';
import 'package:docscan_app/state/scan_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeLibrary extends Library {
  FakeLibrary(this.docs);

  final List<ScanDoc> docs;

  @override
  List<ScanDoc> build() => docs;

  @override
  Future<void> reload() async {}
}

ScanDoc doc(int i) => ScanDoc(
      id: 'doc-$i',
      title: 'qa-export-0$i',
      pdfFile: File('no-such-dir/$i.pdf'),
      pageCount: 2,
      createdAt: DateTime(2026, 10, 25, 10, 47),
      firstPageImage: File('no-such-dir/$i.jpg'),
    );

/// Pumps the library tab with [docs] and an active semantics channel, and
/// returns the handle so the caller can close it inside the test body —
/// `addTearDown` runs after the binding's own handle check.
Future<SemanticsHandle> docsTab(WidgetTester tester, List<ScanDoc> docs) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final handle = tester.ensureSemantics();
  await tester.pumpWidget(ProviderScope(
    overrides: [libraryProvider.overrideWith(() => FakeLibrary(docs))],
    child: const MaterialApp(home: DocsPage()),
  ));
  await tester.pumpAndSettle();
  return handle;
}

/// What the phone reports for the same screen: 13 nodes, of which none is a
/// document title — so the suite cannot find the row it exported, and TalkBack
/// announces "分享 / 删除" for every document in the library.
void main() {
  testWidgets('each library row names its document to accessibility',
      (tester) async {
    final handle = await docsTab(tester, [doc(1), doc(2)]);

    expect(find.bySemanticsLabel(RegExp('qa-export-01')), findsOneWidget,
        reason: 'a screen reader must say which document the row is');
    expect(find.bySemanticsLabel(RegExp('qa-export-02')), findsOneWidget);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('the row is one actionable item, not a dead region',
      (tester) async {
    final handle = await docsTab(tester, [doc(1)]);

    final node =
        tester.getSemantics(find.bySemanticsLabel(RegExp('qa-export-01')).first);
    final actions = node.getSemanticsData().actions;
    expect(actions & SemanticsAction.tap.index, isNonZero);
    expect(actions & SemanticsAction.longPress.index, isNonZero,
        reason: 'long press on a row is the rename gesture');
    handle.dispose();
  });
}
