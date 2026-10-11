import 'dart:convert';

import 'import_model.dart';
import 'kml_parser.dart';
import 'kmz_parser.dart';
import 'ovjsn_parser.dart';
import 'ovobj_parser.dart';

/// 导入文件头路由：按扩展名（不分大小写）分发到各解析器。
///
/// - kml / ovkml → [KmlParser]（文本解码，允许 malformed）
/// - kmz / ovkmz → [KmzParser]
/// - ovjsn → [OvjsnParser]
/// - ovobj → [OvobjParser]
///
/// 不支持的扩展名抛 [FormatException]；解析出 0 要素返回 null。
/// 纯静态、无 UI 依赖；大文件时由 UI 层经 `Isolate.run` 调用。
class Importer {
  Importer._();

  static ImportParseResult? parseFile(String fileName, List<int> bytes) {
    final ext = _extOf(fileName);
    final base = baseNameWithoutExt(fileName);
    final ImportParseResult result;
    switch (ext) {
      case 'kml':
      case 'ovkml':
        result = KmlParser.parse(_decodeText(bytes)).withFileName(base);
      case 'kmz':
      case 'ovkmz':
        result = KmzParser.parseBytes(bytes, fileName: fileName);
      case 'ovjsn':
        result = OvjsnParser.parse(_decodeText(bytes), fileName: fileName);
      case 'ovobj':
        result = OvobjParser.parseBytes(bytes, fileName: fileName);
      default:
        throw FormatException(
          '不支持的文件格式: ${ext.isEmpty ? '(无扩展名)' : '.$ext'}'
          '（支持 kml/kmz/ovkml/ovkmz/ovjsn/ovobj）',
        );
    }
    return result.isEmpty ? null : result;
  }

  static String _extOf(String fileName) {
    final base = fileName.split(RegExp(r'[\\/]')).last;
    final dot = base.lastIndexOf('.');
    if (dot < 0 || dot == base.length - 1) return '';
    return base.substring(dot + 1).toLowerCase();
  }

  static String _decodeText(List<int> bytes) {
    var s = utf8.decode(bytes, allowMalformed: true);
    if (s.startsWith('\uFEFF')) s = s.substring(1);
    return s;
  }
}
