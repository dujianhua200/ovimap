import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../export/kml.dart';
import '../models/fav_node.dart';
import '../models/map_label.dart';
import '../state/app_state.dart';
import '../state/fav_tree_controller.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_models.dart';
import 'design_tokens.dart';
import 'dialogs.dart';
import 'favorites/fav_actions.dart';
import 'favorites/fav_mobile_actions.dart';
import 'favorites/fav_tree.dart';
import 'favorites/select_bar.dart';
import 'favorites/trash.dart';
import 'sync/sync_panel.dart';

/// 收藏夹抽屉（移动端）：奥维式收藏树。
///
/// - 树体：共享 [FavTree]（lib/ui/favorites，与桌面端同一套树组件/控制器；
///   行级手势、拖拽、eye、计数、搜索均由其内部实现）；
/// - 审计问题 1：文件夹树形展示替代旧扁平 chips；
/// - 审计问题 3：搜索模式由 [FavTree]（query 参数）处理，结果列表之上保留
///   文件夹投放行；
/// - 审计问题 7：新建文件夹建在当前树选中层（[FavTreeController.treeSelectedFolderId]）；
/// - 审计问题 9：树选中一律走 [FavTreeController.treeSelectedFolderId] /
///   [FavTreeController.selectTreeFolder]；[AppState.folderId] 只保留"草稿保存目标"
///   语义，本文件不再读写它；
/// - 审计问题 8：删除进回收站（[TrashStore]/[TrashPage]），工具条有回收站入口。
///
/// 手势（由 [FavTree] 实现，移动端）：短按=打开/定位/展开；长按=进入多选；
/// 拖拽=行级 Draggable 整组跟随；文件夹整行 DragTarget 投放。
class FavoritesDrawer extends StatefulWidget {
  final AppState st;

  /// 点位定位回调（home_page 注入：把地图相机移到该点位）。
  /// 可选：不传时 mark 点选仅关闭抽屉。
  final void Function(MapLabel label)? onLocateLabel;

  const FavoritesDrawer({super.key, required this.st, this.onLocateLabel});

  @override
  State<FavoritesDrawer> createState() => _FavoritesDrawerState();
}

class _FavoritesDrawerState extends State<FavoritesDrawer> {
  AppState get st => widget.st;

  final _searchCtl = TextEditingController();
  String _query = '';

  /// 树控制器：优先用全局 provider（桌面线在 main.dart 接入
  /// `ChangeNotifierProvider<FavTreeController>`）；未接入时抽屉自建兜底。
  FavTreeController? _ctrl;
  FavTreeController? _ownedCtrl;

  @override
  void initState() {
    super.initState();
    _ctrl = _resolveController();
    // 首帧可见性对齐：以 st.visibleCids（地图真相）为准对齐树 hiddenIds。
    // syncInitialVisibility 内部会 await c.ready；只改内存、不落盘。
    _syncVisibilityOnce();
  }

  Future<void> _syncVisibilityOnce() async {
    try {
      await syncInitialVisibility(_ctrl!, st);
    } catch (_) {}
  }

