import '../geo/geo_util.dart';
import '../models/map_label.dart';

/// 材料表的一行：大类 / 名称（规格） / 规格说明 / 单位 / 数量。
class MaterialRow {
  final String category;
  final String name;
  final String spec;
  final String unit;
  final double quantity;

  const MaterialRow({
    required this.category,
    required this.name,
    this.spec = '',
    required this.unit,
    required this.quantity,
  });
}

/// 材料汇总结果：行 + 计算过程中的提示（未填型号段数等）。
class MaterialSummary {
  final List<MaterialRow> rows;
  final List<String> notes;

  const MaterialSummary({required this.rows, required this.notes});
}

/// 数量显示：整数去 ".0"，否则保留 1 位小数。
String fmtMaterialQty(double q) =>
    q == q.roundToDouble() ? '${q.toInt()}' : q.toStringAsFixed(1);

/// 大类下拉候选（与下述归类产出的大类一一对应）。
const List<String> kMaterialCategories = [
  '光缆',
  '电杆',
  '接头盒',
  '分光设备',
  '管道井',
  '引上',
  '钢绞线',
  '其它',
];

/// 按归类规则从点位生成材料汇总表（纯函数，可单测）。
///
/// 链段口径：段长一律走 [GeoUtil.segLenLabelFirst]（标注优先），与地图/导出一致。
///
/// 归类规则：
/// - 光缆：按 segCable 型号分组，数量 = 各段（段长 + 盘留 slackM）求和，单位 米；
///   segCable 为空的段不计入，并在 notes 给出"有 N 段未填型号"提示；
/// - 电杆：按 typeId 分组（水泥杆 / 木杆 / 电力杆，role==5），单位 根；
/// - 接头盒：数量 = 链段总数（每段末计一个接头盒），单位 个；
/// - 分光设备：按 typeId 分组（分光器箱 / 分纤盒 / ONU 箱 / 交接箱，
///   role 1/2/3/4），单位 个；
/// - 管道井：按 typeId 分组（人孔 / 手井），单位 座；
/// - 引上：riser 点数量，单位 处；
/// - 钢绞线：架空段（segKind==1）总长（架空光缆配套钢绞线，长度 = 架空段长，
///   不含盘留），单位 米；
/// - 标石：暂无对应类型，跳过（不误报）。
MaterialSummary buildMaterialSummary(List<MapLabel> labels) {
  final rows = <MaterialRow>[];
  final notes = <String>[];

  // ---- 链段统计 ----
  final cableLen = <String, double>{}; // segCable 型号 -> Σ(段长 + 盘留)
  var totalSegments = 0;
  var untypedSegments = 0;
  var aerialLen = 0.0; // 架空段总长（钢绞线）

  for (final chain in buildLabelChains(labels)) {
    for (var i = 1; i < chain.length; i++) {
      final a = chain[i - 1], b = chain[i];
      final d = GeoUtil.segLenLabelFirst(a, b);
      totalSegments++;
      if (b.segKind == 1) aerialLen += d;
      final spec = b.segCable.trim();
      if (spec.isEmpty) {
        untypedSegments++;
      } else {
        cableLen[spec] = (cableLen[spec] ?? 0) + d + b.slackM;
      }
    }
  }

  // ---- 光缆 ----
  final cableSpecs = cableLen.keys.toList()..sort();
  for (final spec in cableSpecs) {
    rows.add(MaterialRow(
      category: '光缆',
      name: spec,
      spec: _coresText(spec),
      unit: '米',
      quantity: cableLen[spec]!,
    ));
  }
  if (untypedSegments > 0) {
    notes.add('有 $untypedSegments 段光缆未填型号，已排除在光缆长度外');
  }

  // ---- 电杆（role==5） ----
  const poleOrder = ['concrete', 'wood', 'electric'];
  final poleCount = <String, int>{};
  for (final l in labels) {
    if (l.type.role != 5) continue;
    poleCount[l.typeId] = (poleCount[l.typeId] ?? 0) + 1;
  }
  for (final id in poleOrder) {
    final n = poleCount[id] ?? 0;
    if (n == 0) continue;
    rows.add(MaterialRow(
      category: '电杆',
      name: poleName(id),
      unit: '根',
      quantity: n.toDouble(),
    ));
  }
  // role==5 但非预置三种（自定义类型）：按实际名称兜底一行。
  final poleExtra = poleCount.keys.where((id) => !poleOrder.contains(id));
  for (final id in poleExtra) {
    final l = labels.firstWhere((e) => e.typeId == id);
    rows.add(MaterialRow(
      category: '电杆',
      name: l.type.name,
      unit: '根',
      quantity: poleCount[id]!.toDouble(),
    ));
  }

  // ---- 接头盒（= 链段总数） ----
  if (totalSegments > 0) {
    rows.add(MaterialRow(
      category: '接头盒',
      name: '接头盒',
      unit: '个',
      quantity: totalSegments.toDouble(),
    ));
  }

  // ---- 分光设备（role 1/2/3/4） ----
  const boxOrder = ['splitterbox', 'fiberbox', 'onubox', 'crossbox'];
  final boxCount = <String, int>{};
  for (final l in labels) {
    final role = l.type.role;
    if (role < 1 || role > 4) continue;
    boxCount[l.typeId] = (boxCount[l.typeId] ?? 0) + 1;
  }
  final boxIds = [
    for (final id in boxOrder)
      if (boxCount.containsKey(id)) id,
    ...boxCount.keys.where((id) => !boxOrder.contains(id)),
  ];
  for (final id in boxIds) {
    final l = labels.firstWhere((e) => e.typeId == id);
    rows.add(MaterialRow(
      category: '分光设备',
      name: l.type.name,
      unit: '个',
      quantity: boxCount[id]!.toDouble(),
    ));
  }

  // ---- 管道井（人孔 / 手井） ----
  const wellOrder = ['manhole', 'handwell'];
  final wellCount = <String, int>{};
  for (final l in labels) {
    if (l.typeId != 'manhole' && l.typeId != 'handwell') continue;
    wellCount[l.typeId] = (wellCount[l.typeId] ?? 0) + 1;
  }
  for (final id in wellOrder) {
    final n = wellCount[id] ?? 0;
    if (n == 0) continue;
    final l = labels.firstWhere((e) => e.typeId == id);
    rows.add(MaterialRow(
      category: '管道井',
      name: l.type.name,
      unit: '座',
      quantity: n.toDouble(),
    ));
  }

  // ---- 引上 ----
  final riserCount = labels.where((l) => l.typeId == 'riser').length;
  if (riserCount > 0) {
    rows.add(MaterialRow(
      category: '引上',
      name: '引上',
      unit: '处',
      quantity: riserCount.toDouble(),
    ));
  }

  // ---- 钢绞线（架空段总长） ----
  if (aerialLen > 0) {
    rows.add(MaterialRow(
      category: '钢绞线',
      name: '钢绞线',
      spec: '架空配套',
      unit: '米',
      quantity: aerialLen,
    ));
  }

  return MaterialSummary(rows: rows, notes: notes);
}

