import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/fav_node.dart';
import '../../models/map_label.dart';
import '../../state/app_state.dart';
import '../../state/fav_tree_controller.dart';
import '../design_tokens.dart';
import '../dialogs.dart';
import 'trash.dart';

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

/// 批量删除标记并合并为**一条**撤销记录「删除 N 个标记」。
///
/// 外层 `undoStack.execute` 包裹循环：do/undo/redo 期间栈挂起，
/// [AppState.removeOverlayLabel] 内层的 execute 只执行本体、不记栈，
/// N 个点只留下这一条（W1 遗留：原先 N 个点 = N 条）。
/// undo 按原 index 升序插回，还原相对顺序；do 没删掉的不回插。
/// 返回 (deleted, skipped)：skipped = 所在工程未打开（`overlayLabels`
/// 无该 cid，单点删除同样删不动），调用方据此给失败原因（B2）。
Future<({int deleted, int skipped})> deleteMarksBatch(
    AppState st, List<(String, MapLabel)> marks) async {
  // do 前快照：undo 需要 label + 原 index（同 removeOverlayLabel 口径）。
  final snaps = <({String cid, MapLabel label, int index})>[];
  var skipped = 0;
  for (final (cid, label) in marks) {
    final list = st.overlayLabels[cid];
    if (list == null) {
      skipped++;
      continue;
    }
    final i = list.indexWhere((e) => e.id == label.id);
    if (i < 0) {
      skipped++;
      continue;
    }
    snaps.add((cid: cid, label: label, index: i));
  }
  if (snaps.isEmpty) return (deleted: 0, skipped: skipped);
  final deleted = <String>{};
  await st.undoStack.execute(
    '删除 ${snaps.length} 个标记',
    () async {
      for (final s in snaps) {
        final cur = st.overlayLabels[s.cid];
        if (cur == null) continue;
        // suspend 下内层 execute 只执行不记录（见 UndoStack 文档）。
        await st.removeOverlayLabel(s.cid, s.label);
        if (cur.every((e) => e.id != s.label.id)) deleted.add(s.label.id);
      }
      return deleted.isNotEmpty;
    },
    () async {
      // 按原 index 升序插回：先插回的低位标记占据 0..i-1，
      // 后插的按原 index 落位即还原相对顺序。
      final ordered = List.of(snaps)
        ..sort((a, b) => a.index.compareTo(b.index));
      for (final s in ordered) {
        if (!deleted.contains(s.label.id)) continue;
        final cur =
            st.overlayLabels[s.cid] ?? await st.store.loadCollection(s.cid);
        if (cur.any((e) => e.id == s.label.id)) continue; // 幂等
        cur.insert(s.index.clamp(0, cur.length), s.label);
        await st.store.saveCollectionLabels(s.cid, cur);
        await st.store.setCollectionCount(s.cid, cur.length);
      }
      st.refreshUi();
      return true;
    },
  );
  return (deleted: deleted.length, skipped: skipped);
}

TrashStore _trashOf(BuildContext context, AppState st) {
  try {
    return Provider.of<TrashStore>(context, listen: false);
  } catch (_) {
    return TrashStore(
        onChanged: () => st.refreshCollections(), appState: st);
  }
}

/// 批量删除所选树节点（收敛：桌面左栏 Delete/Backspace 快捷键与
/// [FavSelectBar] 的删除共用这一套，原两份重复实现已合并）。
///
/// - 文件夹/工程 → 逐个 [TrashStore.trashNode] 进回收站（可撤销）；
/// - 标记（含线组成员）→ [deleteMarksBatch] 合并为一条撤销记录；
/// - 文件夹级联会带走整棵子树：子树内的工程/标记先剔除，避免重复处理。
/// 确认框文案统一口径：「将把 X 个文件夹、Y 个工程移入回收站」。
/// 返回 true = 执行了删除；false = 取消 / 无可删项。
Future<bool> deleteSelectedTreeNodes(
    BuildContext context, FavTreeController c) async {
  final st = Provider.of<AppState>(context, listen: false);
  final trash = _trashOf(context, st);
  final nodes = [
    for (final id in c.selected) c.find(id),
  ].whereType<FavNode>().toList();
  if (nodes.isEmpty) {
    toast(context, '先选条目（点击 / Ctrl 多选 / Ctrl+A 全选）');
    return false;
  }

  // 文件夹级联会带走整棵子树：子树内的工程/标记先剔除，避免重复处理。
  final doomedFolders = <String>{};
  for (final n in nodes) {
    if (!n.isFolder) continue;
    doomedFolders.add(n.id);
    var grew = true;
    while (grew) {
      grew = false;
      for (final f in c.folders) {
        if (doomedFolders.contains(f.pid) && doomedFolders.add(f.id)) {
          grew = true;
        }
      }
    }
  }
  bool inDoomed(FavNode n) {
    if (n.isFolder) return false; // 文件夹自身走 trashNode
    final pid =
        n.isProject ? n.pid : (c.find(n.labelCid ?? '')?.pid ?? '');
    return doomedFolders.contains(pid);
  }

  final folders = <FavNode>[];
  final projects = <FavNode>[];
  final marks = <(String, MapLabel)>[];
  for (final n in nodes) {
    if (inDoomed(n)) continue;
    if (n.isFolder) {
      folders.add(n);
    } else if (n.isProject) {
      projects.add(n);
    } else if (n.isMark && n.label != null) {
      marks.add((n.labelCid ?? '', n.label!));
    } else if (n.isChain) {
      for (final m in await c.childrenOf(n.id)) {
        if (m.isMark && m.label != null) marks.add((n.chainCid ?? '', m.label!));
      }
    }
  }
  if (folders.isEmpty && projects.isEmpty && marks.isEmpty) {
    if (!context.mounted) return false;
    toast(context, '所选条目已失效');
    c.clearSelection();
    return false;
  }
  if (!context.mounted) return false;
  final ok = await askConfirm(context,
      title: '删除所选',
      content: '将把 ${folders.length} 个文件夹、${projects.length} 个工程'
          '移入回收站${marks.isNotEmpty ? '，并直接删除 ${marks.length} 个标记' : ''}。\n'
          '文件夹与工程可在回收站还原。确定？',
      okText: '删除');
  if (!ok || !context.mounted) return false;
  var failCount = 0;
  for (final f in folders) {
    // trashNode 返回 trashId：'' = 失败（节点已失效），报原因（B2）。
    if ((await trash.trashNode(c, f)).isEmpty) failCount++;
    if (!context.mounted) return false;
  }
  for (final p in projects) {
    if ((await trash.trashNode(c, p)).isEmpty) failCount++;
    if (!context.mounted) return false;
  }
  final markRes = await deleteMarksBatch(st, marks);
  c.clearSelection();
  if (!context.mounted) return true;
  final doneParts = <String>[
    if (folders.isNotEmpty || projects.isNotEmpty)
      '${folders.length + projects.length} 项已进回收站',
    if (markRes.deleted > 0) '删除 ${markRes.deleted} 个标记',
  ];
  var msg = doneParts.isEmpty ? '未删除任何条目' : '已删除所选（${doneParts.join('、')}）';
  final failParts = <String>[
    if (failCount > 0) '$failCount 项进回收站失败（条目已失效）',
    if (markRes.skipped > 0) '${markRes.skipped} 个标记所在工程未打开，已跳过',
  ];
  if (failParts.isNotEmpty) msg += '；${failParts.join('；')}';
  toast(context, msg);
  return true;
}
