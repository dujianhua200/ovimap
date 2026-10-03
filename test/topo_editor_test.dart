/// Phase 2 拓扑图编辑器测试：布局纯函数 + 页面交互。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/fiber_link.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/ui/topo_editor.dart';

MapLabel _dev(String id, String typeId, String name, double lat, double lon) =>
    MapLabel(id: id, typeId: typeId, name: name, lat: lat, lon: lon);

void main() {
  group('layoutTopoNodes', () {
    test('空列表返回空', () {
      expect(layoutTopoNodes([], const Size(800, 600)), isEmpty);
    });

    test('经纬度归一化：保持相对位置', () {
      final ds = [
        _dev('a', 'crossbox', 'GX-01', 32.0, 114.0),
        _dev('b', 'fiberbox', 'FH-01', 32.1, 114.2),
      ];
      final pos = layoutTopoNodes(ds, const Size(800, 600));
      expect(pos.length, 2);
      // b 在东北方向 → 屏幕上应在右上方
      expect(pos['b']!.dx, greaterThan(pos['a']!.dx));
      expect(pos['b']!.dy, lessThan(pos['a']!.dy));
      // 都在画布内
      for (final o in pos.values) {
        expect(o.dx, inInclusiveRange(0.0, 800.0));
        expect(o.dy, inInclusiveRange(0.0, 600.0));
      }
    });

    test('全部重合时退化为网格', () {
      final ds = [
        _dev('a', 'crossbox', 'GX-01', 32.0, 114.0),
        _dev('b', 'fiberbox', 'FH-01', 32.0, 114.0),
        _dev('c', 'room', 'OLT-01', 32.0, 114.0),
      ];
      final pos = layoutTopoNodes(ds, const Size(800, 600));
      expect(pos.length, 3);
      // 网格点互不重合
      final pts = pos.values.toList();
      expect(pts[0] == pts[1], false);
      expect(pts[1] == pts[2], false);
    });
  });

  group('topoLinkableDevices', () {
    test('只保留可连线类型', () {
      final ds = [
        _dev('a', 'crossbox', 'GX-01', 32.0, 114.0),
        _dev('b', 'text', '', 32.0, 114.0),
        _dev('c', 'pole', 'G-01', 32.0, 114.0),
      ];
      final r = topoLinkableDevices(ds);
      expect(r.map((e) => e.id), ['a']);
    });
  });

  group('pointToSegment', () {
    test('中点距离', () {
      expect(
        pointToSegment(const Offset(5, 3), const Offset(0, 0), const Offset(10, 0)),
        closeTo(3.0, 1e-9),
      );
    });
    test('端点外', () {
      expect(
        pointToSegment(const Offset(-4, 0), const Offset(0, 0), const Offset(10, 0)),
        closeTo(4.0, 1e-9),
      );
    });
  });

  group('TopoEditorPage widget', () {
    late List<MapLabel> devices;

    setUp(() {
      devices = [
        _dev('dev-a', 'crossbox', 'GX-01', 32.0, 114.0),
        _dev('dev-b', 'fiberbox', 'FH-01', 32.001, 114.001),
      ];
    });

    /// 取画布内某设备的全局坐标（与页面布局函数一致）。
    Offset nodeGlobal(WidgetTester tester, String id) {
      final paint = tester
          .element(find.byKey(const ValueKey('topo_canvas')))
          .renderObject as RenderBox;
      final size = paint.size;
      final pos = layoutTopoNodes(topoLinkableDevices(devices), size);
      return paint.localToGlobal(pos[id]!);
    }

    testWidgets('渲染节点并点选两设备弹出表单', (tester) async {
      List<FiberLink>? changed;
      await tester.pumpWidget(MaterialApp(
        home: TopoEditorPage(
          devices: devices,
          onChanged: (l) => changed = l,
        ),
      ));
      await tester.pumpAndSettle();

      // 点选起点、终点
      await tester.tapAt(nodeGlobal(tester, 'dev-a'));
      await tester.pump();
      await tester.tapAt(nodeGlobal(tester, 'dev-b'));
      await tester.pumpAndSettle();

      // 参数表单弹出
      expect(find.text('GX-01 → FH-01'), findsOneWidget);
      expect(find.text('保存连线'), findsOneWidget);

      // 直接保存（默认 48芯/GYTS/架空/熔接）
      await tester.tap(find.text('保存连线'));
      await tester.pumpAndSettle();

      expect(changed, isNotNull);
      expect(changed!.length, 1);
      final l = changed!.first;
      expect(l.fromDeviceId, 'dev-a');
      expect(l.toDeviceId, 'dev-b');
      expect(l.cores, 48);
      expect(l.cableModel, 'GYTS');
      expect(l.layMethod, 1);
      expect(l.spliceMethod, '熔接');
    });

    testWidgets('芯数可切换自定义', (tester) async {
      List<FiberLink>? changed;
      await tester.pumpWidget(MaterialApp(
        home: TopoEditorPage(
          devices: devices,
          onChanged: (l) => changed = l,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tapAt(nodeGlobal(tester, 'dev-a'));
      await tester.pump();
      await tester.tapAt(nodeGlobal(tester, 'dev-b'));
      await tester.pumpAndSettle();

      // 切换到自定义芯数
      await tester.tap(find.text('自定义'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '288');
      await tester.tap(find.text('保存连线'));
      await tester.pumpAndSettle();

      expect(changed!.first.cores, 288);
    });

    testWidgets('一键校验显示孤立节点', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: TopoEditorPage(devices: devices),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('一键校验'));
      await tester.pumpAndSettle();

      expect(find.text('孤立节点'), findsWidgets);
    });

    testWidgets('已有连线传入并显示', (tester) async {
      final links = [
        FiberLink(fromDeviceId: 'dev-a', toDeviceId: 'dev-b', cores: 24),
      ];
      await tester.pumpWidget(MaterialApp(
        home: TopoEditorPage(devices: devices, initialLinks: links),
      ));
      await tester.pumpAndSettle();

      // 校验应无孤立节点（两设备已连线），但有未命名？设备都有名 → 通过
      await tester.tap(find.byTooltip('一键校验'));
      await tester.pumpAndSettle();
      expect(find.text('未发现问题'), findsOneWidget);
    });

    testWidgets('无设备时显示占位', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: TopoEditorPage(devices: []),
      ));
      await tester.pumpAndSettle();
      expect(find.text('暂无可连线设备，请先在路由图添加设备'), findsOneWidget);
    });
  });

  group('FiberLinkFormDialog', () {
    testWidgets('取消不产生连线', (tester) async {
      var saved = false;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              final r = await showDialog<FiberLink>(
                context: ctx,
                builder: (_) => FiberLinkFormDialog(
                  from: _dev('a', 'crossbox', 'GX-01', 32, 114),
                  to: _dev('b', 'fiberbox', 'FH-01', 32, 114),
                ),
              );
              saved = r != null;
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(saved, false);
    });
  });
}
