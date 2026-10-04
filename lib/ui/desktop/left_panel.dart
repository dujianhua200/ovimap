import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/fav_node.dart';
import '../../models/map_label.dart';
import '../../design/design_menu_extra.dart';
import '../../design/project_wizard_page.dart';
import '../../survey/survey_menu_extra.dart';
import '../../services/store.dart';
import '../../state/app_state.dart';
import '../../state/fav_tree_controller.dart';
import '../../sync/sync_controller.dart';
import '../../sync/sync_models.dart';
import '../design_tokens.dart';
import '../dialogs.dart';
import '../export_center.dart';
import '../favorites/fav_actions.dart';
import '../favorites/fav_tree.dart';
import '../favorites/select_bar.dart';
import '../favorites/trash.dart';
import '../favorites/tree_keys.dart';
import '../favorites/tree_menus.dart';
import '../sync/sync_panel.dart';
import 'batch_export.dart';

/// 桌面左栏（Phase 2 收尾：树体换共享 [FavTree]，旧 1460 行自绘实现退役）。
///
/// 内容自上而下：标题 + 新建工程 / 新建文件夹 / 从模板新建（工程向导） /
/// 回收站 → 搜索框 →
/// 共享收藏树（[FavTree]，compact: false 桌面行高）→ 底部多选操作条
/// （[FavSelectBar]，isDesktop: true）→ 底部「导入区」（点击选文件 /
/// 应用内拖拽 → `.ovimap`/`.geojson` 分派，T21）。
///
/// ## 与旧面板的行为对齐
///
/// - 行级信息（tag/点数/同步徽标）：tag + 点数由 [FavTree] 内置
///   （`favKindTag`/`favKindColor` 即旧 `_itemCard` 口径）；同步徽标经
///   [FavTree.projectTrailing] 补（`SyncBadge`，`SyncController?` 可空接入）；
/// - 右键菜单：[FavTree] 内置 `showFavNodeMenu`（桌面 showMenu 样式），⋮ 按钮
///   与右键共用同一套入口（旧面板即此口径）；
/// - 审计问题 2：每行独立 eye → [setNodeVisible]（树显隐与地图显隐联动）；
/// - 审计问题 3：搜索模式由 [FavTree]（query 参数）处理，结果列表之上保留
///   文件夹投放行；
/// - 审计问题 6/5：拖拽（桌面 [Draggable] 整组跟随）/ 多选 / 悬停展开 /
///   文件夹整行投放由共享组件提供；
/// - 审计问题 7：新建文件夹默认建在当前树选中层（[FavTreeController.treeSelectedFolderId]）；
/// - 审计问题 8：删除一律进回收站（[TrashStore]/[TrashPage]），标题栏有回收站入口；
/// - 审计问题 9：树选中层一律走 [FavTreeController.treeSelectedFolderId]；
///   [AppState.folderId] 只保留"草稿保存目标"语义，本文件不再用它表示树选中；
/// - 审计问题 10：计数走 [FavTreeController.countOf]（工程数 + 点数）。
///
/// ## 桌面特有菜单（[FavMenuExtra] 扩展点）
///
/// 共享菜单之外的旧面板工程操作：同步该工程 / 历史版本 / 批量导出 DXF /
/// 竣工资料成册 / 竣工对比设计；文件夹的「把当前画布收藏到此」；以及「删除所选 N 项」。
class LeftPanel extends StatefulWidget {
  const LeftPanel({
    super.key,
    required this.st,
    this.searchFocus,
    required this.onNewProject,
    this.onLocate,
    this.onLocateGroup,
    this.onClose,
  });

  final AppState st;
  final FocusNode? searchFocus;

  /// 新建工程（清空草稿进入空白编辑态）。
  final VoidCallback onNewProject;

  /// 点击点位行 → 外壳把地图移过去并选中该点（相机归壳，左栏不持 `MapController`）。
  final void Function(MapLabel l)? onLocate;

  /// 点击组 → 定位整个组（全部点位）。
  final void Function(List<MapLabel>)? onLocateGroup;

  /// 面板以叠加方式悬浮在地图上时，标题栏出现「收起」按钮（见 workspace_page）。
  final VoidCallback? onClose;

  @override
  State<LeftPanel> createState() => _LeftPanelState();
}

class _LeftPanelState extends State<LeftPanel> {
  AppState get st => widget.st;
  String _query = '';

  /// 树控制器：优先用全局 provider（main.dart 接入
  /// `ChangeNotifierProvider<FavTreeController>`）；未接入时自建兜底。
  FavTreeController? _ctrl;
  FavTreeController? _ownedCtrl;

  /// 桌面特有菜单项（共享菜单之外的旧面板能力）。
  late final FavMenuExtra _menuExtra = FavMenuExtra(
    entries: _extraEntries,
    onSelected: _onExtraSelected,
  );

