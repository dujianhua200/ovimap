import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/topo.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/odn/core_check.dart';

MapLabel _node(
  String id,
  String typeId,
  String name, {
  String topoParentId = '',
  String splitterRatio = '',
  String cableSpec = '',
  int cableCores = 0,
}) {
  return MapLabel(
    id: id,
    typeId: typeId,
    seq: 1,
    name: name,
    topoParentId: topoParentId,
    splitterRatio: splitterRatio,
    cableSpec: cableSpec,
    cableCores: cableCores,
  );
}

void main() {
  group('分光比解析 Topology.parseRatio', () {
    test('常见写法', () {
      expect(Topology.parseRatio('1:8'), 8);
      expect(Topology.parseRatio('1：16'), 16); // 全角冒号
      expect(Topology.parseRatio(' 1:32 '), 32); // 空格
      expect(Topology.parseRatio('1:4（备用）'), 4); // 后缀中文
    });
    test('无效输入返回 0', () {
      expect(Topology.parseRatio(null), 0);
      expect(Topology.parseRatio(''), 0);
      expect(Topology.parseRatio('abc'), 0);
      expect(Topology.parseRatio('8'), 0); // 没有冒号
      expect(Topology.parseRatio('1:0'), 0);
      expect(Topology.parseRatio('1:256'), 0); // 超过 128 上限
    });
  });

  group('芯数占用校验 CoreCheck', () {
    test('直熔超用：12 芯光缆直挂 13 个 ONU → 超 1 芯', () {
      final labels = <MapLabel>[
        _node('r', 'room', '机房'),
        _node('x', 'crossbox', '光交1',
            topoParentId: 'r', cableSpec: '12芯GYTS', cableCores: 12),
        for (var i = 1; i <= 13; i++)
          _node('u$i', 'onubox', 'ONU-$i', topoParentId: 'x'),
      ];
      final roots = Topology.buildTree(labels);
      Topology.assignTitles(roots);
      final res = CoreCheck.check(roots);

      expect(res.overEdges, hasLength(1));
      final e = res.overEdges.single;
      expect(e.parent.title, '机房');
      expect(e.child.title, '光交1');
      expect(e.total, 12);
      expect(e.used, 13); // 无分光器：下级各占各的芯
      expect(e.overBy, 1);
      expect(res.alerts.any((a) => a.isCoreOver && a.text.contains('超 1 芯')),
          isTrue);
    });

    test('分光器折算：12 芯喂 1:8 分光器带 8 盒 → 只占 1 芯，不超用', () {
      final labels = <MapLabel>[
        _node('r', 'room', '机房'),
        _node('s', 'splitterbox', '分光箱1',
            topoParentId: 'r',
            cableSpec: '12芯GYTA',
            cableCores: 12,
            splitterRatio: '1:8'),
        for (var i = 1; i <= 8; i++)
          _node('f$i', 'fiberbox', '分纤盒-$i', topoParentId: 's'),
      ];
      final roots = Topology.buildTree(labels);
      final res = CoreCheck.check(roots);

      expect(res.overEdges, isEmpty);
      expect(res.ok, isTrue);
      // 该边的已用芯数确为 1（分光器整台占 1 芯）
      final e = res.edges.single;
      expect(e.used, 1);
      expect(e.total, 12);
    });

    test('端口超用：1:4 分光器挂 5 个下级 → 端口告警（非芯数告警）', () {
      final labels = <MapLabel>[
        _node('r', 'room', '机房'),
        _node('s', 'splitterbox', '分光箱1',
            topoParentId: 'r', splitterRatio: '1:4'),
        for (var i = 1; i <= 5; i++)
          _node('f$i', 'fiberbox', '分纤盒-$i', topoParentId: 's'),
      ];
      final roots = Topology.buildTree(labels);
      final res = CoreCheck.check(roots);

      expect(res.overEdges, isEmpty);
      expect(res.alerts, hasLength(1));
      expect(res.alerts.single.isCoreOver, isFalse);
      expect(res.alerts.single.text, contains('超 1 个'));
    });

    test('无芯数边不参与校验', () {
      final labels = <MapLabel>[
        _node('r', 'room', '机房'),
        _node('x', 'crossbox', '光交1', topoParentId: 'r'), // cableCores=0
        _node('u1', 'onubox', 'ONU-1', topoParentId: 'x'),
      ];
      final roots = Topology.buildTree(labels);
      final res = CoreCheck.check(roots);
      expect(res.edges, isEmpty);
      expect(res.ok, isTrue);
    });

    test('demandOf 折算规则', () {
      // 叶子 → 1
      final leaf = _node('u', 'onubox', 'ONU');
      // 分光器（带下级）→ 1
      final sp = _node('s', 'splitterbox', '分光箱', splitterRatio: '1:8');
      // 直熔中间节点 → 下级之和
      final mid = _node('x', 'crossbox', '光交');

      final roots = Topology.buildTree([
        _node('r', 'room', '机房'),
        mid..topoParentId = 'r',
        sp..topoParentId = 'x',
        leaf..topoParentId = 'x',
        _node('f', 'fiberbox', '分纤盒', topoParentId: 's'),
      ]);
      final byId = {for (final n in Topology.flatten(roots)) n.src.id: n};
      expect(CoreCheck.demandOf(byId['u']!), 1);
      expect(CoreCheck.demandOf(byId['s']!), 1); // 分光器整台 1 芯
      expect(CoreCheck.demandOf(byId['x']!), 2); // 分光器 1 + 直连 ONU 1
    });
  });

  group('topoParentId 成环', () {
    test('双向互指不死循环', () {
      final labels = <MapLabel>[
        _node('a', 'crossbox', '光交A', topoParentId: 'b'),
        _node('b', 'crossbox', '光交B', topoParentId: 'a'),
      ];
      // 能返回即不死循环（现有环检测把互指收敛，不抛、不 hangs）
      final roots = Topology.buildTree(labels);
      final all = Topology.flatten(roots);
      // 后续校验同样不能 hangs
      final res = CoreCheck.check(roots);
      expect(all.length, lessThanOrEqualTo(2));
      expect(res, isNotNull);
    });

    test('自指不成环', () {
      final labels = <MapLabel>[
        _node('a', 'crossbox', '光交A', topoParentId: 'a'),
      ];
      final roots = Topology.buildTree(labels);
      expect(roots, hasLength(1));
      expect(roots.single.parent, isNull);
    });
  });

  group('空工程提示', () {
    test('空标签列表抛 TopoException（友好文案）', () {
      expect(
        () => Topology.buildTree([]),
        throwsA(isA<TopoException>().having(
          (e) => e.message,
          'message',
          contains('没有可成拓扑的节点'),
        )),
      );
    });

    test('只有非配线节点（如杆路点）同样提示', () {
      final labels = <MapLabel>[
        _node('p1', 'pole', '杆1'),
        _node('p2', 'pole', '杆2'),
      ];
      expect(() => Topology.buildTree(labels), throwsA(isA<TopoException>()));
    });
  });
}
