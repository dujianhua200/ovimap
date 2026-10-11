import 'dart:convert';

import 'package:archive/archive.dart';

import 'import_model.dart';
import 'kml_parser.dart';

/// KMZ / ovkmz 解析：zip 解包取 `doc.kml`（大小写不敏感、取第一个 .kml），
/// 解码后复用 [KmlParser]。纯静态、无 UI 依赖。
class KmzParser {
  KmzParser._();

  static ImportParseResult parseBytes(List<int> bytes, {String fileName = ''}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw FormatException('不是有效的 KMZ 压缩包: $e');
    }

    // 先找 doc.kml（大小写不敏感），没有则取第一个 .kml
    ArchiveFile? doc;
    for (final f in archive.files) {
      if (!f.isFile || !f.name.toLowerCase().endsWith('.kml')) continue;
      final base = f.name.split(RegExp(r'[\\/]')).last.toLowerCase();
      if (base == 'doc.kml') {
        doc = f;
        break;
      }
      doc ??= f;
    }
    if (doc == null) throw FormatException('KMZ 内未找到 doc.kml');

    var images = 0;
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final n = f.name.toLowerCase();
      if (n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg')) {
        images++;
      }
    }

    var text = utf8.decode(doc.content as List<int>, allowMalformed: true);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    final parsed = KmlParser.parse(text)
        .withFileName(baseNameWithoutExt(fileName));
    if (images == 0) return parsed;
    return ImportParseResult(
      units: parsed.units,
      detectedSystem: parsed.detectedSystem,
      warnings: [...parsed.warnings, '已忽略 $images 个图片附件'],
    );
  }
}
