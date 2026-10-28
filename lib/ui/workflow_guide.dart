import 'dart:async';

import 'package:flutter/material.dart';

import '../models/map_label.dart';
import '../state/app_state.dart';
import 'design_tokens.dart';
import 'dialogs.dart';
import 'route_tools.dart';

/// 作业流程引导：把一天的主线动作排成 5 步，点哪步做哪步。
///
/// 实机走查发现：工具栏/菜单里功能很多，但新用户（以及忙起来的老用户）
/// 常在「新建 → 打点 → 布杆 → 体检 → 导出」之间找入口。这里不新增业务逻辑，
/// 只把既有动作串成一条看得见的流程。
Future<void> showWorkflowGuide(
  BuildContext context,
  AppState st, {
  required VoidCallback onNewProject,
  required VoidCallback onInspect,
  required VoidCallback onExport,
}) async {
  final chains = buildLabelChains(st.labels);
  final points = st.labels.length;
  final project = st.projectName.trim().isEmpty
      ? '未命名工程'
      : st.projectName.trim();

  Widget step({
    required String no,
    required String title,
    required String subtitle,
    required String action,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: enabled ? kAccent : TokC.divider,
        child: Text(
          no,
          style: const TextStyle(
            color: Colors.white,
            fontSize: TokFs.caption,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(
        title,
        style: const TextStyle(color: kTextMain, fontSize: TokFs.body),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: kTextSub, fontSize: TokFs.caption),
      ),
      trailing: TextButton(
        onPressed: enabled ? onTap : null,
        child: Text(action),
      ),
    );
  }

  await showDarkDialog(
    context,
    title: '作业流程（按顺序做）',
    width: 560,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '当前：$project · $points 点 · ${chains.length} 条线组',
          style: const TextStyle(color: kTextSub, fontSize: TokFs.caption),
        ),
        const SizedBox(height: TokSp.s),
        step(
          no: '1',
          title: '新建工程',
          subtitle: '名称、场景模板、自动编号一次设好',
          action: '新建',
          onTap: () {
            Navigator.pop(context);
            onNewProject();
          },
        ),
        step(
          no: '2',
          title: '打点',
          subtitle: points == 0 ? '沿线路连续落点，软件自动编号并连线' : '已落 $points 点',
          action: '开始',
          onTap: () {
            Navigator.pop(context);
            st.setMode(AppMode.edit);
            toast(context, '打点模式：左键连续落点，Esc 结束');
          },
        ),
        step(
          no: '3',
          title: '自动布杆',
          subtitle: chains.isEmpty
              ? '先画一条线组（打点会自动连线），再等距布杆'
              : '沿最近一条线组等距布杆，不切角',
          action: '布杆',
          enabled: chains.isNotEmpty,
          onTap: () {
            Navigator.pop(context);
            unawaited(showAutoPoleDialog(context, st));
          },
        ),
        step(
          no: '4',
          title: '出图体检',
          subtitle: points == 0 ? '打点后可查段距/敷设方式/编号/标注' : '出图前先查一遍，减少返工',
          action: '体检',
          enabled: points > 0,
          onTap: () {
            Navigator.pop(context);
            onInspect();
          },
        ),
        step(
          no: '5',
          title: '导出成果',
          subtitle: 'DXF 路由图 / 配线图 / CSV / KML',
          action: '导出',
          enabled: points > 0,
          onTap: () {
            Navigator.pop(context);
            onExport();
          },
        ),
      ],
    ),
    actions: [darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub)],
  );
}
