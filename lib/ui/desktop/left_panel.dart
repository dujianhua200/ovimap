import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../geo/geo_util.dart';
import '../../geo/route_segments.dart';
import '../../models/map_label.dart';
import '../../services/store.dart';
import '../../state/app_state.dart';
import '../../sync/sync_controller.dart';
import '../../sync/sync_models.dart';
import '../design_tokens.dart';
import '../dialogs.dart';
import '../export_center.dart';
import '../sync/sync_panel.dart';
import 'batch_export.dart';

/// 段标就地编辑输入框的 Key。
///
/// 左栏里有两个 `TextField`（顶部工程搜索框 + 这里的段标输入框），
/// 测试/finder 必须能精确命中后者，否则会撞上 `Too many elements`。
const Key kSegLabelEditorKey = ValueKey<String>('segLabelEditor');

/// 桌面左栏（架构文档 §3.2 / T09）。
///
/// 内容自上而下：标题 + 新建工程 → 搜索框 → 文件夹树 → 工程列表（每项带
/// **同步徽标** ✓/↑/⚠/●；支持 **Ctrl/Shift 多选** → 右键「批量导出 DXF」）→
/// **本工程段落 / 点位表**（可就地改段标，见 [LeftPanel.onLocate]）→
/// 底部「导入区」（点击选文件 / 应用内拖拽 → `.ovimap`/`.geojson` 分派，T21）。
///
/// ## 为什么左栏要有「段落表」
///
/// 线路设计人员最高频的修改动作是「改某一档的标注」——现场量了 42.5 米，要把图上
/// 那一段改成「埋42.5」。原先只能在图上点中该点、再去右栏属性面板找「本段标注」，
/// 一档一档来；几十档的线路就是几十次「地图找点 → 点中 → 右栏改」。左栏段落表把
/// 全线的段按顺序铺出来，**在哪一档改哪一档**，还能一眼看到整条线路的段距分布。
class LeftPanel extends StatefulWidget {
  const LeftPanel({
    super.key,
    required this.st,
    this.searchFocus,
    required this.onNewProject,
    this.onLocate,
    this.onClose,
  });

  final AppState st;
  final FocusNode? searchFocus;

  /// 新建工程（清空草稿进入空白编辑态）。
  final VoidCallback onNewProject;

  /// 点击段落/点位行 → 外壳把地图移过去并选中该点（相机归壳，左栏不持 `MapController`）。
  final void Function(MapLabel l)? onLocate;

  /// 面板以叠加方式悬浮在地图上时，标题栏出现「收起」按钮（见 workspace_page）。
  final VoidCallback? onClose;

  @override
  State<LeftPanel> createState() => _LeftPanelState();
}

class _LeftPanelState extends State<LeftPanel> {
  AppState get st => widget.st;
  String _query = '';

  /// 多选集合（Ctrl/Shift 点击维护）；普通点击会清空后打开工程。
  final Set<String> _selected = <String>{};

  /// Shift 范围选择的锚点（上一次 Ctrl/普通点击的工程 id）。
  String _anchor = '';

  /// 底部「本工程」区是否展开；默认收起，避免新用户一进来就看到一片列表。
  bool _draftOpen = false;

  /// 当前用哪个视图看草稿：「段落」（默认，出图改标注用）或「点位」。
  bool _segView = true;

  /// 正在就地编辑段标的点 id（空 = 没有在编辑）。
  String _editingId = '';
  final TextEditingController _segCtl = TextEditingController();
  final FocusNode _segFocus = FocusNode();

  @override
  void dispose() {
    _segCtl.dispose();
    _segFocus.dispose();
    super.dispose();
  }

