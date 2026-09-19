// 左栏「本工程段落 / 点位表」护栏。
//
// 这一块是用户上轮反馈的直接落地：「左边也可以修改为中文加数字，比如说 42 改为 埋42」。
// 因此测试重点是**就地改段标真的写回去了**，而不只是"界面长得对"。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/sync/sync_controller.dart';
import 'package:ovimap/ui/desktop/left_panel.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState st;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    st = AppState();
    st.setPrefsForTest(await SharedPreferences.getInstance());
  });

  /// 造一条 4 点 3 段的链：段1架空、段2埋地、段3默认。
  /// 用 distanceM 固定段距，让断言不依赖 haversine 常量。
  void seed() {
    st.labels.addAll([
      MapLabel(typeId: 'pole', seq: 1, lat: 32.0, lon: 114.0, lineGroupId: 'g1',
          name: 'GK-1'),
      MapLabel(typeId: 'pole', seq: 2, lat: 32.001, lon: 114.0, lineGroupId: 'g1',
          name: 'GK-2', distanceM: 38, segKind: 1),
      MapLabel(typeId: 'pole', seq: 3, lat: 32.002, lon: 114.0, lineGroupId: 'g1',
          name: 'GK-3', distanceM: 42, segKind: 2),
      MapLabel(typeId: 'pole', seq: 4, lat: 32.003, lon: 114.0, lineGroupId: 'g1',
          name: 'GK-4', distanceM: 25),
    ]);
  }

  Future<void> mount(WidgetTester tester, {void Function(MapLabel)? onLocate}) async {
    await tester.pumpWidget(
      // `Provider<SyncController?>.value(null)`：左栏工程列表未用到的路径不会读它，
      // 但显式给一个空 provider 可以避免将来列表非空时测试意外挂掉。
      MultiProvider(
        providers: [Provider<SyncController?>.value(value: null)],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 260,
              height: 700,
              child: LeftPanel(
                st: st,
                onNewProject: () {},
                onLocate: onLocate,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('默认收起：只显示标题与点数/段数概览', (tester) async {
    seed();
    await mount(tester);
    expect(find.text('本工程'), findsOneWidget);
    expect(find.text('4 点 · 3 段'), findsOneWidget);
    // 收起态不应渲染段落行（避免挤占工程列表）。
    expect(find.textContaining('GK-1 → GK-2'), findsNothing);
  });

  testWidgets('展开后段落页显示 Σ(链长-1) 行，且段标实时带敷设方式前缀', (tester) async {
    seed();
    await mount(tester);
    await tester.tap(find.text('本工程'));
    await tester.pumpAndSettle();

    expect(find.text('段落 3'), findsOneWidget);
    expect(find.text('点位 4'), findsOneWidget);
    expect(find.text('GK-1 → GK-2'), findsOneWidget);
    expect(find.text('GK-3 → GK-4'), findsOneWidget);

    // 核心：没手填标注的段，左栏直接显示「前缀 + 距离」（不是裸数字）。
    expect(find.text('架38'), findsOneWidget); // 段1 架空
    expect(find.text('埋42'), findsOneWidget); // 段2 埋地
    expect(find.text('25'), findsOneWidget);   // 段3 默认：无前缀则只显示距离
  });

  testWidgets('就地改段标：点开输入框 → 输入 → 写回 distLabel 并保留前缀语义', (tester) async {
    seed();
    await mount(tester);
    await tester.tap(find.text('本工程'));
    await tester.pumpAndSettle();

    // 点「架38」进入编辑。
    await tester.tap(find.text('架38'));
    await tester.pumpAndSettle();
    // 用 Key 精确命中「段标输入框」——左栏顶部还有工程搜索框，不能按类型找。
    expect(find.byKey(kSegLabelEditorKey), findsOneWidget);

    // 模拟用户改成「架38.5（现场复测）」。
    await tester.enterText(find.byKey(kSegLabelEditorKey), '架38.5');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(st.labels[1].distLabel, '架38.5');
    expect(find.text('架38.5'), findsOneWidget);
  });

  testWidgets('前缀快捷键：点「埋」把本段实测距离自动补进输入框（42 → 埋42）',
      (tester) async {
    seed();
    await mount(tester);
    await tester.tap(find.text('本工程'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('架38'));
    await tester.pumpAndSettle();

    // 清空后用「埋」一键补距：这正是用户说的「42 改为 埋42」那一步。
    await tester.enterText(find.byKey(kSegLabelEditorKey), '');
    await tester.tap(find.text('埋'));
    await tester.pumpAndSettle();

    // 关键：点 chip 不能把编辑框关掉（否则下方断言会因找不到输入框而失败）。
    expect(find.byKey(kSegLabelEditorKey), findsOneWidget,
        reason: 'chip 属于输入框同组区域，点击不应触发 onTapOutside 提交');
    final tf = tester.widget<TextField>(find.byKey(kSegLabelEditorKey));
    expect(tf.controller!.text, '埋38', reason: '无数字时应补本段实测距离');

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(st.labels[1].distLabel, '埋38');
  });

  testWidgets('清除：段标回到「敷设方式 + 实测距离」实时生成，而不是留空', (tester) async {
    seed();
    await mount(tester);
    await tester.tap(find.text('本工程'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('架38'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(st.labels[1].distLabel, '');
    // 清除后显示的仍是自动推导结果（架空 + 38），证明"清手填 ≠ 图上没标注"。
    expect(find.text('架38'), findsOneWidget);
  });

  testWidgets('点位页列出全部点，点击行把该点交给壳去定位', (tester) async {
    seed();
    final located = <MapLabel>[];
    await mount(tester, onLocate: located.add);
    await tester.tap(find.text('本工程'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('点位 4'));
    await tester.pumpAndSettle();
    expect(find.text('GK-3'), findsOneWidget);

    await tester.tap(find.text('GK-3'));
    await tester.pumpAndSettle();
    expect(located.length, 1);
    expect(located.first.name, 'GK-3');
  });

  testWidgets('无点工程：展开后给出可行动的提示，而不是空白', (tester) async {
    await mount(tester);
    await tester.tap(find.text('本工程'));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有点'), findsOneWidget);
  });
}