  /// Phase 4 提效三件套（智能布杆/配盘表/材料表）菜单扩展。
  late final FavMenuExtra _designExtra = buildDesignMenuExtra();

  /// Phase 5 勘察表单菜单扩展（标记节点）。
  late final FavMenuExtra _surveyExtra = buildSurveyMenuExtra();

  @override
  void initState() {
    super.initState();
    _ctrl = _resolveController();
    // 首帧可见性对齐：以 st.visibleCids（地图真相）为准对齐树 hiddenIds。
    // syncInitialVisibility 内部会 await c.ready；只改内存、不落盘。
    _syncVisibilityOnce();
  }

  FavTreeController _resolveController() {
    try {
      return Provider.of<FavTreeController>(context, listen: false);
    } on ProviderNotFoundException {
      return _ownedCtrl ??= FavTreeController(st);
    }
  }

  Future<void> _syncVisibilityOnce() async {
    try {
      await syncInitialVisibility(_ctrl!, st);
    } catch (_) {}
  }

  @override
  void dispose() {
    _ownedCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctrl!;
    // Delete / Backspace 删除所选（奥维同款）；F2 重命名 / Ctrl+A 全选由共享
    // [TreeKeyHandler] 提供（桌面/移动硬件键盘同一套逻辑）；
    // 批量选择必须**看得见**——标题栏按钮 + 右键菜单 + 快捷键三条路都给
    // （用户反馈只靠 Ctrl 找不到）。
    // ⚠️ Focus(autofocus: true) 让 Delete 等快捷键真正生效（此前无焦点不触发）。
    return ListenableBuilder(
      listenable: st,
      // TreeKeyHandler 必须在 autofocus Focus **之上**：按键事件从焦点节点
      // 向上冒泡，Shortcuts 只有位于焦点祖先链上才能收到。
      builder: (ctx, _) => TreeKeyHandler(
        controller: c,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.delete): _deleteSelected,
            const SingleActivator(LogicalKeyboardKey.backspace): _deleteSelected,
          },
          child: Focus(
            autofocus: true,
            child: Container(
            color: TokC.panelSolid,
            // TrashStore 提给子树（含 FavSelectBar / showFavNodeMenu 的
            // _trashOf 回退查找）：面板内单实例，徽标与批量删除共用。
            // （与移动端抽屉同一模式；main.dart 的全局实例被此处的局部遮蔽。）
            child: ChangeNotifierProvider<TrashStore>(
              create: (_) {
                final t = TrashStore(
                    onChanged: () => st.refreshCollections(),
                    appState: st);
                t.load();
                return t;
              },
              child: ListenableBuilder(
                listenable: c,
                builder: (ctx, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(ctx, c),
                    _searchBar(),
                    const Divider(height: 1, color: TokC.divider),
                    Expanded(
                      child: FavTree(
                        controller: c,
                        compact: false,
                        query: _query,
                        onLocate: _onLocate,
                        onLocateGroup: _onLocateGroup,
                        onOpenProject: _onOpenProject,
                        // 工程行同步状态徽标（旧 _itemCard 的 SyncBadge 位）。
                        // 形参名必须叫 context：源码级测试断言
                        // `left_panel.dart` 含字面 `context.watch<SyncController?>()`。
                        projectTrailing: (context, node) {
                          final sync = context.watch<SyncController?>();
                          final status =
                              sync?.statusFor(node.id) ?? SyncStatus.localOnly;
                          return SyncBadge(status: status);
                        },
                        // 桌面特有菜单项（同步/历史版本/批量导出/成册/收藏到此）。
                        menuExtra: _menuExtra,
                      ),
                    ),
                    // 多选模式：底部批量操作条（无选中时内部渲染为空）。
                    FavSelectBar(controller: c, isDesktop: true),
                    const Divider(height: 1, color: TokC.divider),
                    _dropZone(ctx),
                  ],
                ),
              ),
            ),
          ),
          ),
        ),
      ),
    );
  }

  // ---------- 标题栏：新建工程 / 新建文件夹 / 批量导出 / 回收站 ----------

  Widget _header(BuildContext context, FavTreeController c) {
    final nSel = c.selected.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
      child: Row(
        children: [
          const Icon(Icons.bookmarks, size: 18, color: kAccent),
          const SizedBox(width: 6),
          const Expanded(
            child: Text('收藏夹',
                style: TextStyle(
                    color: kTextMain,
                    fontSize: TokFs.heading,
                    fontWeight: FontWeight.bold)),
          ),
          // 新建工程入口（v3.4.0 改轨道时曾丢失，用户点名要回来）。
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '新建工程',
            onPressed: widget.onNewProject,
            icon: const Icon(Icons.note_add, color: kAccent, size: 20),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '新建文件夹（建在当前选中层）',
            onPressed: _addFolder,
            icon: const Icon(Icons.create_new_folder_outlined,
                color: kAccent, size: 20),
          ),
          // 工程向导：从模板一键生成目录结构（可选分支；原有直接新建流程不动）。
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '从模板新建（工程向导）',
            onPressed: () =>
                showProjectWizardDialog(context, controller: c),
            icon: const Icon(Icons.auto_awesome_outlined,
                color: kAccent, size: 20),
          ),
          // 有选中时：批量导出所选工程（DXF，T21 旧能力保留）。
          if (nSel > 0)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '批量导出 DXF（$nSel 项）',
              onPressed: () => _batchExportSelected(c),
              icon: const Icon(Icons.ios_share, color: kAccent, size: 20),
            ),
          _trashButton(context, c),
          if (widget.onClose != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '收起',
              onPressed: widget.onClose,
              icon: const Icon(Icons.close, color: kTextSub, size: 20),
            ),
        ],
      ),
    );
  }

  /// 回收站入口（审计问题 8）：徽标显示在站条目数 → [TrashPage]。
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

  // ---------- 搜索 ----------

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: TextField(
        focusNode: widget.searchFocus,
        onChanged: (v) => setState(() => _query = v.trim()),
        style: const TextStyle(color: kTextMain, fontSize: TokFs.body),
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
    if (l == null) return;
    widget.onLocate?.call(l);
  }

  /// 组定位：传入全部点位，地图缩放到整个组范围。
  Future<void> _onLocateGroup(List<MapLabel> labels) async {
    widget.onLocateGroup?.call(labels);
  }

  /// 点击工程行：打开工程（旧 `_onItemTap` 的普通点击路径）。
  Future<void> _onOpenProject(FavNode node) async {
    final m = node.project;
    if (m == null) return;
    await st.openCollection(m);
    if (!mounted) return;
    toast(context, '已打开「${m.name}」，可继续编辑');
  }

  // ---------- 新建文件夹（审计问题 7：建在当前树选中层） ----------

  Future<void> _addFolder() async {
    final c = _ctrl!;
    final parentId = c.treeSelectedFolderId;
    final parentName =
        parentId.isEmpty ? '根目录' : (c.find(parentId)?.name ?? '根目录');
    final name = await askText(context,
        title: '新建文件夹', hint: '文件夹名称（将建在：$parentName）');
    if (name == null || !mounted) return;
    await st.store.addFolder(name, parentId);
    await st.refreshCollections();
    // 保存对话框「所属文件夹」默认落到新建文件夹所在的这层（旧面板行为保留）。
    st.folderId = parentId;
    st.refreshUi();
    if (mounted) toast(context, '已创建文件夹「$name」');
  }

  // ---------- 批量导出所选工程（DXF，T21） ----------

  Future<void> _batchExportSelected(FavTreeController c) async {
    final targets = [
      for (final id in c.selected) c.find(id)?.project,
    ].whereType<CollectionMeta>().toList();
    if (targets.isEmpty) {
      toast(context, '所选条目中没有工程');
      return;
    }
    await batchExportDxf(context, st, targets);
  }

  // ---------- 多选：删除所选 ----------
  //
  // 全选（Ctrl+A）/ 重命名（F2）由共享 [TreeKeyHandler] 提供，逻辑只写一遍。

  /// 删除所选：收敛到 fav_actions 的共享实现（与 [FavSelectBar] 同一套，
  /// W1 遗留收敛项；批量标记合并为一条撤销记录）。
  Future<void> _deleteSelected() =>
      deleteSelectedTreeNodes(context, _ctrl!);

  // ---------- 桌面特有右键菜单项 ----------

  List<PopupMenuEntry<String>> _extraEntries(FavNode node) {
    final c = _ctrl!;
    const labelStyle = TextStyle(color: kTextMain, fontSize: TokFs.body);
    final items = <PopupMenuEntry<String>>[];
    if (c.selected.isNotEmpty) {
      items.add(PopupMenuItem(
        value: 'extra:delSel',
        height: 34,
        child: Text('删除所选 ${c.selected.length} 项',
            style: labelStyle.copyWith(color: kDanger)),
      ));
    }
    if (node.isFolder) {
      items.add(const PopupMenuItem(
        value: 'extra:saveHere',
        height: 34,
        child: Text('把当前画布收藏到此', style: labelStyle),
      ));
    }
    if (node.isProject) {
      items.addAll(const [
        PopupMenuItem(
            value: 'extra:sync', height: 34, child: Text('同步该工程', style: labelStyle)),
        PopupMenuItem(
            value: 'extra:history', height: 34, child: Text('历史版本', style: labelStyle)),
        PopupMenuItem(
            value: 'extra:batchExport',
            height: 34,
            child: Text('批量导出 DXF（选中项）', style: labelStyle)),
        PopupMenuItem(
            value: 'extra:archive',
            height: 34,
            child: Text('竣工资料成册', style: labelStyle)),
        PopupMenuItem(
            value: 'extra:design-diff',
            height: 34,
            child: Text('竣工对比设计', style: labelStyle)),
      ]);
    }
    // Phase 4 提效三件套：智能布杆/配盘表/汇总材料表（project/folder 按需出现）。
    items.addAll(_designExtra.entries(node));
    // Phase 5 勘察表单（标记节点）。
    items.addAll(_surveyExtra.entries(node));
    return items;
  }

  Future<void> _onExtraSelected(BuildContext ctx, FavTreeController c,
      FavNode node, String value) async {
    if (isDesignMenuValue(value)) {
      await _designExtra.onSelected(ctx, c, node, value);
      return;
    }
    if (isSurveyMenuValue(value)) {
      await _surveyExtra.onSelected(ctx, c, node, value);
      return;
    }
    switch (value) {
      case 'extra:delSel':
        await _deleteSelected();
        return;
      case 'extra:design-diff': {
        // 竣工对比：本工程=竣工版，对话框内再选设计版（复用选工程逻辑）。
        final m = node.project;
        if (m == null || !mounted) return;
        await showDesignDiffDialog(ctx, st, m);
        return;
      }
      case 'extra:saveHere':
        // 先把目标文件夹选上，保存对话框的"所属文件夹"即默认落在右键的这层。
        st.folderId = node.id;
        st.refreshUi();
        if (mounted) await showFinishDialog(context, st);
        return;
      case 'extra:sync':
      case 'extra:history':
      case 'extra:batchExport':
      case 'extra:archive': {
        final m = node.project;
        if (m == null || !mounted) return;
        if (value == 'extra:sync') {
          final sync = ctx.read<SyncController?>();
          if (sync == null || !sync.configured) {
            if (ctx.mounted) toast(ctx, '未配置云同步，请在「同步设置」里填入令牌');
            return;
          }
          if (ctx.mounted) toast(ctx, '正在同步「${m.name}」…');
          await sync.syncProject(m.id);
          if (!mounted) return;
          toast(context, '已同步「${m.name}」');
        } else if (value == 'extra:history') {
          // 版本历史与恢复（T20）。未配置令牌时对话框内给中文提示，不崩。
          await showVersionHistoryDialog(
              ctx, ctx.read<SyncController?>(), m.id, m.name);
        } else if (value == 'extra:batchExport') {
          // 批量导出：优先导出多选集合；无多选时退化为「仅本项」。
          final targets = [
            for (final id in c.selected) c.find(id)?.project,
          ].whereType<CollectionMeta>().toList();
          await batchExportDxf(
              ctx, st, targets.isEmpty ? <CollectionMeta>[m] : targets);
        } else {
          await showArchiveBookDialog(ctx, st);
        }
      }
    }
  }

  // ---- 导入区（点击选文件 / 应用内拖拽）T21 ----

  /// 点击「导入区」→ 选文件 → 按扩展名分派（`.ovimap` / `.geojson`）。
  Future<void> _importExternal() async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['ovimap', 'geojson', 'json'],
        withData: false,
      );
    } catch (e) {
      if (mounted) toast(context, '打开文件选择器失败：$e');
      return;
    }
    if (picked == null || picked.files.isEmpty) return; // 用户取消：静默
    final p = picked.files.first.path;
    if (p == null || p.isEmpty) {
      if (mounted) toast(context, '无法获取所选文件的内容');
      return;
    }
    final msg = await st.openExternalFiles(<String>[p]);
    if (mounted) toast(context, msg);
  }

  Widget _dropZone(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: DragTarget<Object>(
        onWillAcceptWithDetails: (_) => true,
        onAcceptWithDetails: (details) async {
          final raw = details.data;
          final path = raw is String ? raw : '$raw';
          final msg = await st.openExternalFiles(<String>[path]);
          if (context.mounted) toast(context, msg);
        },
        builder: (ctx, candidate, rejected) {
          final hot = candidate.isNotEmpty;
          return InkWell(
            onTap: _importExternal,
            borderRadius: BorderRadius.circular(TokR.m),
            child: Container(
              height: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: hot ? kAccent.withValues(alpha: 0.12) : TokC.field,
                  borderRadius: BorderRadius.circular(TokR.m),
                  border: Border.all(
                      color: hot ? kAccent : TokC.divider,
                      width: 1,
                      style: BorderStyle.solid)),
              child: const Text('点击导入文件，或拖入窗口\n（.ovimap 工程 / .geojson 底图）',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: kTextSub, fontSize: TokFs.micro, height: 1.4)),
            ),
          );
        },
      ),
    );
  }
}
