// 两段式点选状态机（resolveTapAction）+ 快速编辑小框 widget test：
// 改距离 → 点「架」chip → 本段标注变「架50」→ 保存写回 label；
// 盘留 / 敷设方式 / 样式覆盖一并写回。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/ui/label_marker.dart';
import 'package:ovimap/ui/label_quick_edit.dart';
import 'package:ovimap/ui/map/map_canvas.dart';

void main() {
  group('resolveTapAction 状态机', () {
    test('点空地 → clear（无论此前选中谁）', () {
      expect(resolveTapAction(null, null), LabelTapAction.clear);
      expect(resolveTapAction('a', null), LabelTapAction.clear);
      expect(resolveTapAction('cid:a', null), LabelTapAction.clear);
    });

    test('首次点中 → select', () {
      expect(resolveTapAction(null, 'a'), LabelTapAction.select);
    });

    test('换一个点 → select（重置为新点）', () {
      expect(resolveTapAction('a', 'b'), LabelTapAction.select);
      // 草稿点 id 与叠加点 cid:id 不撞键
      expect(resolveTapAction('a', 'cid:a'), LabelTapAction.select);
    });

    test('再点同一点 → popup', () {
      expect(resolveTapAction('a', 'a'), LabelTapAction.popup);
      expect(resolveTapAction('cid:a', 'cid:a'), LabelTapAction.popup);
    });

    test('labelHitKey：草稿裸 id，叠加点带 cid 前缀', () {
      final l = MapLabel(typeId: 'pipe');
      expect(labelHitKey(l, ''), l.id);
      expect(labelHitKey(l, 'c9'), 'c9:${l.id}');
    });
  });

  group('showLabelQuickEdit 小框', () {
    late Directory dir;
    late AppState st;
    late MapLabel l1;
    late MapLabel l2;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ovimap_quickedit');
      LabelStore.instance.setBaseDirForTest(dir);
      st = AppState();
      l1 = MapLabel(
        typeId: 'concrete',
        seq: 1,
        lat: 32.0,
        lon: 114.0,
        lineGroupId: 'g1',
        name: '杆1',
      );
      l2 = MapLabel(
        typeId: 'concrete',
        seq: 2,
        lat: 32.0,
        lon: 114.001,
        lineGroupId: 'g1',
        name: '杆2',
      );
      st.labels.addAll([l1, l2]);
    });

    tearDown(() {
      AppPaths.clearForTest();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Finder fieldByHint(String part) => find.byWidgetPredicate(
      (w) => w is TextField && (w.decoration?.hintText ?? '').contains(part),
    );

    Future<void> openQuickEdit(WidgetTester tester, MapLabel target) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () => showLabelQuickEdit(ctx, st, target),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('改距离50 → 点「架」→ 标注=架50 → 保存写回距离/盘留/敷设方式', (tester) async {
      await openQuickEdit(tester, l2);

      // 段信息组出现（l2 有上一链点 l1）。
      expect(fieldByHint('到上一点距离'), findsOneWidget);
      expect(fieldByHint('本段标注'), findsOneWidget);

      // 改距离为 50。
      await tester.enterText(fieldByHint('到上一点距离'), '50');
      await tester.pump();

      // 点「架」chip → 标注自动变成「架50」（数字取距离框现值）。
      await tester.ensureVisible(find.text('架'));
      await tester.tap(find.text('架'));
      await tester.pump();
      final segField = tester.widget<TextField>(fieldByHint('本段标注'));
      expect(segField.controller!.text, '架50');

      // 盘留 5 米、敷设方式选「架空」。
      await tester.ensureVisible(fieldByHint('盘留'));
      await tester.enterText(fieldByHint('盘留'), '5');
      await tester.ensureVisible(find.text('架空'));
      await tester.tap(find.text('架空'));
      await tester.pump();

      // 保存写回。
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(l2.distanceM, 50);
      expect(l2.distLabel, '架50');
      expect(l2.slackM, 5);
      expect(l2.segKind, 1);
    });

    testWidgets('样式选择器：选圆点+红 → 确定 → 保存写回样式覆盖', (tester) async {
      await openQuickEdit(tester, l1);

      await tester.tap(find.text('样式…'));
      await tester.pumpAndSettle();
      expect(find.text('标签样式'), findsOneWidget);

      // 网格中 (dot, 电力杆红) 的样例符号唯一，点其色格。
      final cellSymbol = find.byWidgetPredicate(
        (w) =>
            w is LabelSymbol &&
            w.label.symShape == 'dot' &&
            w.label.symColor == 0xFFE53935,
      );
      expect(cellSymbol, findsOneWidget);
      await tester.ensureVisible(cellSymbol);
      await tester.pump();
      await tester.tap(
        find.ancestor(of: cellSymbol, matching: find.byType(GestureDetector)),
      );
      await tester.pump();

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('标签样式'), findsNothing);

      // 回到小框后保存，覆盖写回 label。
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(l1.symShape, 'dot');
      expect(l1.symColor, 0xFFE53935);
      expect(l1.symText, '');
    });
  });
}
