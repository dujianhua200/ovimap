import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/fav_node.dart';
import '../../state/app_state.dart';
import '../../state/fav_tree_controller.dart';
import '../design_tokens.dart';
import '../dialogs.dart';

/// 收藏树共享小动作（桌面/移动共用）：输入框、确认框、显隐联动、文件夹选择器、
/// 样式选择器、首帧可见性对齐。
///
/// 约束：点位真相源只走 [FavTreeController]，不碰 `AppState.overlayLabels`。

/// 单行文本输入框。返回 null = 取消/空输入。
Future<String?> askText(BuildContext context,
    {required String title, String initial = '', String hint = '名称'}) async {
  final ctl = TextEditingController(text: initial);
  var done = false;
  String? result;
  void submit() {
    if (done) return;
    done = true;
    result = ctl.text.trim();
    Navigator.pop(context);
  }

  await showDarkDialog(
    context,
    title: title,
    content: TextField(
      controller: ctl,
      autofocus: true,
      onSubmitted: (_) => submit(),
      style: const TextStyle(color: kTextMain),
      decoration: dec(hint),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('确定', submit, color: kGreen),
    ],
  );
  ctl.dispose();
  if (result == null || result!.isEmpty) return null;
  return result;
}

/// 危险操作确认框。返回 true = 用户点了确认按钮。
Future<bool> askConfirm(BuildContext context,
    {required String title,
    required String content,
    String okText = '确定',
    Color okColor = kDanger}) async {
  var ok = false;
  await showDarkDialog(
    context,
    title: title,
    content: Text(content,
        style: const TextStyle(color: kTextMain, fontSize: TokFs.body)),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn(okText, () {
        ok = true;
        Navigator.pop(context);
      }, color: okColor),
    ],
  );
  return ok;
}

/// 设置节点可见性（审计问题 2：树显隐与地图显隐联动，但互不绑死）。
///
/// ① `await c.setVisible(id, visible)`（树状态；project 会落盘 `visible` 字段）；
/// ② 地图联动：
/// - project → 按 `AppState.visibleCids` 差值调 `st.toggleVisible(cid)`
///  （只在状态不一致时调，避免重复 toggle）；
/// - folder → 递归其下所有 project 做同样的差值联动；
/// - mark → D2：树 hiddenIds 照旧，另联动 `st.hiddenLabelIds`
///  （地图渲染/点选跳过，polyline 保持连续不断）。
Future<void> setNodeVisible(BuildContext context, FavTreeController c,
    FavNode node, bool visible) async {
  final st = Provider.of<AppState>(context, listen: false);
  await c.setVisible(node.id, visible);
  Future<void> syncProject(String cid) async {
    final mapVisible = st.visibleCids.contains(cid);
    if (mapVisible != visible) st.toggleVisible(cid);
  }

  if (node.isProject) {
    await syncProject(node.id);
  } else if (node.isFolder) {
    for (final cid in c.projectCidsUnder(node.id)) {
      await syncProject(cid);
    }
  } else if (node.isMark && node.label != null) {
    // D2：mark 级地图显隐——树照旧，另联动 hiddenLabelIds + prefs + notify。
    st.setLabelHidden(node.label!.id, !visible);
  }
}

/// 首帧可见性对齐：以 `st.visibleCids`（地图真相）为准对齐 `c.hiddenIds`。
///
/// 只改内存、不落盘（不能调 `c.setVisible`，它会写 index.json）。
Future<void> syncInitialVisibility(
    FavTreeController c, AppState st) async {
  await c.ready;
  for (final p in c.projects) {
    if (st.visibleCids.contains(p.id)) {
      c.hiddenIds.remove(p.id);
    } else {
      c.hiddenIds.add(p.id);
    }
  }
  c.notifyTreeChanged();
}

/// 文件夹选择器（移动到… / 合并目标等共用）。
///
/// 返回目标文件夹 id（'' = 根）；null = 用户取消。[excludeSubtree] 指定的
/// 文件夹及其子树不出现在候选中（防成环）。
Future<String?> pickFavFolder(BuildContext context, FavTreeController c,
    {String title = '选择文件夹',
    String excludeSubtree = '',
    String initial = ''}) async {
  bool isExcluded(String fid) {
    if (excludeSubtree.isEmpty) return false;
    if (fid == excludeSubtree) return true;
    var p = c.find(fid)?.pid ?? '';
    final seen = <String>{};
    while (p.isNotEmpty && seen.add(p)) {
      if (p == excludeSubtree) return true;
      p = c.find(p)?.pid ?? '';
    }
    return false;
  }

  int depthOf(FavNode f) {
    var d = 0;
    var p = f.pid;
    final seen = <String>{};
    while (p.isNotEmpty && seen.add(p)) {
      final n = c.find(p);
      if (n == null || !n.isFolder) break;
      p = n.pid;
      d++;
    }
    return d;
  }

  final folders =
      c.folders.where((f) => !isExcluded(f.id)).toList();
  var target = initial;
  // 初始值若被排除，回退到根。
  if (target.isNotEmpty && isExcluded(target)) target = '';
  var picked = false;
  await showDarkDialog(
    context,
    title: title,
    content: StatefulBuilder(
      builder: (ctx, setSt) => DropdownButtonFormField<String>(
        initialValue: target,
        dropdownColor: TokC.panelSolid,
        isExpanded: true,
        style: const TextStyle(color: kTextMain, fontSize: TokFs.body),
        decoration: dec('移动到…'),
        items: [
          const DropdownMenuItem(value: '', child: Text('根目录（收藏夹）')),
          for (final f in folders)
            DropdownMenuItem(
                value: f.id,
                child: Text('${'　' * depthOf(f)}${f.name}')),
        ],
        onChanged: (v) => setSt(() => target = v ?? ''),
      ),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('确定', () {
        picked = true;
        Navigator.pop(context);
      }, color: kGreen),
    ],
  );
  return picked ? target : null;
}

/// 工程样式选择器：返回 (color ARGB, width dp)；null = 取消。
Future<(int, double)?> pickProjectStyle(BuildContext context,
    {int initialColor = 0, double initialWidth = 3.0}) async {
  const presets = <int>[
    0xFFE53935, // 红
    0xFFFB8C00, // 橙
    0xFFFFD54F, // 黄
    0xFF43A047, // 绿
    0xFF039BE5, // 蓝
    0xFF5E35B1, // 紫
    0xFF546E7A, // 灰
    0xFF1C242C, // 黑
  ];
  var color = initialColor;
  var width = initialWidth.clamp(1.0, 12.0);
  var picked = false;
  await showDarkDialog(
    context,
    title: '改样式',
    content: StatefulBuilder(
      builder: (ctx, setSt) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('颜色', style: TextStyle(color: kTextSub, fontSize: TokFs.caption)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in presets)
                GestureDetector(
                  onTap: () => setSt(() => color = p),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Color(p),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: color == p ? kAccent : Colors.transparent,
                          width: 2.5),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text('线宽 ${width.toStringAsFixed(1)} dp',
              style: const TextStyle(color: kTextSub, fontSize: TokFs.caption)),
          Slider(
            value: width,
            min: 1,
            max: 12,
            divisions: 22,
            onChanged: (v) => setSt(() => width = v),
          ),
        ],
      ),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('应用', () {
        picked = true;
        Navigator.pop(context);
      }, color: kGreen),
    ],
  );
  return picked ? (color, width) : null;
}
