import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/design/material_table.dart';
import 'package:ovimap/models/map_label.dart';

MapLabel _pt({
  required String typeId,
  int seq = 1,
  String group = 'g',
  String distLabel = '100',
  String segCable = '',
  double slackM = 0,
  int segKind = 0,
}) =>
    MapLabel(
      typeId: typeId,
      seq: seq,
      lat: 32.0,
      lon: 114.0,
      lineGroupId: group,
      distLabel: distLabel,
      segCable: segCable,
      slackM: slackM,
      segKind: segKind,
    );

/// 3 段链（4 点）+ 1 分光器箱 + 1 引上，用于综合断言。
List<MapLabel> _fixture() => [
      _pt(typeId: 'concrete', seq: 1), // 起点（段属性记在段末点上）
      _pt(
          typeId: 'concrete',
          seq: 2,
          segCable: '48芯GYTS',
          slackM: 5,
          segKind: 1), // 段1：100m 架空
      _pt(
          typeId: 'wood',
          seq: 3,
          distLabel: '200',
          segCable: '48芯GYTS',
          segKind: 1), // 段2：200m 架空
      _pt(
          typeId: 'manhole',
          seq: 4,
          distLabel: '50',
          segCable: '12芯GYTA',
          segKind: 2), // 段3：50m 埋地
      _pt(typeId: 'splitterbox', seq: 5, group: ''), // 独立个体，不入链
      _pt(typeId: 'riser', seq: 6, group: ''),
    ];

MaterialRow _rowOf(List<MaterialRow> rows, String category, String name) =>
    rows.firstWhere((r) => r.category == category && r.name == name);

void main() {
  group('buildMaterialSummary', () {
    test('光缆按型号分组求和（含 slackM）', () {
      final s = buildMaterialSummary(_fixture());
      final a = _rowOf(s.rows, '光缆', '48芯GYTS');
      // 段1：100 + 盘留 5；段2：200 → 305
      expect(a.quantity, 305);
      expect(a.unit, '米');
      expect(a.spec, '48芯');
      final b = _rowOf(s.rows, '光缆', '12芯GYTA');
      expect(b.quantity, 50);
      expect(s.notes, isEmpty);
    });

    test('电杆按类型计数', () {
      final s = buildMaterialSummary(_fixture());
      expect(_rowOf(s.rows, '电杆', '水泥杆').quantity, 2);
      expect(_rowOf(s.rows, '电杆', '水泥杆').unit, '根');
      expect(_rowOf(s.rows, '电杆', '木杆').quantity, 1);
      // 没有电力杆 → 不出零行
      expect(s.rows.where((r) => r.name == '电力杆'), isEmpty);
    });

    test('接头盒 = 链段总数', () {
      final s = buildMaterialSummary(_fixture());
      final j = _rowOf(s.rows, '接头盒', '接头盒');
      expect(j.quantity, 3);
      expect(j.unit, '个');
    });

    test('分光设备 / 管道井 / 引上归类', () {
      final s = buildMaterialSummary(_fixture());
      expect(_rowOf(s.rows, '分光设备', '分光器箱').quantity, 1);
      expect(_rowOf(s.rows, '管道井', '人孔').quantity, 1);
      expect(_rowOf(s.rows, '管道井', '人孔').unit, '座');
      expect(_rowOf(s.rows, '引上', '引上').quantity, 1);
      expect(_rowOf(s.rows, '引上', '引上').unit, '处');
    });

    test('架空段钢绞线长度 = 架空段长（不含盘留、埋地不计）', () {
      final s = buildMaterialSummary(_fixture());
      final g = _rowOf(s.rows, '钢绞线', '钢绞线');
      expect(g.quantity, 300); // 段1 100 + 段2 200；埋地段3 不计
      expect(g.unit, '米');
    });

    test('segCable 为空的段不计入光缆并给出提示', () {
      final labels = [
        _pt(typeId: 'concrete', seq: 1),
        _pt(typeId: 'concrete', seq: 2, distLabel: '100'), // 未填型号
        _pt(typeId: 'concrete', seq: 3, distLabel: '60', segCable: '24芯GYTS'),
      ];
      final s = buildMaterialSummary(labels);
      final cables = s.rows.where((r) => r.category == '光缆').toList();
      expect(cables, hasLength(1));
      expect(cables.first.quantity, 60);
      expect(s.notes, hasLength(1));
      expect(s.notes.first, contains('未填型号'));
      expect(s.notes.first, contains('1 段'));
      // 未填型号的段仍计接头盒（链段总数）
      expect(_rowOf(s.rows, '接头盒', '接头盒').quantity, 2);
    });

    test('空输入 → 空行空提示', () {
      final s = buildMaterialSummary([]);
      expect(s.rows, isEmpty);
      expect(s.notes, isEmpty);
    });

    test('独立个体（箱体/引上）不打断链、不产生虚假段', () {
      // 箱体点无 lineGroupId → buildLabelChains 跳过，链仍为 3 段
      final s = buildMaterialSummary(_fixture());
      expect(_rowOf(s.rows, '接头盒', '接头盒').quantity, 3);
    });
  });

  group('buildMaterialCsv', () {
    test('表头 + 行 + 备注齐全，CSV 转义正常', () {
      final csv = buildMaterialCsv(
        '测试工程',
        const [
          MaterialRow(
              category: '光缆',
              name: '48芯GYTS',
              spec: '48芯',
              unit: '米',
              quantity: 305),
          MaterialRow(
              category: '电杆',
              name: '水泥杆,8米', // 含逗号 → 转义
              unit: '根',
              quantity: 2),
        ],
        ['有 1 段光缆未填型号，已排除在光缆长度外'],
      );
      expect(csv, contains('大类,名称/规格,规格说明,单位,数量'));
      expect(csv, contains('光缆,48芯GYTS,48芯,米,305'));
      expect(csv, contains('电杆,"水泥杆,8米",,根,2'));
      expect(csv, contains('未填型号'));
      expect(csv, contains('口径说明'));
    });
  });

  group('fmtMaterialQty', () {
    test('整数去 .0，否则保留 1 位小数', () {
      expect(fmtMaterialQty(305), '305');
      expect(fmtMaterialQty(42.5), '42.5');
    });
  });
}
