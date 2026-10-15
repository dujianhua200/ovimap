import '../models/map_label.dart';
import 'import_model.dart';

/// 增强 KML 解析器（标准 KML 与奥维导出的 ovkml 均为 KML 文本，走同一解析）。
///
/// 相对老解析器（`lib/export/kml_import.dart`，保持不动）新增：
/// - 保留 `<Folder>` 嵌套层级 → 每个 Placemark 附带 [FolderPath]
/// - `<description>` → [ImportUnit.description]（CDATA/HTML 实体处理）
/// - `<OvCoordType>` 识别（GCJ02/GCJ-02/火星 → 转 WGS-84；CGCS2000 视为 WGS-84）
/// - Polygon 只取外环（`<outerBoundaryIs>`），按闭合线链输出
/// - 同一 Folder 直属 Placemark 合并为一个 [ImportUnit]；根级 Placemark
///   合并为一个单元，name 用 '' 占位，由 [ImportParseResult.withFileName] 补齐
///
/// 纯静态、无 UI 依赖、零第三方依赖；大文件时由 UI 层经 `Isolate.run` 调用。
class KmlParser {
  KmlParser._();

  // 文档顺序 token：Folder 开/闭标签，或整个 Placemark 块（Placemark 不嵌套）。
  static final _tokenRe = RegExp(
    r'<Folder[\s>]|</Folder\s*>|<Placemark[\s>][\s\S]*?</Placemark\s*>',
  );
  static final _placemarkStripRe = RegExp(
    r'<Placemark[\s>][\s\S]*?</Placemark\s*>',
  );
  static final _nameRe = RegExp(r'<name[^>]*>([\s\S]*?)</name\s*>');
  static final _descRe = RegExp(
    r'<description[^>]*>([\s\S]*?)</description\s*>',
  );
  static final _coordRe = RegExp(
    r'<coordinates[^>]*>([\s\S]*?)</coordinates\s*>',
  );
  static final _outerRingRe = RegExp(
    r'<outerBoundaryIs[\s>][\s\S]*?<coordinates[^>]*>([\s\S]*?)</coordinates\s*>',
  );
  static final _coordTypeRe = RegExp(
    r'<OvCoordType[^>]*>([\s\S]*?)</OvCoordType\s*>',
  );
  static final _cdataRe = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>');
  static final _pointRe = RegExp(r'<Point[\s>]');
  static final _lineRe = RegExp(r'<LineString[\s>]|<LinearRing[\s>]');
  static final _polyRe = RegExp(r'<Polygon[\s>]');

  /// 解析 KML 文本。全部输出坐标已统一为 WGS-84。
  static ImportParseResult parse(String xml) {
    final docSystem = _detectDocSystem(xml);
    final docGcj = docSystem == 'GCJ02';
    final warnings = <String>[];

    final stack = <String>[];
    final builders = <String, _UnitBuilder>{};
    final order = <String>[];
    final tokens = _tokenRe.allMatches(xml).toList();
    var sawGcj = false;

    for (var i = 0; i < tokens.length; i++) {
      final m = tokens[i];
      final tok = m.group(0)!;
      if (tok.startsWith('<Folder')) {
        // Folder 头：取 <Folder> 标签与下一个 token 之间的 <name>
        final segEnd = i + 1 < tokens.length ? tokens[i + 1].start : xml.length;
        final head = xml.substring(m.end, segEnd);
        stack.add(_cleanText(_nameRe.firstMatch(head)?.group(1) ?? ''));
      } else if (tok.startsWith('</Folder')) {
        if (stack.isNotEmpty) stack.removeLast();
      } else {
        if (_parsePlacemark(tok, List.of(stack), docGcj, builders, order)) {
          sawGcj = true;
        }
      }
    }

    final units = <ImportUnit>[];
    for (final key in order) {
      final b = builders[key]!;
      if (b.labels.isEmpty) continue;
      for (var i = 0; i < b.labels.length; i++) {
        b.labels[i].seq = i + 1;
      }
      units.add(
        ImportUnit(
          folderPath: b.folderPath,
          name: b.displayName,
          labels: b.labels,
          description: _cappedDescription(b.descriptions),
        ),
      );
    }
    return ImportParseResult(
      units: units,
      detectedSystem: (sawGcj || docSystem == 'GCJ02') ? 'GCJ02' : docSystem,
      warnings: warnings,
    );
  }

  /// 文档级坐标系：只看 Placemark 之外的 `<OvCoordType>`（Document/Folder 级），
  /// 任一为 GCJ 系 → 'GCJ02'；否则任一出现过 → 'CGCS2000'；否则 'WGS84'。
  /// Placemark 自带的 `<OvCoordType>` 只影响自身（缺省 WGS84，不向兄弟扩散）。
  static String _detectDocSystem(String xml) {
    final stripped = xml.replaceAll(_placemarkStripRe, '');
    var seen = false;
    for (final m in _coordTypeRe.allMatches(stripped)) {
      seen = true;
      if (_isGcjValue(m.group(1) ?? '')) return 'GCJ02';
    }
    return seen ? 'CGCS2000' : 'WGS84';
  }

  /// GCJ02 / GCJ-02 / 火星（及常见变体）→ true；CGCS2000/缺省 → false。
  static bool _isGcjValue(String v) {
    final t = v.trim().toUpperCase();
    return t.contains('GCJ') || v.contains('火星') || t.contains('MARS');
  }

