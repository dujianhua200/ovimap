import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/device_category.dart';
import 'package:ovimap/models/fiber_link.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/models/pole_segment.dart';
import 'package:ovimap/models/topo_check.dart';

void main() {
  group('FiberLink', () {
    test('JSON 往返', () {
      final l = FiberLink(
        fromDeviceId: 'a',
        toDeviceId: 'b',
        cores: 48,
        cableModel: 'GYTS',
        manufacturer: '长飞',
        layMethod: 1,
        lengthM: 125.5,
        spliceMethod: '熔接',
        note: '测试',
      );
      final r = FiberLink.fromJson(l.toJson());
      expect(r.fromDeviceId, 'a');
      expect(r.toDeviceId, 'b');
      expect(r.cores, 48);
      expect(r.cableModel, 'GYTS');
      expect(r.manufacturer, '长飞');
      expect(r.layMethod, 1);
      expect(r.lengthM, 125.5);
      expect(r.spliceMethod, '熔接');
      expect(r.id, l.id);
    });

    test('fullSpec 拼接', () {
      final l = FiberLink(cores: 48, cableModel: 'GYTS', layMethod: 1);
      expect(l.fullSpec, '48芯GYTS（架空）');
      expect(FiberLink().fullSpec, '');
    });

    test('clone 深拷贝', () {
      final l = FiberLink(fromDeviceId: 'a', cores: 24);
      final c = l.clone();
      expect(c.id, l.id);
      expect(c.cores, 24);
    });
  });

  group('DeviceCategory', () {
    test('模板库非空且前缀唯一', () {
      expect(kDeviceLibrary.isNotEmpty, true);
      final ids = kDeviceLibrary.map((c) => c.typeId).toSet();
      expect(ids.length, kDeviceLibrary.length);
    });

    test('findCategory', () {
      expect(findCategory('mcab')!.noPrefix, 'GX');
      expect(findCategory('notexist'), isNull);
    });

    test('nextDeviceNo 跳过已用', () {
      expect(nextDeviceNo('GX', {}), 'GX-01');
      expect(nextDeviceNo('GX', {'GX-01', 'GX-02'}), 'GX-03');
      expect(nextDeviceNo('FH', {'FH-01'}), 'FH-02');
    });
  });

  group('PoleSegment', () {
    test('JSON 往返', () {
      final p = PoleSegment(
        name: '杆路A-1段',
        pointIds: ['p1', 'p2', 'p3'],
        material: '水泥杆',
        layMethod: 1,
        buildYear: '2024',
      );
      final r = PoleSegment.fromJson(p.toJson());
      expect(r.name, '杆路A-1段');
      expect(r.pointIds, ['p1', 'p2', 'p3']);
      expect(r.material, '水泥杆');
      expect(r.buildYear, '2024');
      expect(r.id, p.id);
    });
  });

  group('validateTopology', () {
    MapLabel dev(String id, String name) =>
        MapLabel(id: id, name: name, typeId: 'mcab');

    test('空输入无问题', () {
      expect(validateTopology([], []), isEmpty);
    });

    test('孤立节点', () {
      final issues = validateTopology([dev('a', 'GX-01')], []);
      expect(issues.length, 1);
      expect(issues[0].kind, '孤立节点');
    });

    test('未命名', () {
      final issues = validateTopology([MapLabel(id: 'a')], []);
      expect(issues.any((i) => i.kind == '未命名'), true);
    });

    test('重复连线', () {
      final ds = [dev('a', 'A'), dev('b', 'B')];
      final ls = [
        FiberLink(fromDeviceId: 'a', toDeviceId: 'b'),
        FiberLink(fromDeviceId: 'b', toDeviceId: 'a'),
      ];
      final issues = validateTopology(ds, ls);
      expect(issues.any((i) => i.kind == '重复连线'), true);
    });

    test('自环', () {
      final ds = [dev('a', 'A')];
      final ls = [FiberLink(fromDeviceId: 'a', toDeviceId: 'a')];
      expect(validateTopology(ds, ls).any((i) => i.kind == '自环'), true);
    });

    test('无效端点', () {
      final ds = [dev('a', 'A')];
      final ls = [FiberLink(fromDeviceId: 'a', toDeviceId: 'zzz')];
      expect(validateTopology(ds, ls).any((i) => i.kind == '无效端点'), true);
    });

    test('芯数不一致', () {
      final ds = [dev('a', 'A'), dev('b', 'B'), dev('c', 'C')];
      final ls = [
        FiberLink(fromDeviceId: 'a', toDeviceId: 'b', cores: 48),
        FiberLink(fromDeviceId: 'a', toDeviceId: 'c', cores: 24),
      ];
      expect(validateTopology(ds, ls).any((i) => i.kind == '芯数不一致'), true);
    });

    test('正常拓扑无问题', () {
      final ds = [dev('a', 'GX-01'), dev('b', 'FH-01')];
      final ls = [
        FiberLink(fromDeviceId: 'a', toDeviceId: 'b', cores: 48)
      ];
      expect(validateTopology(ds, ls), isEmpty);
    });
  });
}