  FavTreeController _resolveController() {
    try {
      return Provider.of<FavTreeController>(context, listen: false);
    } on ProviderNotFoundException {
      // 全局 provider 尚未接入（桌面线负责 main.dart）时的兜底。
      return _ownedCtrl ??= FavTreeController(st);
    }
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _ownedCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctrl!;
    // TrashStore 提给子树（含 FavSelectBar 的 _trashOf 回退查找）：
    // 抽屉内单实例，徽标与批量删除共用。
    return ChangeNotifierProvider<TrashStore>(
      create: (_) {
        final t = TrashStore(onChanged: () => st.refreshCollections());
        t.load();
        return t;
      },
      child: Builder(
        builder: (ctx) => Drawer(
          backgroundColor: TokC.panelSolid,
          child: SafeArea(
            // 整抽屉跟随控制器刷新：多选计数等保持最新（树体内部另有监听）。
            child: ListenableBuilder(
              listenable: c,
              builder: (_, _) => Column(
                children: [
                  _header(ctx, c),
                  _searchBar(),
                  const Divider(height: 1, color: TokC.divider),
                  Expanded(
                    child: FavTree(
                      controller: c,
                      compact: true,
                      query: _query,
                      onLocate: _onLocate,
                      onOpenProject: _onOpenProject,
                      // 移动端：工程行同步状态徽标
                      // （T17：SyncController? 可空接入，AOT 安全）。
                      // 「⋯」菜单由 FavTree 在 compact 模式内置，
                      // 这里只补徽标（旧抽屉的 per-row 徽标能力不丢失）。
                      projectTrailing: (mctx, node) {
                        final sync = mctx.watch<SyncController?>();
                        final status =
                            sync?.statusFor(node.id) ?? SyncStatus.localOnly;
                        return SyncBadge(status: status);
                      },
                      // 移动端：行尾「⋯」由 FavTree 内置（所有行），菜单追加项为
                      // 7 个旧抽屉独有工程操作（同步该工程/历史版本/拓扑连线/
                      // 配线图PNG/竣工成册/导入箱体/竣工对比设计）。
                      menuExtra: favMobileProjectExtra(),
                    ),
                  ),
                  // 多选模式：底部批量操作条（无选中时内部渲染为空）。
                  FavSelectBar(controller: c, isDesktop: false),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 头部：标题 / 全部KML / 新建文件夹 / 回收站 / 多选 ----------

  Widget _header(BuildContext context, FavTreeController c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
      child: Row(
        children: [
          const Expanded(
            child: Text('收藏夹',
                style: TextStyle(
                    color: kTextMain,
                    fontSize: 17,
                    fontWeight: FontWeight.bold)),
          ),
          // 多选模式开关：进入靠长按条目；此处提供退出 + 已选计数。
          Builder(builder: (ctx) {
            final n = c.selected.length;
            return IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: n == 0 ? '多选（长按条目进入）' : '退出多选（已选 $n 项）',
              onPressed: () {
                if (n == 0) {
                  toast(ctx, '长按条目进入多选模式，可批量移动/删除');
                } else {
                  c.clearSelection();
                }
              },
              icon: Icon(n == 0 ? Icons.checklist : Icons.close,
                  color: n == 0 ? kTextSub : kAccent, size: 20),
            );
          }),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '新建文件夹（建在当前选中层）',
            onPressed: () => _addFolder(context, c),
            icon: const Icon(Icons.create_new_folder_outlined,
                color: kAccent, size: 20),
          ),
          _trashButton(context, c),
          TextButton.icon(
            onPressed: () => _exportAllKml(context),
            icon: const Icon(Icons.share, size: 16, color: kAccent),
            label: const Text('全部KML',
                style: TextStyle(color: kAccent, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _trashButton(BuildContext context, FavTreeController c) {
    final trash = context.watch<TrashStore>();
    final n = trash.items.length;
    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: '回收站',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TrashPage(trash: trash, controller: c),
            ),
          ),
          icon: const Icon(Icons.delete_outline, color: kTextSub, size: 20),
        ),
        if (n > 0)
          Positioned(
            right: 4,
            top: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: TokC.danger,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('$n',
                  style: const TextStyle(color: Colors.white, fontSize: 9)),
            ),
          ),
      ],
    );
  }

  /// 审计问题 7：新建文件夹默认建在当前树选中层，不再永远建在根。
  Future<void> _addFolder(
      BuildContext context, FavTreeController c) async {
    final parentId = c.treeSelectedFolderId;
    final parentName =
        parentId.isEmpty ? '根目录' : (c.find(parentId)?.name ?? '根目录');
    final name = await askText(context,
        title: '新建文件夹', hint: '文件夹名称（将建在：$parentName）');
    if (name == null) return;
    await st.store.addFolder(name, parentId);
    await st.refreshCollections();
  }

  /// 导出全部收藏为 KML（旧抽屉头部能力，保留）。
  Future<void> _exportAllKml(BuildContext context) async {
    final all = <MapLabel>[];
    for (final m in st.collections) {
      all.addAll(await st.store.loadCollection(m.id));
    }
    if (!context.mounted) return;
    if (all.isEmpty) {
      toast(context, '还没有任何收藏');
      return;
    }
    try {
      final f =
          await KmlExporter.export('滑洲云图全部收藏', all, KmlExporter.all);
      if (context.mounted) shareFile(context, f);
    } catch (e) {
      if (context.mounted) toast(context, '导出失败：$e');
    }
  }

  // ---------- 搜索 ----------

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: TextField(
        controller: _searchCtl,
        onChanged: (v) => setState(() => _query = v.trim()),
        style: const TextStyle(color: kTextMain, fontSize: 13),
        decoration: dec('搜索工程名 / 标记名 / 备注（跨文件夹）').copyWith(
          prefixIcon: const Icon(Icons.search, color: kTextSub, size: 18),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    );
  }

  // ---------- 树回调：定位点位 / 打开工程 ----------

  /// [FavTree] 的 onLocate 总是收到带 label 的 mark 节点
  /// （工程/线组在内部已取首个点位包装）。
  Future<void> _onLocate(FavNode node) async {
    final l = node.label;
    Navigator.pop(context); // 关抽屉
    if (l != null) widget.onLocateLabel?.call(l);
  }

  void _onOpenProject(FavNode node) {
    final m = node.project;
    if (m == null) return;
    Navigator.pop(context); // 关抽屉
    st.openCollection(m).then((_) {
      if (mounted) toast(context, '已打开「${m.name}」，可继续编辑');
    });
  }
}