  /// 开始就地编辑某一段的段标。
  void _beginEdit(MapLabel to) {
    setState(() {
      _editingId = to.id;
      _segCtl.text = to.distLabel;
    });
    // 下一帧再聚焦：本帧该输入框还没进树。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _segFocus.requestFocus();
        _segCtl.selection = TextSelection(
            baseOffset: 0, extentOffset: _segCtl.text.length);
      }
    });
  }

  void _commitEdit(MapLabel to) {
    final changed = st.setSegLabel(to, _segCtl.text);
    setState(() => _editingId = '');
    if (changed) {
      toast(context, _segCtl.text.trim().isEmpty
          ? '已清除手填标注，该段改按敷设方式 + 实测距离自动显示'
          : '段标已更新（Ctrl+Z 可撤销）');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: TokC.panelSolid,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          _searchBar(),
          const Divider(height: 1, color: TokC.divider),
          Expanded(child: _favoritesView(context)),
          _draftSection(),
          _dropZone(context),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
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

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: TextField(
        focusNode: widget.searchFocus,
        onChanged: (v) => setState(() => _query = v.trim()),
        style: const TextStyle(color: kTextMain, fontSize: TokFs.body),
        decoration: dec('搜索工程名/备注（跨文件夹）').copyWith(
          prefixIcon: const Icon(Icons.search, color: kTextSub, size: 18),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    );
  }

  // ---- 收藏夹（叠加式多级导航） ----
  //
  // 用户反馈「收藏夹最好用叠加功能来实现多级文件夹的访问」：不再一棵树平铺，
  // 而是**逐级钻入**——列表只显示当前层的子文件夹与工程；点文件夹进入该层，
  // 面包屑（或「..」）逐级返回。层级状态用 [_nav] 栈表达，天然支持任意深度。

  /// 导航栈：空 = 根目录；最后一位 = 当前所在文件夹。
  final List<Folder> _nav = <Folder>[];

  /// 已展开（显示二级）的文件夹 id 集（+/− 树）。
  final Set<String> _expanded = <String>{};

  String get _currentFolderId => _nav.isEmpty ? '' : _nav.last.id;

  /// 收藏夹主视图：面包屑栏 + 当前层内容（子文件夹在上、工程在下）。
  Widget _favoritesView(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _breadcrumbBar(),
        Expanded(child: _currentLevelList(context)),
      ],
    );
  }

  /// 面包屑栏：根目录显示标题；进入子级后给出可点击的完整路径与「新建文件夹」。
  Widget _breadcrumbBar() {
    final crumbs = <Widget>[
      InkWell(
        onTap: _nav.isEmpty ? null : _backToRoot,
        child: Text('收藏夹',
            style: TextStyle(
                color: _nav.isEmpty ? kTextMain : kAccent,
                fontSize: TokFs.body,
                fontWeight: FontWeight.w600)),
      ),
    ];
    for (var i = 0; i < _nav.length; i++) {
      final last = i == _nav.length - 1;
      final f = _nav[i];
      crumbs.add(const Text(' › ',
          style: TextStyle(color: kTextHint, fontSize: TokFs.body)));
      crumbs.add(InkWell(
        onTap: last ? null : () => setState(() => _nav.removeRange(i + 1, _nav.length)),
        child: Text(f.name,
            style: TextStyle(
                color: last ? kTextMain : kAccent,
                fontSize: TokFs.body,
                fontWeight: last ? FontWeight.w600 : FontWeight.normal),
                maxLines: 1, overflow: TextOverflow.ellipsis),
      ));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
      child: Row(children: [
        ...crumbs,
        const Spacer(),
        TextButton(
          onPressed: () => _addFolder(),
          child: const Text('新建文件夹',
              style: TextStyle(color: kAccent, fontSize: TokFs.small)),
        ),
      ]),
    );
  }

  void _drillInto(Folder f) {
    setState(() => _nav.add(f));
    st.folderId = f.id;
    st.refreshUi();
  }

  void _backToRoot() {
    setState(() => _nav.clear());
    st.folderId = '';
    st.refreshUi();
  }

  void _backOneLevel() {
    setState(() {
      if (_nav.isNotEmpty) _nav.removeLast();
    });
    st.folderId = _currentFolderId;
    st.refreshUi();
  }

  /// 当前层内容：搜索时跨全库；否则显示当前文件夹的子文件夹（可 +/- 展开）+ 工程。
  Widget _currentLevelList(BuildContext context) {
    if (_query.isNotEmpty) return _collectionList(context);

    final fid = _currentFolderId;
    final subfolders = [
      for (final f in st.folders)
        if (f.id.isNotEmpty && f.parentId == fid) f,
    ];

    final rows = <Widget>[
      // 「..」返回上级（根目录不显示）。
      if (_nav.isNotEmpty)
        InkWell(
          onTap: _backOneLevel,
          child: Container(
            height: 32,
            padding: const EdgeInsets.only(left: 10, right: 8),
            child: Row(children: [
              const Icon(Icons.arrow_back_ios_new, size: 13, color: kTextSub),
              const SizedBox(width: 6),
              Text('..',
                  style: const TextStyle(color: kTextSub, fontSize: TokFs.body)),
            ]),
          ),
        ),
      // 子文件夹树：+/− 展开/收缩二级（用户指定交互），点名称仍可钻入。
      ..._folderRows(subfolders, 0),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
          ),
        ),
        Expanded(child: _collectionList(context)),
      ],
    );
  }

  /// 递归构建文件夹行：展开的文件夹其子级缩进显示。
  List<Widget> _folderRows(List<Folder> roots, int baseDepth) {
    final rows = <Widget>[];
    void rec(Folder f, int depth) {
      rows.add(_folderRow(f, depth));
      if (_expanded.contains(f.id)) {
        for (final c in st.folders) {
          if (c.id.isNotEmpty && c.parentId == f.id) rec(c, depth + 1);
        }
      }
    }

    for (final f in roots) {
      rec(f, baseDepth);
    }
    return rows;
  }

  /// 文件夹行：**有子级时前缀 +/− 号**——点 + 展开二级（变 −），点 − 收缩；
  /// 点名称/行钻入该层（面包屑导航仍在）。右侧显示内含工程数。
  Widget _folderRow(Folder f, int depth) {
    final count = st.collections.where((m) => m.folder == f.id).length;
    final kids =
        st.folders.where((c) => c.id.isNotEmpty && c.parentId == f.id).toList();
    final expanded = _expanded.contains(f.id);
    return InkWell(
      onTap: () => _drillInto(f),
      // 桌面惯例是右键；长按保留给触屏（移动端抽屉同一套手势语义）。
      onSecondaryTapUp: (d) => _showFolderMenu(f, d.globalPosition),
      onLongPress: () {
        final box = context.findRenderObject() as RenderBox?;
        final pos = box != null && box.localToGlobal(Offset.zero).dy >= 0
            ? box.localToGlobal(const Offset(80, 40))
            : Offset.zero;
        _showFolderMenu(f, pos);
      },
      child: Container(
        height: 32,
        margin: EdgeInsets.only(left: 6.0 + depth * 14.0, right: 6, top: 1, bottom: 1),
        padding: const EdgeInsets.only(left: 6, right: 4),
        decoration: BoxDecoration(
          color: TokC.field,
          borderRadius: BorderRadius.circular(TokR.s),
        ),
        child: Row(
          children: [
            if (kids.isEmpty)
              const Icon(Icons.folder, size: 15, color: kTextSub)
            else
              // 加号=收起（可展开），减号=已展开（点击收缩）。
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() {
                  if (expanded) {
                    _expanded.remove(f.id);
                  } else {
                    _expanded.add(f.id);
                  }
                }),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
                  child: Icon(
                    expanded ? Icons.remove : Icons.add,
                    size: 14,
                    color: kAccent,
                  ),
                ),
              ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(f.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: kTextMain,
                      fontSize: TokFs.body,
                      fontWeight: FontWeight.w500)),
            ),
            Text('$count 工程',
                style: const TextStyle(
                    color: kTextHint, fontSize: TokFs.micro)),
            const Icon(Icons.chevron_right, size: 15, color: kTextHint),
          ],
        ),
      ),
    );
  }

  /// 在指定屏幕位置弹菜单（右键 / 长按共用）。
  ///
  /// 用 `showMenu` 而不是对话框：奥维式的收藏夹操作是"右键哪一项就操作哪一项"，
  /// 弹模态框会打断"连着整理一排文件夹"的节奏。
  Future<void> _showMenuAt(
      Offset pos, List<PopupMenuEntry<String>> items,
      void Function(String) onSelected) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final sel = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
          Rect.fromPoints(pos, pos), Offset.zero & overlay.size),
      color: kPanelBg,
      items: items,
    );
    if (sel != null) onSelected(sel);
  }

  void _showFolderMenu(Folder f, Offset pos) {
    _showMenuAt(pos, [
      const PopupMenuItem(
          value: 'sub', height: 34, child: Text('新建子文件夹')),
      const PopupMenuItem(
          value: 'save', height: 34, child: Text('把当前画布收藏到此')),
      const PopupMenuItem(value: 'rename', height: 34, child: Text('重命名')),
      const PopupMenuItem(value: 'delete', height: 34, child: Text('删除')),
    ], (v) async {
      switch (v) {
        case 'sub':
          await _addFolder(parentId: f.id);
          break;
        case 'save':
          // 先把目标文件夹选上，保存对话框的"所属文件夹"即默认落在右键的这层。
          st.folderId = f.id;
          st.refreshUi();
          if (mounted) await showFinishDialog(context, st);
          break;
        case 'rename':
          await _renameFolder(f);
          break;
        case 'delete':
          await _confirmDeleteFolder(f);
          break;
      }
    });
  }

  /// 新建文件夹（修「新建一个出现 2 个」）。
  ///
  /// 旧实现的坑：`onSubmitted` 里 `created.complete(st.store.addFolder(...))`
  /// —— 回车后**对话框不关闭**；再按一次回车时，`complete` 的参数表达式
  /// 会先求值（第二个 `addFolder` 已发出去）才抛 StateError，两个并发写盘
  /// 竞态后文件夹就成了两个。现改为单一提交口 `submit` + `done` 闸门：
  /// 回车/按钮谁先来都只建一次，且回车立即关框。
  Future<void> _addFolder({String? parentId}) async {
    final ctl = TextEditingController();
    final parent = parentId ?? _currentFolderId;
    var done = false;
    Future<void> submit() async {
      if (done) return;
      done = true;
      Navigator.pop(context);
      final f = await st.store
          .addFolder(ctl.text.trim(), parent.isEmpty ? '' : parent);
      await st.refreshCollections();
      // 新文件夹就在当前层列表里可见（parent 即当前层），不用跳转。
      st.folderId = parent;
      st.refreshUi();
      if (mounted) toast(context, '已创建文件夹「${f.name}」');
    }

    await showDarkDialog(context,
        title: '新建文件夹',
        content: TextField(
            controller: ctl,
            autofocus: true,
            // 回车直接建并关框——"新建→命名→回车"是高频动作。
            onSubmitted: (_) => submit(),
            style: const TextStyle(color: kTextMain),
            decoration: dec(parent.isEmpty
                ? '文件夹名称（建在根目录）'
                : '文件夹名称（建在「${_folderName(parent)}」内）')),
        actions: [
          darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
          darkTextBtn('创建', () => submit(), color: kGreen),
        ]);
  }

  /// 移动工程到目标文件夹：**下拉选择**（用户指定交互）。
  ///
  /// 候选 = 根目录 + 全部文件夹，按层级缩进；一次选择一次确认，不再把每个
  /// 文件夹摆成一个按钮（文件夹一多旧交互既放不下也看不清层级）。
  Future<void> _moveToFolderDialog(
      BuildContext context, CollectionMeta m) async {
    // 层级深度：用于下拉项缩进。
    int depthOf(Folder f) {
      var d = 0;
      var pid = f.parentId;
      while (pid.isNotEmpty) {
        final p = st.folders.where((e) => e.id == pid).toList();
        if (p.isEmpty) break;
        pid = p.first.parentId;
        d++;
      }
      return d;
    }

    var target = m.folder;
    var moved = false;
    await showDarkDialog(
      context,
      title: '移动「${m.name}」',
      content: StatefulBuilder(
        builder: (ctx, setSt) => DropdownButtonFormField<String>(
          value: target,
          dropdownColor: TokC.panelSolid,
          isExpanded: true,
          style: const TextStyle(color: kTextMain, fontSize: TokFs.body),
          decoration: dec('移动到…'),
          items: [
            const DropdownMenuItem(value: '', child: Text('根目录')),
            for (final f in st.folders)
              if (f.id != m.folder)
                DropdownMenuItem(
                    value: f.id,
                    child: Text('${'　' * depthOf(f)}${f.name}')),
          ],
          onChanged: (v) => setSt(() => target = v ?? ''),
        ),
      ),
      actions: [
        darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
        darkTextBtn('移动', () {
          moved = true;
          Navigator.pop(context);
        }, color: kGreen),
      ],
    );
    if (!moved) return;
    if (target == m.folder) return;
    await st.store.moveCollection(m.id, target);
    await st.refreshCollections();
    if (context.mounted) {
      toast(context, '已移动到${target.isEmpty ? '根目录' : '「${_folderName(target)}」'}');
    }
  }

  String _folderName(String fid) {
    for (final f in st.folders) {
      if (f.id == fid) return f.name;
    }
    return '根目录';
  }

  Future<void> _renameFolder(Folder f) async {
    final ctl = TextEditingController(text: f.name);
    await showDarkDialog(context,
        title: '重命名文件夹',
        content: TextField(
            controller: ctl,
            autofocus: true,
            onSubmitted: (_) => Navigator.pop(context),
            style: const TextStyle(color: kTextMain),
            decoration: dec('文件夹名称')),
        actions: [
          darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
          darkTextBtn('保存', () async {
            await st.store.renameFolder(
                f.id, ctl.text.trim().isEmpty ? f.name : ctl.text.trim());
            Navigator.pop(context);
            await st.refreshCollections();
          }, color: kGreen),
        ]);
  }

  /// 删除文件夹：**必须确认**。内容不会丢（子项与工程上移到父级），
  /// 但文案要说清去向，否则用户不敢删。
  Future<void> _confirmDeleteFolder(Folder f) async {
    final n = st.collections.where((m) => m.folder == f.id).length;
    await showDarkDialog(context,
        title: '删除文件夹「${f.name}」',
        content: Text(
            n > 0
                ? '里面 $n 个工程将移到上一级，不会被删除。确定删除该文件夹？'
                : '该文件夹是空的，确定删除？',
            style:
                const TextStyle(color: kTextMain, fontSize: TokFs.body)),
        actions: [
          darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
          darkTextBtn('删除', () async {
            Navigator.pop(context);
            await st.store.deleteFolder(f.id);
            if (st.folderId == f.id) st.folderId = '';
            await st.refreshCollections();
            st.refreshUi();
            toast(context, '已删除文件夹「${f.name}」'
                '${n > 0 ? '（$n 个工程已移到上一级）' : ''}');
          }, color: kDanger),
        ]);
  }

  // ---- 工程列表 ----

  /// 当前可见（受搜索/文件夹筛选）的工程列表——列表构建与 Shift 范围选择共用。
  List<CollectionMeta> _filteredItems() {
    final q = _query.toLowerCase();
    return st.collections.where((m) {
      if (q.isNotEmpty) {
        return m.name.toLowerCase().contains(q) ||
            m.desc.toLowerCase().contains(q);
      }
      final fid = _currentFolderId;
      if (fid.isEmpty) return m.folder.isEmpty;
      return m.folder == fid;
    }).toList();
  }

  /// 选中集合对应的工程（按当前可见列表过滤掉已删除项）。
  List<CollectionMeta> _selectedMetas() =>
      st.collections.where((m) => _selected.contains(m.id)).toList();

  /// 点击工程项：普通点击=清空多选并打开；Ctrl/Cmd=切换；Shift=范围选择。
  Future<void> _onItemTap(CollectionMeta m) async {
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    final shift = kb.isShiftPressed;

    if (ctrl) {
      setState(() {
        if (!_selected.remove(m.id)) _selected.add(m.id);
        _anchor = m.id;
      });
      return;
    }
    if (shift && _anchor.isNotEmpty) {
      final ids = _filteredItems().map((e) => e.id).toList();
      final a = ids.indexOf(_anchor);
      final b = ids.indexOf(m.id);
      if (a >= 0 && b >= 0) {
        final lo = a < b ? a : b;
        final hi = a < b ? b : a;
        setState(() => _selected.addAll(ids.sublist(lo, hi + 1)));
        return;
      }
    }
    // 普通点击：清空多选，打开工程。
    if (_selected.isNotEmpty) setState(() => _selected.clear());
    _anchor = m.id;
    await st.openCollection(m);
    if (mounted) toast(context, '已打开「${m.name}」，可继续编辑');
  }

  Widget _collectionList(BuildContext context) {
    final items = _filteredItems();
    final selectedCount = _selectedMetas().length;

    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Text(
            _query.isNotEmpty ? '没有匹配「$_query」的工程' : '本文件夹暂无收藏',
            textAlign: TextAlign.center,
            style: const TextStyle(color: kTextSub, fontSize: TokFs.body, height: 1.6),
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 0),
          child: selectedCount > 0
              ? Row(children: [
                  Text('已选 $selectedCount 项',
                      style: const TextStyle(color: kAccent, fontSize: TokFs.caption)),
                  const Spacer(),
                  TextButton(
                    onPressed: _batchExportSelected,
                    child: const Text('批量导出 DXF',
                        style: TextStyle(color: kAccent, fontSize: TokFs.small)),
                  ),
                  TextButton(
                    onPressed: _confirmDeleteSelected,
                    child: const Text('删除所选',
                        style: TextStyle(color: kDanger, fontSize: TokFs.small)),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _selected.clear()),
                    child: const Text('清除',
                        style: TextStyle(color: kTextSub, fontSize: TokFs.small)),
                  ),
                ])
              : Row(children: [
                  Text('共 ${items.length} 项',
                      style: const TextStyle(color: kTextSub, fontSize: TokFs.caption)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _addFolder(),
                    child: const Text('新建文件夹',
                        style: TextStyle(color: kAccent, fontSize: TokFs.small)),
                  ),
                ]),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: items.length,
            itemBuilder: (ctx, i) => _item(ctx, items[i]),
          ),
        ),
      ],
    );
  }

  /// 批量导出选中工程（T21）：每个工程各存于 `导出/批量/<工程名>/`。
  Future<void> _batchExportSelected() async {
    final targets = _selectedMetas();
    if (targets.isEmpty) {
      toast(context, '请先选择要导出的工程（Ctrl/Shift 多选）');
      return;
    }
    await batchExportDxf(context, st, targets);
  }

  /// 批量删除选中工程：Ctrl/Shift 多选之后一把删，逐个右键太折磨。
  /// 删除不可撤销（云端软删除除外），必须确认并把名单亮出来。
  Future<void> _confirmDeleteSelected() async {
    final targets = _selectedMetas();
    if (targets.isEmpty) {
      toast(context, '请先选择要删除的工程（Ctrl/Shift 多选）');
      return;
    }
    final names = targets.map((e) => '「${e.name}」').join('、');
    await showDarkDialog(context,
        title: '删除 ${targets.length} 个工程',
        content: Text('确定删除 $names？\n删除后不可恢复（已开云同步的工程可在其他设备确认后彻底移除）。',
            style: const TextStyle(color: kTextMain, fontSize: TokFs.body)),
        actions: [
          darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
          darkTextBtn('删除', () async {
            Navigator.pop(context);
            for (final m in targets) {
              await st.deleteCollection(m.id);
            }
            setState(() => _selected.clear());
            toast(context, '已删除 ${targets.length} 个工程');
          }, color: kDanger),
        ]);
  }

  Widget _item(BuildContext context, CollectionMeta m) {
    final visible = st.visibleCids.contains(m.id);
    final selected = _selected.contains(m.id);
    // 同步状态取自可空快照（未接入同步 → 仅本地）；不读任何可能抛异常的 getter。
    final sync = context.watch<SyncController?>();
    final status = sync?.statusFor(m.id) ?? SyncStatus.localOnly;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: selected ? kAccent.withValues(alpha: 0.14) : TokC.card,
        borderRadius: BorderRadius.circular(TokR.m),
        border: Border.all(
            color: selected
                ? kAccent
                : (visible
                    ? kAccent.withValues(alpha: 0.6)
                    : Colors.transparent)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(TokR.m),
        onTap: () => _onItemTap(m),
        // 右键 = ⋮ 菜单（桌面惯例）。此前删除/重命名只藏在 ⋮ 里，
        // 用户反馈"没有删除功能"实为入口不可发现。
        onSecondaryTapUp: (d) => _showItemMenu(m, d.globalPosition),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 7, 2, 7),
          child: Row(
            children: [
              if (selected)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.check_circle,
                      size: 14, color: kAccent),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.name.isEmpty ? '未命名' : m.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: kTextMain, fontSize: TokFs.body)),
                    const SizedBox(height: 2),
                    Row(children: [
                      _tag(_kindTag(m), _kindColor(m)),
                      const SizedBox(width: 6),
                      Text('${m.count} 点',
                          style: const TextStyle(
                              color: kTextSub, fontSize: TokFs.micro)),
                      const SizedBox(width: 6),
                      SyncBadge(status: status),
                    ]),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: visible ? '从地图隐藏' : '叠加显示到地图',
                onPressed: () => st.toggleVisible(m.id),
                icon: Icon(visible ? Icons.visibility : Icons.visibility_off,
                    color: visible ? kAccent : kTextSub, size: 18),
              ),
              PopupMenuButton<String>(
                tooltip: '更多操作',
                icon: const Icon(Icons.more_vert, color: kTextSub, size: 18),
                color: kPanelBg,
                onSelected: (v) => _onAction(context, m, v),
                itemBuilder: (ctx) => _itemMenuEntries,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _kindTag(CollectionMeta m) => m.kind == 'track'
      ? '轨迹'
      : m.kind == 'data'
          ? '数据'
          : m.editMode == 'completion'
              ? '竣工'
              : '设计';

  Color _kindColor(CollectionMeta m) => m.editMode == 'completion'
      ? TokC.warn
      : m.kind == 'track'
          ? const Color(0xFFFFD54F)
          : const Color(0xFF81C784);

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(TokR.s),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: TokFs.micro)),
      );

  /// 工程项动作清单——⋮ 按钮与**右键菜单**共用同一份，两边永远不会长得不一样。
  List<PopupMenuEntry<String>> get _itemMenuEntries => const [
        PopupMenuItem(value: 'sync', height: 34, child: Text('同步该工程')),
        PopupMenuItem(value: 'history', height: 34, child: Text('历史版本')),
        PopupMenuItem(value: 'export', height: 34, child: Text('导出成果')),
        PopupMenuItem(
            value: 'batch_export',
            height: 34,
            child: Text('批量导出 DXF（选中项）')),
        PopupMenuItem(value: 'archive', height: 34, child: Text('竣工资料成册')),
        PopupMenuItem(value: 'rename', height: 34, child: Text('重命名')),
        PopupMenuItem(value: 'move', height: 34, child: Text('移动到文件夹')),
        PopupMenuItem(value: 'delete', height: 34, child: Text('删除')),
      ];

  /// 右键工程项：在指针位置弹动作菜单（复用 [showMenu]，与文件夹菜单同一套交互）。
  Future<void> _showItemMenu(CollectionMeta m, Offset pos) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final sel = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
          Rect.fromPoints(pos, pos), Offset.zero & overlay.size),
      color: kPanelBg,
      items: _itemMenuEntries,
    );
    if (sel == null || !mounted) return;
    await _onAction(context, m, sel);
  }

  Future<void> _onAction(
      BuildContext context, CollectionMeta m, String action) async {
    switch (action) {
      case 'sync':
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
        break;
      case 'history':
        // 版本历史与恢复（T20）。未配置令牌时对话框内给中文提示，不崩。
        await showVersionHistoryDialog(
            context, context.read<SyncController?>(), m.id, m.name);
        break;
      case 'export':
        final ls = await st.store.loadCollection(m.id);
        if (context.mounted)
          showExportDialog(context, ls, m.name, segPrefix: st.segPrefix);
        break;
      case 'batch_export':
        // 批量导出：优先导出多选集合；无多选时退化为「仅本项」。
        final targets = _selectedMetas();
        await batchExportDxf(
            context, st, targets.isEmpty ? <CollectionMeta>[m] : targets);
        break;
      case 'archive':
        if (context.mounted) await showArchiveBookDialog(context, st);
        break;
      case 'rename':
        final ctl = TextEditingController(text: m.name);
        if (!context.mounted) return;
        await showDarkDialog(context,
            title: '重命名',
            content: TextField(
                controller: ctl,
                autofocus: true,
                style: const TextStyle(color: kTextMain),
                decoration: dec('项目名称')),
            actions: [
              darkTextBtn('取消', () => Navigator.pop(context),
                  color: kTextSub),
              darkTextBtn('保存', () async {
                await st.store.renameCollection(m.id, ctl.text.trim());
                Navigator.pop(context);
                await st.refreshCollections();
              }),
            ]);
        break;
      case 'move':
        if (!context.mounted) return;
        await _moveToFolderDialog(context, m);
        break;
      case 'delete':
        if (!context.mounted) return;
        await showDarkDialog(context,
            title: '删除收藏',
            content: Text('确定删除「${m.name}」（${m.count} 点）？',
                style: const TextStyle(color: kTextMain, fontSize: TokFs.body)),
            actions: [
              darkTextBtn('取消', () => Navigator.pop(context),
                  color: kTextSub),
              darkTextBtn('删除', () async {
                // 统一入口：清理可见集合 + 刷新 + 通知同步器（服务端软删除）。
                await st.deleteCollection(m.id);
                Navigator.pop(context);
                st.refreshUi();
              }, color: TokC.danger),
            ]);
        break;
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

  // ================= 本工程（草稿）段落 / 点位表 =================

  /// 底部「本工程」区：默认收起（一行标题），展开后固定高度内滚动。
  ///
  /// 为什么固定高度而不是跟着内容长：左栏同时还要放工程列表与导入区，
  /// 段落表若自由增长会把上面两块挤没。固定 264 高刚好显示 5~6 行段落，
  /// 再用内部滚动承载长线路。
  Widget _draftSection() {
    final n = st.labels.length;
    final segs = st.segments;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: TokC.divider)),
      ),
      child: Column(
        children: [
          _draftHeader(n, segs.length),
          if (_draftOpen)
            SizedBox(
              height: 264,
              child: n == 0
                  ? _draftEmpty()
                  : Column(
                      children: [
                        _draftTabs(n, segs.length),
                        Expanded(
                          child: _segView ? _segList(segs) : _labelList(),
                        ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }

  Widget _draftHeader(int nPoints, int nSegs) {
    return InkWell(
      onTap: () => setState(() => _draftOpen = !_draftOpen),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        child: Row(
          children: [
            Icon(_draftOpen ? Icons.expand_more : Icons.chevron_right,
                size: 16, color: kTextSub),
            const SizedBox(width: 4),
            const Expanded(
              child: Text('本工程',
                  style: TextStyle(
                      color: kTextMain,
                      fontSize: TokFs.body,
                      fontWeight: FontWeight.w500)),
            ),
            Text('$nPoints 点 · $nSegs 段',
                style: const TextStyle(color: kTextHint, fontSize: TokFs.micro)),
          ],
        ),
      ),
    );
  }

  Widget _draftTabs(int nPoints, int nSegs) {
    Widget tab(String text, bool active, VoidCallback onTap) => Expanded(
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                      color: active ? kAccent : Colors.transparent, width: 2),
                ),
              ),
              child: Text(text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: active ? kAccent : kTextSub, fontSize: TokFs.small)),
            ),
          ),
        );
    return Row(
      children: [
        tab('段落 $nSegs', _segView, () => setState(() => _segView = true)),
        tab('点位 $nPoints', !_segView, () => setState(() => _segView = false)),
      ],
    );
  }

  Widget _draftEmpty() => const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('还没有点。\n在地图上打点并连线后，这里会列出全线段落，可直接改段标。',
              textAlign: TextAlign.center,
              style: TextStyle(color: kTextHint, fontSize: TokFs.caption, height: 1.6)),
        ),
      );

  String _lblName(MapLabel l) =>
      l.name.trim().isNotEmpty ? l.name.trim() : l.type.name;

  Widget _segList(List<RouteSegment> segs) {
    if (segs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('还没有连成线的段落（同一线组至少两个点才会成段）。',
              textAlign: TextAlign.center,
              style: TextStyle(color: kTextHint, fontSize: TokFs.caption, height: 1.6)),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: segs.length,
      itemBuilder: (ctx, i) => _segRow(segs[i]),
    );
  }

  Widget _segRow(RouteSegment s) {
    final editing = _editingId == s.to.id;
    return InkWell(
      // 点在编辑框上时不要抢走点击（否则点一下输入框就跳地图了）。
      onTap: editing ? null : () => widget.onLocate?.call(s.to),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: TokC.kind(s.kind),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text('#${s.segIndex}',
                    style: const TextStyle(color: kTextHint, fontSize: TokFs.micro)),
                const SizedBox(width: 5),
                Expanded(
                  child: Text('${_lblName(s.from)} → ${_lblName(s.to)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: kTextMain, fontSize: TokFs.small)),
                ),
                Text('${GeoUtil.segDistText(s.lengthM)}m',
                    style: const TextStyle(color: kTextSub, fontSize: TokFs.micro)),
              ],
            ),
            const SizedBox(height: 3),
            if (editing)
              _segEditor(s)
            else
              Row(
                children: [
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      onTap: () => _beginEdit(s.to),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: s.to.distLabel.trim().isEmpty
                              ? Colors.transparent
                              : TokC.accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(TokR.s),
                          border: Border.all(
                            color: s.to.distLabel.trim().isEmpty
                                ? TokC.divider
                                : TokC.accent.withValues(alpha: 0.55),
                            width: 0.5,
                          ),
                        ),
                        child: Text(
                          s.text.isEmpty ? '（未标）' : s.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: s.to.distLabel.trim().isEmpty
                                  ? kTextSub
                                  : kAccent,
                              fontSize: TokFs.small),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.edit, size: 12, color: kTextHint),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// 段标就地编辑：输入框 + 敷设方式前缀快捷键 + 清除。
  ///
  /// 前缀 chip 用工程习惯的简称（架/埋/管），点一下就把前缀套到已有数字前面，
  /// 没有数字时自动补上本段实测距离——这就是"42 → 埋42"一步到位。
  ///
  /// **为什么整块要套 [TextFieldTapRegion]**：输入框上的 `onTapOutside` 会在
  /// 指针按下时就提交并关闭编辑态。若不加这层分组，用户点「埋」chip 会被当成
  /// "点到框外"——先提交半截文字、编辑器随即消失，chip 永远点不中。把它标成
  /// 输入框的**同组区域**后，这排操作才算"框内点击"。
  Widget _segEditor(RouteSegment s) {
    return TextFieldTapRegion(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: TextField(
              key: kSegLabelEditorKey,
              controller: _segCtl,
              focusNode: _segFocus,
              style: const TextStyle(color: kTextMain, fontSize: TokFs.small),
              decoration: dec('如 埋42.5，留空=按敷设方式自动'),
              onSubmitted: (_) => _commitEdit(s.to),
              onTapOutside: (_) => _commitEdit(s.to),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final p in const ['架', '埋', '管'])
                  _chip(p, () {
                    final m = RegExp(r'[0-9][0-9.]*').firstMatch(_segCtl.text);
                    _segCtl.text =
                        p + (m?.group(0) ?? GeoUtil.segDistText(s.lengthM));
                    _segCtl.selection = TextSelection(
                        baseOffset: 0, extentOffset: _segCtl.text.length);
                  }, color: kTextMain),
                _chip('清除', () => _segCtl.text = '', color: kTextSub),
                _chip('确定', () => _commitEdit(s.to),
                    bg: kAccent, color: Colors.black),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 段标编辑器里的小按钮（前缀 chip / 清除 / 确定）。
  Widget _chip(String label, VoidCallback onTap,
      {Color? bg, Color color = kTextMain}) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: bg ?? TokC.field,
          borderRadius: BorderRadius.circular(TokR.s),
        ),
        child: Text(label, style: TextStyle(color: color, fontSize: TokFs.caption)),
      ),
    );
  }

  Widget _labelList() {
    final ls = st.labels;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: ls.length,
      itemBuilder: (ctx, i) {
        final l = ls[i];
        return InkWell(
          onTap: () => widget.onLocate?.call(l),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
            child: Row(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: l.type.color,
                    borderRadius: BorderRadius.circular(
                        l.type.shape == 'box' ? 3 : 999),
                  ),
                  child: Text(
                      l.type.symbol.isNotEmpty
                          ? l.type.symbol
                          : _lblName(l).substring(0, 1),
                      style: const TextStyle(
                          color: Colors.white, fontSize: TokFs.micro, height: 1.0)),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_lblName(l),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: kTextMain, fontSize: TokFs.small)),
                ),
                Text('#${l.seq}',
                    style: const TextStyle(color: kTextHint, fontSize: TokFs.micro)),
              ],
            ),
          ),
        );
      },
    );
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
                  color: hot
                      ? kAccent.withValues(alpha: 0.12)
                      : TokC.field,
                  borderRadius: BorderRadius.circular(TokR.m),
                  border: Border.all(
                      color: hot ? kAccent : TokC.divider,
                      width: 1,
                      style: BorderStyle.solid)),
              child: const Text('点击导入文件，或拖入窗口\n（.ovimap 工程 / .geojson 底图）',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kTextSub, fontSize: TokFs.micro, height: 1.4)),
            ),
          );
        },
      ),
    );
  }
}
