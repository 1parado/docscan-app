import 'dart:io';

import 'package:docscan_app/pages/docs_page.dart';
import 'package:docscan_app/pages/home_page.dart';
import 'package:docscan_app/state/scan_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Evidence for the "what happens when there are many documents" question.
///
/// Seeding hundreds of real scans on a phone is slow and not reproducible, so
/// this renders the two lists that consume the library with synthetic docs and
/// lets Flutter's own layout error do the asserting: a `RenderFlex` that does
/// not fit throws in debug, which `takeException` picks up.
class FakeLibrary extends Library {
  FakeLibrary(this.docs);

  final List<ScanDoc> docs;

  @override
  List<ScanDoc> build() => docs;

  @override
  Future<void> reload() async {}
}

List<ScanDoc> fakeDocs(int n) => List.generate(
      n,
      (i) => ScanDoc(
        id: 'doc-$i',
        title: '文档 $i',
        pdfFile: File('no-such-dir/$i.pdf'),
        pageCount: 1,
        createdAt: DateTime(2026, 10, 1).add(Duration(minutes: i)),
        firstPageImage: File('no-such-dir/$i.jpg'),
      ),
    );

Widget host(Widget child, List<ScanDoc> docs) => ProviderScope(
      overrides: [libraryProvider.overrideWith(() => FakeLibrary(docs))],
      child: MaterialApp(home: child),
    );

/// The test surface defaults to 800x600 logical pixels, which is far wider than
/// the phone under test (1080px at 480dpi = 360 logical). Measuring the pager
/// against the default would report a library size no real device reaches.
void useTestPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('Docs tab paginates instead of rendering every document', (tester) async {
    useTestPhone(tester);
    await tester.pumpWidget(host(const DocsPage(), fakeDocs(50)));
    await tester.pumpAndSettle();

    expect(find.byType(ListView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// The pager must fit at every library size, not just small ones.
  for (final n in [50, 65, 100, 300]) {
    testWidgets('pager fits at $n docs (${(n / 10).ceil()} pages)', (tester) async {
      useTestPhone(tester);
      await tester.pumpWidget(host(const DocsPage(), fakeDocs(n)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('pager shows a bounded window of page chips', (tester) async {
    useTestPhone(tester);
    await tester.pumpWidget(host(const DocsPage(), fakeDocs(300)));
    await tester.pumpAndSettle();

    // Only the page row carries plain numeric labels, so counting them bounds
    // the row width instead of trusting the layout to have behaved.
    final chips = find.byWidgetPredicate(
      (w) => w is Text && RegExp(r'^\d+$').hasMatch(w.data ?? ''),
    );
    expect(chips.evaluate().length, lessThanOrEqualTo(5),
        reason: 'page chips must stay a fixed window as the library grows');
  });

  testWidgets('home overview stays bounded no matter how large the library is',
      (tester) async {
    useTestPhone(tester);
    await tester.pumpWidget(host(const HomePage(), fakeDocs(500)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    // A bounded overview is a fixed window; an unbounded one would keep the
    // whole library in the widget tree.
    final titles = find.byWidgetPredicate(
      (w) => w is Text && RegExp(r'^文档 \d+$').hasMatch(w.data ?? ''),
    );
    expect(titles.evaluate().length, lessThanOrEqualTo(8),
        reason: 'the overview must show a fixed window, not the whole library');
  });
}
