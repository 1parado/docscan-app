import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Build a multi-page A4 PDF from processed page JPEGs.
/// Pages are already on an A4 canvas (200/250/300dpi, chosen per page by the
/// pipeline), so each JPEG fills one page exactly — the same one-JPEG-per-page
/// strategy as the web project, where JPEG q88 keeps files small without
/// visible loss.
Future<Uint8List> buildPdf(List<String> pagePaths) async {
  final doc = pw.Document();
  for (final path in pagePaths) {
    final bytes = File(path).readAsBytesSync();
    final image = pw.MemoryImage(bytes);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (context) => pw.Image(image, fit: pw.BoxFit.contain),
      ),
    );
  }
  return doc.save();
}
