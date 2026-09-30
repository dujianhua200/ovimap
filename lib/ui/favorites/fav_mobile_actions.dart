import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/fav_node.dart';
import '../../services/platform_caps.dart';
import '../../services/store.dart';
import '../../state/app_state.dart';
import '../../sync/sync_controller.dart';
import '../dialogs.dart';
import '../../export/archive_book.dart';
import '../../export/topo_png.dart';
import '../export_center.dart';
import '../sync/sync_panel.dart';
import 'tree_menus.dart';

/// 移动端独有工程操作：旧 drawer_panel（87c98ee^）的 per-row 能力，接回共享菜单。
///
/// 旧抽屉每个工程行有「⋯」菜单，含 7 个操作：
/// 同步该工程 / 历史版本 / 拓扑连线 / 配线图PNG / 竣工成册 / 导入箱体 / 竣工对比设计。
/// 通用菜单 [showFavNodeMenu] 的 project 项里没有它们，这里以 [FavMenuExtra]
/// 扩展点形式提供：移动端 `FavTree(menuExtra: favMobileProjectExtra())`，
/// 配合 compact 行尾「⋯」→ 底弹菜单，即可看到这 7 项（value 均以 `extra:` 开头）。
///
/// 桌面端不受影响（desktop 传自己的 menuExtra，不传这个）。
/// AppState 经 Provider 获取（与 [showFavNodeMenu] 一致，不自建实例）。

/// 7 个移动端工程操作的菜单项（value 均以 `extra:` 开头）。
List<PopupMenuEntry<String>> favMobileProjectEntries() => const [
      PopupMenuItem(
          value: 'extra:sync_project',
          height: 34,
          child: Text('同步该工程')),
      PopupMenuItem(
          value: 'extra:history', height: 34, child: Text('历史版本')),
      PopupMenuItem(
          value: 'extra:topo_link', height: 34, child: Text('拓扑连线')),
      PopupMenuItem(
          value: 'extra:topo_png', height: 34, child: Text('配线图 PNG')),
      PopupMenuItem(
          value: 'extra:archive_book',
          height: 34,
          child: Text('竣工资料一键成册')),
      PopupMenuItem(
          value: 'extra:import_boxes',
          height: 34,
          child: Text('导入箱体节点')),
      PopupMenuItem(
          value: 'extra:diff_design',
          height: 34,
          child: Text('竣工对比设计')),
    ];

/// 移动端工程操作扩展点：`FavTree(menuExtra: favMobileProjectExtra())`。
FavMenuExtra favMobileProjectExtra() => FavMenuExtra(
      entries: (node) =>
          node.isProject ? favMobileProjectEntries() : const [],
      onSelected: (ctx, c, node, value) =>
          handleFavMobileProjectAction(ctx, node, value),
    );

/// 执行移动端工程操作；value 由 [favMobileProjectEntries] 定义。
Future<void> handleFavMobileProjectAction(
    BuildContext context, FavNode node, String value) async {
  final st = Provider.of<AppState>(context, listen: false);
  final m = node.project;
  if (m == null) return;
  switch (value) {
    case 'extra:sync_project':
      await _syncProject(context, m);
    case 'extra:history':
      await showVersionHistoryDialog(
          context, context.read<SyncController?>(), m.id, m.name);
    case 'extra:topo_link':
      await _topoLink(context, st, m);
    case 'extra:topo_png':
      await _topoPng(context, st, m);
    case 'extra:archive_book':
      await _archiveBook(context, st, m);
    case 'extra:import_boxes':
      if (context.mounted) await _showImportBoxesDialog(context, st, m);
    case 'extra:diff_design':
      if (context.mounted) await showDesignDiffDialog(context, st, m);
  }
}

Future<void> _syncProject(BuildContext context, CollectionMeta m) async {
  final sync = context.read<SyncController?>();
  if (sync == null || !sync.configured) {
    if (context.mounted) {
      toast(context, '未配置云同步，请在「同步设置」里填入令牌');
    }
    return;
  }
  if (context.mounted) toast(context, '正在同步「${m.name}」…');
  await sync.syncProject(m.id);
  if (context.mounted) toast(context, '已同步「${m.name}」');
}

Future<void> _topoLink(
    BuildContext context, AppState st, CollectionMeta m) async {
  // 拓扑连线要在地图上点选箱体：移动端先关抽屉再进连线模式（旧抽屉行为）。
  if (!PlatformCaps.isDesktop && context.mounted) Navigator.pop(context);
  final ok = await st.startTopoLink(m);
  if (context.mounted) {
    toast(context,
        ok ? '点起点箱体→点终点箱体进行连线' : '该收藏没有可连线的箱体节点');
  }
}

