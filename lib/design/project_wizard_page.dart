/// 工程向导 UI：从模板一键生成目录结构 + 自定义模板管理。
///
/// 桌面（`left_panel` 标题栏）与移动端（`drawer_panel` 标题栏）共用
/// [showProjectWizardDialog]；现有"新建工程 / 新建文件夹"流程原样保留，
/// 向导只是标题栏上多出的一个可选入口，不破坏原有直接新建流程。
library;

import 'package:flutter/material.dart';

import '../state/fav_tree_controller.dart';
import '../ui/design_tokens.dart';
import '../ui/dialogs.dart';
import '../ui/favorites/fav_actions.dart';
import 'project_wizard.dart';

/// 打开工程向导对话框。
///
/// 生成位置取 [FavTreeController.treeSelectedFolderId]（'' = 根目录），
/// 与"新建文件夹"的口径一致；生成后树自动刷新，新建文件夹天然展开。
Future<void> showProjectWizardDialog(
  BuildContext context, {
  required FavTreeController controller,
}) async {
  final store = await WizardTemplateStore.load(controller.store);
  if (!context.mounted) return;
  await showDarkDialog(
    context,
    title: '工程向导 · 从模板新建',
    width: 560,
    content: _WizardDialog(controller: controller, store: store),
  );
}

enum _Mode { select, manage, edit }

class _WizardDialog extends StatefulWidget {
  final FavTreeController controller;
  final WizardTemplateStore store;

  const _WizardDialog({required this.controller, required this.store});

  @override
  State<_WizardDialog> createState() => _WizardDialogState();
}

class _WizardDialogState extends State<_WizardDialog> {
  _Mode _mode = _Mode.select;
  String? _selectedId;
  WizardTemplate? _editing;
  final _nameCtl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  List<WizardTemplate> get _all => widget.store.allTemplates();