/// 预置杆型的中文名；未知 id 回退类型名。
String poleName(String typeId) {
  switch (typeId) {
    case 'concrete':
      return '水泥杆';
    case 'wood':
      return '木杆';
    case 'electric':
      return '电力杆';
    default:
      return typeId;
  }
}

/// 解析光缆型号里的芯数："48芯GYTS" → "48芯"；无则空串。
String _coresText(String spec) {
  final m = RegExp(r'(\d+)\s*芯').firstMatch(spec);
  return m == null ? '' : '${m.group(1)}芯';
}

String _csvEscape(String value) {
  if (value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

/// 材料表 CSV 文本（纯函数；UTF-8 BOM 与写文件由调用方处理）。
String buildMaterialCsv(
    String title, List<MaterialRow> rows, List<String> notes) {
  final sb = StringBuffer();
  sb.write('材料表,${_csvEscape(title)}\r\n');
  sb.write('大类,名称/规格,规格说明,单位,数量\r\n');
  for (final r in rows) {
    sb.write('${_csvEscape(r.category)},'
        '${_csvEscape(r.name)},'
        '${_csvEscape(r.spec)},'
        '${_csvEscape(r.unit)},'
        '${fmtMaterialQty(r.quantity)}\r\n');
  }
  if (notes.isNotEmpty) {
    sb.write('\r\n备注\r\n');
    for (final n in notes) {
      sb.write('${_csvEscape(n)}\r\n');
    }
  }
  sb.write('\r\n口径说明,'
      '段长=标注优先口径（GeoUtil.segLenLabelFirst）；竣工光缆用量=段长+接头盘留；'
      '接头盒=链段总数（每段末计一个）；标石暂无对应类型未计列\r\n');
  return sb.toString();
}
