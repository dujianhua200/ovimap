/// Phase 4 设备模板库测试：模板创建、智能编号、批量改号、选择器。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/device_category.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/ui/device_library.dart';

void main() {
  group('createDeviceFromTemplate', () {
    test('按前缀自动编号', () {
      final cat = findCategory('mcab')!;
      final l = createDeviceFromTemplate(
          category: cat, lat: 32.0, lon: 114.0);
      expect(l.name, 'GX-01');
      expect(l.typeId, 'crossbox'); // 映射到 LabelType
      expect(l.lat, 32.0);
      expect(l.extra!['deviceCategory'], 'mcab');
    });

    test('编号避开已有', () {
      final cat = findCategory('mcab')!;
      final existing = [
        MapLabel(typeId: 'crossbox', name: 'GX-01'),
        MapLabel(typeId: 'crossbox', name: 'GX-02'),
      ];
      final l = createDeviceFromTemplate(
          category: cat, lat: 32.0, lon: 114.0, existing: existing);
      expect(l.name, 'GX-03');
    });

    test('自定义名称优先', () {
      final cat = findCategory('pole')!;
      final l = createDeviceFromTemplate(
          category: cat, lat: 32.0, lon: 114.0, customName: '  G-99 ');
      expect(l.name, 'G-99');
      expect(l.typeId, 'concrete');
    });

    test('13 类模板全部可映射', () {
      for (final c in kDeviceLibrary) {
        expect(kCategoryToLabelType.containsKey(c.typeId), true,
            reason: c.typeId);
        final l = createDeviceFromTemplate(
            category: c, lat: 32.0, lon: 114.0);
        // typeId 必须在 LabelType 中可解析（不回退为 pipe 才算映射成功，
        // pipe 本身也是合法值，这里只保证不抛异常且有分类记录）
        expect(l.extra!['deviceCategory'], c.typeId);
      }
    });
  });

  group('deviceNoPrefix', () {
    test('从 extra 取原始分类前缀', () {
      final cat = findCategory('fdcab')!;
      final l = createDeviceFromTemplate(
          category: cat, lat: 32.0, lon: 114.0);
      expect(deviceNoPrefix(l), 'FH');
    });

    test('无 extra 时回退', () {
      final l = MapLabel(typeId: 'pipe', name: 'x');
      expect(deviceNoPrefix(l), isNotEmpty);
    });
  });

  group('renumberDevices', () {
    test('按类型重新编号并避开未选中', () {
      final mcab = findCategory('mcab')!;
      final fdcab = findCategory('fdcab')!;
      final a = createDeviceFromTemplate(
          category: mcab, lat: 32, lon: 114, customName: '老名字A');
      final b = createDeviceFromTemplate(
          category: mcab, lat: 32, lon: 114, customName: '老名字B');
      final c = createDeviceFromTemplate(
          category: fdcab, lat: 32, lon: 114, customName: '老名字C');
      final keep = MapLabel(
          id: 'keep-1', typeId: 'crossbox', name: 'GX-01'); // 未选中，占位
      final all = [a, b, c, keep];

      renumberDevices(all, {a.id, b.id, c.id});

      // GX-01 被占用 → a/b 从 GX-02 起；c 为 FH-01
      final names = {a.name, b.name, c.name};
      expect(names, {'GX-02', 'GX-03', 'FH-01'});
      expect(keep.name, 'GX-01'); // 未选中不受影响
    });

    test('空选择不做任何事', () {
      final l = MapLabel(typeId: 'crossbox', name: 'KEEP');
      renumberDevices([l], {});
      expect(l.name, 'KEEP');
    });
  });

  group('showDeviceTemplatePicker widget', () {
    testWidgets('选择模板返回分类', (tester) async {
      DeviceCategory? picked;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              picked = await showDeviceTemplatePicker(ctx);
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('选择设备模板'), findsOneWidget);
      // 首行模板可见可点
      expect(find.byKey(const ValueKey('tpl_olt')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tpl_olt')));
      await tester.pumpAndSettle();

      expect(picked, isNotNull);
      expect(picked!.typeId, 'olt');
      expect(picked!.name, 'OLT机房');
    });
  });

  group('showBatchRenumberConfirm widget', () {
    testWidgets('确认返回 true', (tester) async {
      var result = false;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              result = await showBatchRenumberConfirm(ctx, 3);
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新编号'));
      await tester.pumpAndSettle();
      expect(result, true);
    });
  });
}