Future<void> _topoPng(
    BuildContext context, AppState st, CollectionMeta m) async {
  final ls = await st.store.loadCollection(m.id);
  try {
    final f = await TopoPngExporter.render(ls, m.name, 1400);
    if (context.mounted) await shareFile(context, f);
  } catch (e) {
    if (context.mounted) toast(context, '$e');
  }
}

/// 竣工资料一键成册：把本工程的成果打成一个 ZIP（缺项自动跳过）。
Future<void> _archiveBook(
    BuildContext context, AppState st, CollectionMeta m) async {
  final ls = await st.store.loadCollection(m.id);
  if (!context.mounted) return;
  if (ls.isEmpty) {
    toast(context, '该工程没有点位');
    return;
  }
  toast(context, '正在生成竣工资料成册…');
  try {
    final r = await ArchiveBookExporter.export(
      name: m.name.isEmpty ? '未命名项目' : m.name,
      labels: ls,
      pointCount: m.count,
      editMode: m.editMode,
      segPrefix: st.segPrefix,
    );
    if (!context.mounted) return;
    if (r.skipped.isNotEmpty) {
      toast(context, '成册完成，缺项：${r.skipped.join('、')}');
    } else {
      toast(context, '成册完成：含 ${r.included.length} 项');
    }
    await shareFile(context, r.zip);
  } catch (e) {
    if (context.mounted) toast(context, '成册失败：$e');
  }
}

/// 导入箱体节点：选择来源工程 → 把其光交/分光箱/分纤盒/ONU/机房/基站/引上并入本工程。
Future<void> _showImportBoxesDialog(
    BuildContext context, AppState st, CollectionMeta target) async {
  final sources = st.collections.where((c) => c.id != target.id).toList();
  if (sources.isEmpty) {
    if (context.mounted) toast(context, '没有其他工程可导入');
    return;
  }
  // 统计每个来源工程的箱体数量，列表项显示"其中箱体 M 个"。
  final boxCounts = <String, int>{};
  for (final c in sources) {
    try {
      final ls = await st.store.loadCollection(c.id);
      boxCounts[c.id] = ls.where((l) => l.type.isTopoLinkable).length;
    } catch (_) {
      boxCounts[c.id] = 0;
    }
  }
  if (!context.mounted) return;
  await showDarkDialog(
    context,
    title: '导入箱体到「${target.name}」',
    content: SizedBox(
      width: double.maxFinite,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text(
            '选择来源工程，将其中的光交箱/分纤盒/分光器箱/ONU箱/机房/基站/引上节点并入当前工程（同位置同类型自动去重）',
            style: TextStyle(color: kTextSub, fontSize: 12)),
        const SizedBox(height: 10),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final c in sources)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.call_received,
                      color: kAccent, size: 20),
                  title: Text(c.name.isEmpty ? '未命名' : c.name,
                      style: const TextStyle(
                          color: kTextMain, fontSize: 13.5)),
                  subtitle: Text(
                      '${c.count} 点 · 其中箱体 ${boxCounts[c.id] ?? 0} 个',
                      style: const TextStyle(
                          color: kTextSub, fontSize: 11)),
                  onTap: () async {
                    Navigator.pop(context);
                    bool overwrite = false;
                    final result = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => StatefulBuilder(
                        builder: (ctx, setState) => AlertDialog(
                          title: const Text('导入箱体节点'),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                  '是否覆盖目标工程中同位置同类型的箱体节点的属性？'),
                              CheckboxListTile(
                                title:
                                    const Text('覆盖已有同位置同类型的属性'),
                                value: overwrite,
                                onChanged: (bool? value) {
                                  setState(() {
                                    overwrite = value ?? false;
                                  });
                                },
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(ctx).pop(),
                              child: const Text('取消'),
                            ),
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(ctx).pop(overwrite),
                              child: const Text('确定'),
                            ),
                          ],
                        ),
                      ),
                    );
                    if (result == null) return; // 取消/关闭：不导入
                    overwrite = result;
                    final n = await st.importBoxesToCollection(
                        target.id, c.id, overwriteSame: overwrite);
                    if (context.mounted) {
                      toast(context,
                          n == 0 ? '没有可导入的箱体节点（或已全部导入）' : '已导入 $n 个箱体节点');
                    }
                  },
                ),
            ],
          ),
        ),
      ]),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
    ],
  );
}