  /// 返回该 Placemark 是否为 GCJ-02 坐标（供 detectedSystem 统计）。
  static bool _parsePlacemark(
    String body,
    List<String> folderPath,
    bool docGcj,
    Map<String, _UnitBuilder> builders,
    List<String> order,
  ) {
    final name = _cleanText(_nameRe.firstMatch(body)?.group(1) ?? '');
    final desc = _cleanText(_descRe.firstMatch(body)?.group(1) ?? '');
    final typeMatch = _coordTypeRe.firstMatch(body);
    final isGcj = typeMatch == null ? docGcj : _isGcjValue(typeMatch.group(1)!);

    final hasPoint = _pointRe.hasMatch(body);
    final hasLine = _lineRe.hasMatch(body);
    final hasPoly = _polyRe.hasMatch(body);

    final labels = <MapLabel>[];
    if (hasPoint && !hasLine && !hasPoly) {
      final blocks = _coordRe.allMatches(body).toList();
      if (blocks.isNotEmpty) {
        final c = _parseCoords(blocks.first.group(1)!);
        if (c.isNotEmpty) {
          final w = importToWgs84(c[0][0], c[0][1], isGcj02: isGcj);
          labels.add(
            MapLabel(
              typeId: 'pipe',
              lat: w[0],
              lon: w[1],
              name: name,
              note: desc,
            ),
          );
        }
      }
    } else {
      // 线/面：每个逻辑链独立 lineGroupId；Polygon 只取外环并闭合。
      final chains = <List<List<double>>>[];
      if (hasPoly) {
        for (final m in _outerRingRe.allMatches(body)) {
          final c = _parseCoords(m.group(1)!);
          if (c.length >= 2) chains.add(_closeRing(c));
        }
      } else {
        for (final m in _coordRe.allMatches(body)) {
          final c = _parseCoords(m.group(1)!);
          if (c.length >= 2) chains.add(c);
        }
      }
      for (final chain in chains) {
        final gid = MapLabel().id;
        for (var i = 0; i < chain.length; i++) {
          final w = importToWgs84(chain[i][0], chain[i][1], isGcj02: isGcj);
          labels.add(
            MapLabel(
              typeId: 'pipe',
              lat: w[0],
              lon: w[1],
              name: i == 0 ? name : '',
              note: desc,
              lineGroupId: gid,
            ),
          );
        }
      }
    }
    if (labels.isEmpty) return isGcj;

    final key = folderPath.join('\u0000');
    final b = builders.putIfAbsent(key, () {
      order.add(key);
      return _UnitBuilder(folderPath);
    });
    b.labels.addAll(labels);
    if (desc.isNotEmpty) {
      b.descriptions.add(desc); // Set 去重 O(1)；原 List.contains 是 O(n²)
    }
    return isGcj;
  }

  /// "lon,lat[,alt]" 序列（空格/换行分隔）→ [lat, lon] 列表，过滤非法与重复。
  /// 与老 KmlImporter._parseCoords 同规则。
  static List<List<double>> _parseCoords(String raw) {
    final out = <List<double>>[];
    final seen = <String>{};
    for (final tok in raw.split(RegExp(r'\s+'))) {
      final t = tok.trim();
      if (t.isEmpty) continue;
      final parts = t.split(',');
      if (parts.length < 2) continue;
      final lon = double.tryParse(parts[0].trim());
      final lat = double.tryParse(parts[1].trim());
      if (lon == null || lat == null) continue;
      if (lat < -90 || lat > 90 || lon < -180 || lon > 180) continue;
      final key = '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
      if (!seen.add(key)) continue;
      out.add([lat, lon]);
    }
    return out;
  }

  /// 面外环首尾闭合（容差 1e-9 度）。
  static List<List<double>> _closeRing(List<List<double>> pts) {
    if (pts.length >= 2) {
      final a = pts.first, b = pts.last;
      if ((a[0] - b[0]).abs() > 1e-9 || (a[1] - b[1]).abs() > 1e-9) {
        return [
          ...pts,
          [a[0], a[1]],
        ];
      }
    }
    return pts;
  }

  /// 去 CDATA 包裹、解常见 XML 实体、trim。
  static String _cleanText(String raw) {
    var s = raw;
    final cd = _cdataRe.firstMatch(s);
    if (cd != null) s = cd.group(1)!;
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .trim();
  }
}

/// 同一 Folder 路径下 Placemark 的累积器（文档顺序）。
class _UnitBuilder {
  final FolderPath folderPath;
  final List<MapLabel> labels = [];
  final Set<String> descriptions = {};

  _UnitBuilder(this.folderPath);

  /// 单元显示名：直接父 Folder 名；根级返回 ''（占位，调用方补文件名）。
  String get displayName {
    if (folderPath.isEmpty) return '';
    final last = folderPath.last;
    return last.isEmpty ? '未命名' : last;
  }
}

/// 描述汇总：去重后最多取 8 条、总长截断到 8000 字符（按 rune 安全截断，
/// 不切散 UTF-16 代理对）。
///
/// ImportUnit.description 目前无消费方（仅作提示，不随导入写盘）；不截断时
/// 万级 Placemark 各带长描述会 join 出几十 MB 的无用字符串（实测 18000 点
/// 单 Folder 达 2.4MB），且与去重一起放大内存/CPU。
String? _cappedDescription(Set<String> descriptions) {
  if (descriptions.isEmpty) return null;
  final joined = descriptions.take(8).join('\n');
  if (joined.length <= 8000) return joined;
  return String.fromCharCodes(joined.runes.take(8000));
}
