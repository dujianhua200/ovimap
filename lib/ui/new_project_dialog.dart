import 'package:flutter/material.dart';

import '../models/project_template.dart';
import '../state/app_state.dart';
import 'design_tokens.dart';
import 'dialogs.dart';
import 'unsaved_draft_guard.dart';

/// 新建工程引导（桌面 / 移动共用）。
///
/// 把「名称 + 场景模板 + 自动编号」收在一次确认里。原来三件事分散在
/// 「新建工程 / 工程模板 / 采集设置」三个菜单，新建时还不问名称，
/// 用户常常打了一半才发现模板和编号前缀不对。
///
/// 返回 true：已创建并进入打点；false：取消，当前工程不受影响。
Future<bool> showNewProjectDialog(BuildContext context, AppState st) async {
  // 新建会清空当前草稿；有未保存点位时先让用户决定保存/放弃。
  if (!await confirmReplaceUnsavedDraft(context, st)) return false;
  final defaultTpl = ProjectTemplate.byId(st.templateId);
  var tplId = defaultTpl?.id ?? '';
  final nameCtl = TextEditingController(text: defaultProjectName());
  var autoNum = true;
  var prefixTouched = false;
  final prefixCtl = TextEditingController(text: defaultPrefixFor(tplId));
  var created = false;

  final screenW = MediaQuery.of(context).size.width;
  await showDarkDialog(
    context,
    title: '新建工程',
    width: screenW >= 560 ? 430 : null,
    content: StatefulBuilder(
      builder: (ctx, setSt) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameCtl,
              autofocus: true,
              style: const TextStyle(color: kTextMain, fontSize: 14),
              decoration: dec('工程名称（如：李庄架空光缆改造）'),
            ),
            const SizedBox(height: TokSp.s),
            const Text('场景模板',
                style: TextStyle(color: kTextSub, fontSize: TokFs.caption)),
            for (final t in <ProjectTemplate?>[null, ...ProjectTemplate.presets])
              RadioListTile<String>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: t?.id ?? '',
                groupValue: tplId,
                activeColor: kAccent,
                title: Text(t?.name ?? '空白工程',
                    style:
                        const TextStyle(color: kTextMain, fontSize: TokFs.body)),
                subtitle: Text(_templateHint(t),
                    style: const TextStyle(
                        color: kTextSub, fontSize: TokFs.caption)),
                onChanged: (v) {
                  setSt(() {
                    tplId = v ?? '';
                    // 只有用户没手动改过前缀时才跟随模板，避免覆盖自定义值。
                    if (!prefixTouched) prefixCtl.text = defaultPrefixFor(tplId);
                  });
                },
              ),
            const Divider(height: 16),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('自动编号（落点命名 前缀-1、前缀-2…）',
                  style: TextStyle(color: kTextMain, fontSize: TokFs.body)),
              value: autoNum,
              activeColor: kAccent,
              onChanged: (v) => setSt(() => autoNum = v ?? false),
            ),
            TextField(
              controller: prefixCtl,
              enabled: autoNum,
              onChanged: (_) => prefixTouched = true,
              style: const TextStyle(color: kTextMain, fontSize: 14),
              decoration: dec('编号前缀（如 G / R / X）'),
            ),
            const SizedBox(height: TokSp.s),
            const Text('创建后直接进入打点模式，编号从 1 开始；工程在第一次保存时落盘。',
                style: TextStyle(color: kTextHint, fontSize: TokFs.caption)),
          ],
        ),
      ),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('开始打点', () {
        final name = nameCtl.text.trim();
        if (name.isEmpty) {
          toast(context, '请先填写工程名称');
          return;
        }
        st.beginNewProject(
          name: name,
          template: ProjectTemplate.byId(tplId),
          autoNumber: autoNum,
          prefix: prefixCtl.text,
        );
        created = true;
        Navigator.pop(context);
      }, color: kGreen),
    ],
  );

  nameCtl.dispose();
  prefixCtl.dispose();
  return created;
}

/// 默认工程名：带日期，避免连续新建时全部叫「新建工程」。
String defaultProjectName([DateTime? now]) {
  final d = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '新建工程 ${d.year}-${two(d.month)}-${two(d.day)}';
}

/// 模板对应的默认编号前缀（空白工程沿用采集设置里的 GK）。
String defaultPrefixFor(String templateId) {
  switch (templateId) {
    case 'aerial':
      return 'G';
    case 'duct':
      return 'R';
    case 'box':
      return 'X';
    default:
      return 'GK';
  }
}

String _templateHint(ProjectTemplate? t) {
  if (t == null) return '沿用当前符号与敷设方式';
  switch (t.id) {
    case 'aerial':
      return '默认水泥杆 · 架空 · 编号 G-1、G-2…';
    case 'duct':
      return '默认管道口 · 管道 · 编号 R-1、R-2…';
    case 'box':
      return '默认分纤盒 · 箱体配线 · 编号 X-1、X-2…';
    default:
      return '默认 ${t.name}';
  }
}
