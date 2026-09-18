import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/store.dart';
import '../../state/app_state.dart';
import '../../sync/sync_controller.dart';
import '../../sync/sync_models.dart';
import '../dialogs.dart';
import '../export_center.dart';
import '../sync/sync_panel.dart';
import 'batch_export.dart';

/// 桌面左栏（架构文档 §3.2 / T09）。
///
/// 内容自上而下：标题 + 新建工程 → 搜索框 → 文件夹树 → 工程列表（每项带
/// **同步徽标** ✓/↑/⚠/●；支持 **Ctrl/Shift 多选** → 右键「批量导出 DXF」）→
/// 底部「导入区」（点击选文件 / 应用内拖拽 → `.ovimap`/`.geojson` 分派，T21）。
class LeftPanel extends StatefulWidget {
  const LeftPanel({
    super.key,
    required this.st,
    this.searchFocus,
    required this.onNewProject,
  });

  final AppState st;
  final FocusNode? searchFocus;

  /// 新建工程（清空草稿进入空白编辑态）。
  final VoidCallback onNewProject;

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

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF141920),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          _searchBar(),
          const Divider(height: 1, color: Colors.white12),
          _folderTree(),
          const Divider(height: 1, color: Colors.white12),
          Expanded(child: _collectionList(context)),
          _dropZone(context),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
      child: Row(
        children: [
          const Expanded(
            child: Text('工程 / 收藏',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '新建工程',
            onPressed: widget.onNewProject,
            icon: const Icon(Icons.add, color: kAccent, size: 20),
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
        style: const TextStyle(color: kTextMain, fontSize: 13),
        decoration: dec('搜索工程名/备注（跨文件夹）').copyWith(
          prefixIcon: const Icon(Icons.search, color: kTextSub, size: 18),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    );
  }

  // ---- 文件夹树 ----

  Widget _folderTree() {
    final rows = <Widget>[];
    void add(Folder f, int depth) {
      rows.add(_folderRow(f, depth));
      for (final c in st.folders) {
        if (c.id.isNotEmpty && c.parentId == f.id) add(c, depth + 1);
      }
    }

    add(const Folder('', '默认'), 0);
    for (final f in st.folders) {
      if (f.id.isNotEmpty && f.parentId.isEmpty) add(f, 0);
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 168),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
      ),
    );
  }

  Widget _folderRow(Folder f, int depth) {
    final selected = st.folderId == f.id;
    return InkWell(
      onTap: () {
        st.folderId = f.id;
        st.refreshUi();
      },
      onLongPress: f.id.isEmpty ? null : () => _folderMenu(f),
      child: Container(
        height: 30,
        padding: EdgeInsets.only(left: 12 + depth * 14.0, right: 8),
        color: selected ? kAccent.withValues(alpha: 0.18) : null,
        child: Row(
          children: [
            Icon(f.id.isEmpty ? Icons.folder_open : Icons.folder,
                size: 15, color: selected ? kAccent : kTextSub),
            const SizedBox(width: 6),
            Expanded(
              child: Text(f.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: selected ? kAccent : kTextMain, fontSize: 12.5)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addFolder() async {
    final ctl = TextEditingController();
    await showDarkDialog(context,
        title: '新建文件夹',
        content: TextField(
            controller: ctl,
            autofocus: true,
            style: const TextStyle(color: kTextMain),
            decoration: dec('文件夹名称')),
        actions: [
          darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
          darkTextBtn('创建', () async {
            final f = await st.store.addFolder(
                ctl.text.trim(), st.folderId.isEmpty ? '' : st.folderId);
            Navigator.pop(context);
            await st.refreshCollections();
            st.folderId = f.id;
            st.refreshUi();
          }),
        ]);
  }

  Future<void> _folderMenu(Folder f) async {
    await showDarkDialog(context, title: '文件夹：${f.name}', actions: [
      darkTextBtn('新建子文件夹', () async {
        Navigator.pop(context);
        st.folderId = f.id;
        await _addFolder();
      }),
      darkTextBtn('重命名', () async {
        Navigator.pop(context);
        final ctl = TextEditingController(text: f.name);
        await showDarkDialog(context,
            title: '重命名文件夹',
            content: TextField(
                controller: ctl,
                autofocus: true,
                style: const TextStyle(color: kTextMain),
                decoration: dec('文件夹名称')),
            actions: [
              darkTextBtn('取消', () => Navigator.pop(context),
                  color: kTextSub),
              darkTextBtn('保存', () async {
                await st.store.renameFolder(
                    f.id, ctl.text.trim().isEmpty ? f.name : ctl.text.trim());
                Navigator.pop(context);
                await st.refreshCollections();
              }),
            ]);
      }),
      darkTextBtn('删除', () async {
        Navigator.pop(context);
        await st.store.deleteFolder(f.id);
        if (st.folderId == f.id) st.folderId = '';
        await st.refreshCollections();
        st.refreshUi();
      }, color: const Color(0xFFFF5252)),
      darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
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
      if (st.folderId.isEmpty) return m.folder.isEmpty;
      return m.folder == st.folderId;
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
            style: const TextStyle(color: kTextSub, fontSize: 12.5, height: 1.6),
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
                      style: const TextStyle(color: kAccent, fontSize: 11)),
                  const Spacer(),
                  TextButton(
                    onPressed: _batchExportSelected,
                    child: const Text('批量导出 DXF',
                        style: TextStyle(color: kAccent, fontSize: 11.5)),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _selected.clear()),
                    child: const Text('清除',
                        style: TextStyle(color: kTextSub, fontSize: 11.5)),
                  ),
                ])
              : Row(children: [
                  Text('共 ${items.length} 项',
                      style: const TextStyle(color: kTextSub, fontSize: 11)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _addFolder(),
                    child: const Text('新建文件夹',
                        style: TextStyle(color: kAccent, fontSize: 11.5)),
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

  Widget _item(BuildContext context, CollectionMeta m) {
    final visible = st.visibleCids.contains(m.id);
    final selected = _selected.contains(m.id);
    // 同步状态取自可空快照（未接入同步 → 仅本地）；不读任何可能抛异常的 getter。
    final sync = context.watch<SyncController?>();
    final status = sync?.statusFor(m.id) ?? SyncStatus.localOnly;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: selected ? kAccent.withValues(alpha: 0.14) : const Color(0xFF1D242C),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
            color: selected
                ? kAccent
                : (visible
                    ? kAccent.withValues(alpha: 0.6)
                    : Colors.transparent)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => _onItemTap(m),
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
                            color: Colors.white, fontSize: 13)),
                    const SizedBox(height: 2),
                    Row(children: [
                      _tag(_kindTag(m), _kindColor(m)),
                      const SizedBox(width: 6),
                      Text('${m.count} 点',
                          style: const TextStyle(
                              color: kTextSub, fontSize: 10.5)),
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
                itemBuilder: (ctx) => const [
                  PopupMenuItem(value: 'sync', child: Text('同步该工程')),
                  PopupMenuItem(value: 'history', child: Text('历史版本')),
                  PopupMenuItem(value: 'export', child: Text('导出成果')),
                  PopupMenuItem(value: 'batch_export', child: Text('批量导出 DXF（选中项）')),
                  PopupMenuItem(value: 'archive', child: Text('竣工资料成册')),
                  PopupMenuItem(value: 'rename', child: Text('重命名')),
                  PopupMenuItem(value: 'move', child: Text('移动到文件夹')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
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
      ? const Color(0xFFFFB74D)
      : m.kind == 'track'
          ? const Color(0xFFFFD54F)
          : const Color(0xFF81C784);

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 9.5)),
      );

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
        if (context.mounted) showExportDialog(context, ls, m.name);
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
        await showDarkDialog(context, title: '移动到文件夹', actions: [
          for (final f in st.folders)
            darkTextBtn(f.name, () async {
              await st.store.moveCollection(m.id, f.id);
              Navigator.pop(context);
              await st.refreshCollections();
            }),
        ]);
        break;
      case 'delete':
        if (!context.mounted) return;
        await showDarkDialog(context,
            title: '删除收藏',
            content: Text('确定删除「${m.name}」（${m.count} 点）？',
                style: const TextStyle(color: kTextMain, fontSize: 13)),
            actions: [
              darkTextBtn('取消', () => Navigator.pop(context),
                  color: kTextSub),
              darkTextBtn('删除', () async {
                // 统一入口：清理可见集合 + 刷新 + 通知同步器（服务端软删除）。
                await st.deleteCollection(m.id);
                Navigator.pop(context);
                st.refreshUi();
              }, color: const Color(0xFFFF5252)),
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
            borderRadius: BorderRadius.circular(10),
            child: Container(
              height: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: hot
                      ? kAccent.withValues(alpha: 0.12)
                      : const Color(0xFF1A2027),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: hot ? kAccent : Colors.white24,
                      width: 1,
                      style: BorderStyle.solid)),
              child: const Text('点击导入文件，或拖入窗口\n（.ovimap 工程 / .geojson 底图）',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kTextSub, fontSize: 10.5, height: 1.4)),
            ),
          );
        },
      ),
    );
  }
}