  WizardTemplate? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final t in _all) {
      if (t.id == id) return t;
    }
    return null;
  }

  String get _parentName {
    final pid = widget.controller.treeSelectedFolderId;
    if (pid.isEmpty) return '根目录';
    return widget.controller.find(pid)?.name ?? '根目录';
  }

  // ---------- 生成 ----------

  Future<void> _generate() async {
    final t = _selected;
    if (t == null) {
      toast(context, '请先选择一个模板');
      return;
    }
    final plan = buildWizardPlan(t);
    if (plan.isEmpty) {
      toast(context, '模板「${t.name}」是空的，请先添加文件夹或工程');
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await applyTemplate(widget.controller, t,
          parentId: widget.controller.treeSelectedFolderId);
      if (!mounted) return;
      Navigator.pop(context);
      toast(
          context,
          r.ok
              ? '已按模板「${t.name}」创建 ${r.folderIds.length} 个文件夹、${r.projectIds.length} 个工程（可撤销）'
              : '生成失败，请重试');
    } catch (e) {
      if (!mounted) return;
      toast(context, '生成失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- 模板管理 ----------

  void _newTemplate() {
    _nameCtl.text = '';
    setState(() {
      _editing = WizardTemplate(id: WizardTemplate.newId('wt'), name: '');
      _mode = _Mode.edit;
    });
  }

  void _editTemplate(WizardTemplate t) {
    _nameCtl.text = t.name;
    setState(() {
      _editing = t.copyWith(
          items: [for (final i in t.items) i.copyWith()]); // 深拷贝再改
      _mode = _Mode.edit;
    });
  }

  Future<void> _deleteTemplate(WizardTemplate t) async {
    final ok = await askConfirm(context,
        title: '删除模板', content: '确定删除自定义模板「${t.name}」吗？此操作不可撤销。');
    if (!ok) return;
    await widget.store.deleteTemplate(t.id);
    if (!mounted) return;
    if (_selectedId == t.id) _selectedId = null;
    setState(() {});
    toast(context, '已删除模板「${t.name}」');
  }

  Future<void> _saveEditing() async {
    final e = _editing;
    if (e == null) return;
    final t = e.copyWith(name: _nameCtl.text.trim());
    final errs = validateWizardTemplate(t);
    if (errs.isNotEmpty) {
      toast(context, errs.first);
      return;
    }
    try {
      await widget.store.saveTemplate(t);
    } catch (ex) {
      if (!mounted) return;
      toast(context, '保存失败：$ex');
      return;
    }
    if (!mounted) return;
    setState(() {
      _editing = null;
      _mode = _Mode.manage;
    });
    toast(context, '模板「${t.name}」已保存');
  }

  // ---------- 条目编辑 ----------

  void _addItem(String kind) {
    final e = _editing;
    if (e == null) return;
    final folders = [for (final i in e.items) if (i.isFolder) i];
    setState(() {
      _editing = e.copyWith(items: [
        ...e.items,
        if (kind == WizardItemKind.folder)
          WizardItem.folder(
              WizardTemplate.newId('wi'), '新建文件夹')
        else
          WizardItem.project(WizardTemplate.newId('wi'), '新建工程',
              folders.isEmpty ? '' : folders.first.id),
      ]);
    });
  }

  void _updateItem(String id, WizardItem Function(WizardItem) f) {
    final e = _editing;
    if (e == null) return;
    setState(() {
      _editing = e.copyWith(
          items: [for (final i in e.items) if (i.id == id) f(i) else i]);
    });
  }

  Future<void> _renameItem(WizardItem item) async {
    final name = await askText(context,
        title: '重命名${item.isFolder ? '文件夹' : '工程'}', initial: item.name);
    if (name == null) return;
    _updateItem(item.id, (i) => i.copyWith(name: name));
  }

  void _deleteItem(WizardItem item) {
    final e = _editing;
    if (e == null) return;
    setState(() {
      // 删文件夹时，其子条目上移到被删文件夹的父级，结构不断裂。
      _editing = e.copyWith(items: [
        for (final i in e.items)
          if (i.id != item.id)
            i.copyWith(
                parentId:
                    i.parentId == item.id ? item.parentId : i.parentId),
      ]);
    });
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    switch (_mode) {
      case _Mode.manage:
        return _buildManage();
      case _Mode.edit:
        return _buildEdit();
      case _Mode.select:
        return _buildSelect();
    }
  }

  // ----- 选择模板 -----

  Widget _buildSelect() {
    final all = _all;
    _selectedId ??= all.isNotEmpty ? all.first.id : null;
    final t = _selected;
    final plan = t == null ? null : buildWizardPlan(t);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('选择模板，一键生成整套目录结构（空工程）。',
            style: TextStyle(color: kTextSub, fontSize: 12)),
        const SizedBox(height: 8),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _groupTitle('预设模板'),
                for (final tp in WizardTemplate.presets) _templateTile(tp),
                _groupTitle('我的模板'),
                for (final tp in widget.store.customTemplates)
                  _templateTile(tp),
                if (widget.store.customTemplates.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 4),
                    child: Text('暂无自定义模板，可在「管理模板」中新建',
                        style: TextStyle(color: kTextSub, fontSize: 12)),
                  ),
                if (t != null && plan != null) ...[
                  const SizedBox(height: 8),
                  Text(
                      '结构预览：${plan.folderCount} 个文件夹 · ${plan.projectCount} 个工程',
                      style: const TextStyle(
                          color: kTextMain,
                          fontSize: 13,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: TokC.field,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final s in plan.folderSteps) _previewRow(s),
                        for (final s in plan.projectSteps) _previewRow(s),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text('将建在：$_parentName',
            style: const TextStyle(color: kTextSub, fontSize: 12)),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            darkTextBtn('管理模板', () => setState(() => _mode = _Mode.manage),
                color: kTextSub),
            const SizedBox(width: 8),
            darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
            const SizedBox(width: 8),
            darkTextBtn(_busy ? '生成中…' : '生成', _busy ? () {} : _generate,
                color: kGreen),
          ],
        ),
      ],
    );
  }

  Widget _groupTitle(String s) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 2),
        child: Text(s,
            style: const TextStyle(color: kTextSub, fontSize: 11)),
      );

  Widget _templateTile(WizardTemplate tp) {
    final plan = buildWizardPlan(tp);
    final selected = _selectedId == tp.id;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected
            ? Icons.radio_button_checked
            : Icons.radio_button_unchecked,
        color: selected ? kAccent : kTextSub,
        size: 20,
      ),
      title: Text(tp.name,
          style: const TextStyle(color: kTextMain, fontSize: 14)),
      subtitle: Text(
          '${plan.folderCount} 文件夹 · ${plan.projectCount} 工程'
          '${tp.builtIn ? ' · 预设' : ''}',
          style: const TextStyle(color: kTextSub, fontSize: 11)),
      onTap: () => setState(() => _selectedId = tp.id),
    );
  }

  Widget _previewRow(WizardPlanStep s) {
    return Padding(
      padding: EdgeInsets.only(left: s.depth * 18.0, top: 2, bottom: 2),
      child: Row(
        children: [
          Icon(
              s.item.isFolder ? Icons.folder_outlined : Icons.description_outlined,
              size: 15,
              color: s.item.isFolder ? kAccent : kTextSub),
          const SizedBox(width: 6),
          Expanded(
            child: Text(s.item.name,
                style: const TextStyle(color: kTextMain, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  // ----- 管理模板 -----

  Widget _buildManage() {
    final customs = widget.store.customTemplates;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('预设模板为只读；自定义模板可改名、增删文件夹/工程项。',
            style: TextStyle(color: kTextSub, fontSize: 12)),
        const SizedBox(height: 8),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final tp in customs)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(tp.name,
                        style:
                            const TextStyle(color: kTextMain, fontSize: 14)),
                    subtitle: Text(
                        '${buildWizardPlan(tp).folderCount} 文件夹 · ${buildWizardPlan(tp).projectCount} 工程',
                        style:
                            const TextStyle(color: kTextSub, fontSize: 11)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '编辑',
                          icon: const Icon(Icons.edit_outlined,
                              size: 18, color: kAccent),
                          onPressed: () => _editTemplate(tp),
                        ),
                        IconButton(
                          tooltip: '删除',
                          icon: const Icon(Icons.delete_outline,
                              size: 18, color: kDanger),
                          onPressed: () => _deleteTemplate(tp),
                        ),
                      ],
                    ),
                  ),
                if (customs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('暂无自定义模板',
                        style: TextStyle(color: kTextSub, fontSize: 12)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            darkTextBtn('＋ 新建模板', _newTemplate, color: kGreen),
            const Spacer(),
            darkTextBtn('返回', () => setState(() => _mode = _Mode.select),
                color: kTextSub),
          ],
        ),
      ],
    );
  }

  // ----- 编辑模板 -----

  Widget _buildEdit() {
    final e = _editing;
    if (e == null) return const SizedBox.shrink();
    final plan = buildWizardPlan(e);
    final folders = [for (final i in e.items) if (i.isFolder) i];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _nameCtl,
          style: const TextStyle(color: kTextMain, fontSize: 14),
          decoration: dec('模板名称'),
        ),
        const SizedBox(height: 8),
        Text(
            '共 ${plan.folderCount} 个文件夹 · ${plan.projectCount} 个工程（点名称可改名，工程可改所属文件夹）',
            style: const TextStyle(color: kTextSub, fontSize: 11)),
        const SizedBox(height: 4),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final s in plan.folderSteps) _editRow(s, folders),
                for (final s in plan.projectSteps) _editRow(s, folders),
                if (plan.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('空模板：点下方按钮添加文件夹或工程',
                        style: TextStyle(color: kTextSub, fontSize: 12)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            darkTextBtn('＋ 文件夹', () => _addItem(WizardItemKind.folder),
                color: kAccent),
            darkTextBtn('＋ 工程', () => _addItem(WizardItemKind.project),
                color: kAccent),
            const Spacer(),
            darkTextBtn('返回', () => setState(() {
              _editing = null;
              _mode = _Mode.manage;
            }), color: kTextSub),
            const SizedBox(width: 8),
            darkTextBtn('保存', _saveEditing, color: kGreen),
          ],
        ),
      ],
    );
  }

  Widget _editRow(WizardPlanStep s, List<WizardItem> folders) {
    final item = s.item;
    return Padding(
      padding: EdgeInsets.only(left: s.depth * 16.0),
      child: Row(
        children: [
          Icon(
              item.isFolder
                  ? Icons.folder_outlined
                  : Icons.description_outlined,
              size: 16,
              color: item.isFolder ? kAccent : kTextSub),
          const SizedBox(width: 6),
          Expanded(
            child: InkWell(
              onTap: () => _renameItem(item),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(item.name,
                    style: const TextStyle(color: kTextMain, fontSize: 13)),
              ),
            ),
          ),
          if (item.isProject)
            _parentPicker(item, folders)
          else if (folders.length > 1)
            _parentPicker(item, [for (final f in folders) if (f.id != item.id) f],
                allowRoot: true),
          IconButton(
            tooltip: '删除',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 16, color: kTextSub),
            onPressed: () => _deleteItem(item),
          ),
        ],
      ),
    );
  }

  /// 所属父级选择器（工程必选文件夹；文件夹可选根目录）。
  Widget _parentPicker(WizardItem item, List<WizardItem> folders,
      {bool allowRoot = false}) {
    final parentName = item.parentId.isEmpty
        ? '根目录'
        : () {
            for (final f in folders) {
              if (f.id == item.parentId) return f.name;
            }
            return '根目录';
          }();
    return PopupMenuButton<String>(
      tooltip: '所属文件夹',
      padding: EdgeInsets.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: TokC.divider),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(parentName,
                style: const TextStyle(color: kTextSub, fontSize: 11)),
            const Icon(Icons.arrow_drop_down, size: 14, color: kTextSub),
          ],
        ),
      ),
      onSelected: (v) => _updateItem(item.id, (i) => i.copyWith(parentId: v)),
      itemBuilder: (_) => [
        if (allowRoot)
          const PopupMenuItem(value: '', child: Text('根目录')),
        for (final f in folders)
          PopupMenuItem(value: f.id, child: Text(f.name)),
      ],
    );
  }
}
