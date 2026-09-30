import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/fav_tree_controller.dart';
import '../desktop/shortcuts.dart';
import '../dialogs.dart';
import 'tree_menus.dart';

/// 收藏树键盘操作共享组件：桌面左栏 [LeftPanel] 与移动抽屉 [FavoritesDrawer]
/// 共用，逻辑只写一遍。
///
/// - F2 → [RenameIntent]：重命名当前选中的单个树节点（裸键，非文本编辑态才
///   注册，规则见 [DesktopShortcuts] 文件头注释「规则 1」—— 与全局快捷键
///   同名，冒泡顺序保证焦点在树内时此处优先）；
/// - Ctrl+A → [SelectAllIntent]：全选控制器索引中的全部节点（folders +
///   projects + 已加载的子节点，走 [FavTreeController.selectAll]）。
///   文本编辑态不注册：搜索框里的 Ctrl+A 仍是"全选文本"。
///
/// [autofocus]：左栏已有外层 autofocus，此处默认 false；移动抽屉打开时
/// 没有焦点，需要传 true 才能让硬件键盘生效。
class TreeKeyHandler extends StatefulWidget {
  const TreeKeyHandler({
    super.key,
    required this.child,
    required this.controller,
    this.autofocus = false,
  });

  final Widget child;
  final FavTreeController controller;
  final bool autofocus;

  @override
  State<TreeKeyHandler> createState() => _TreeKeyHandlerState();
}

class _TreeKeyHandlerState extends State<TreeKeyHandler> {
  /// 当前主焦点是否位于可编辑文本内（决定裸键 / Ctrl+A 是否注册）。
  /// 判定口径与 [DesktopShortcuts] 一致（规则 1 的 rationale）。
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
    _onFocusChanged();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    final editing = _isEditingText();
    if (editing != _editing && mounted) {
      setState(() => _editing = editing);
    }
  }

  static bool _isEditingText() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null || !ctx.mounted) return false;
    if (ctx.widget is EditableText) return true;
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        // 裸键 / 与文本编辑冲突的组合：仅非编辑态注册。
        if (!_editing) ...{
          const SingleActivator(LogicalKeyboardKey.f2):
              const RenameIntent(),
          const SingleActivator(LogicalKeyboardKey.keyA, control: true):
              const SelectAllIntent(),
          const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
              const SelectAllIntent(),
        },
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          RenameIntent: CallbackAction<RenameIntent>(
              onInvoke: (_) =>
                  _run(() => renameTreeSelection(context, widget.controller))),
          SelectAllIntent: CallbackAction<SelectAllIntent>(
              onInvoke: (_) => _run(
                  () => selectAllTreeNodes(widget.controller))),
        },
        child: Focus(autofocus: widget.autofocus, child: widget.child),
      ),
    );
  }

  Object? _run(FutureOr<void> Function() fn) {
    final r = fn();
    if (r is Future) {
      // 重命名是异步对话框：不阻塞按键派发，未捕获异常交由 Flutter 上报。
      r.ignore();
    }
    return null;
  }
}

/// 重命名当前树选择（F2 / 桌面全局 F2 共用入口）。
///
/// - 未选 → 提示先选一项；多选 → toast「请只选中一项」；
/// - 选中 mark/chain → 提示只能重命名文件夹或工程；
/// - folder/project → 走 [renameFavNode]（tree_menus 现有流程：
///   askText + renameFolderUndoable/renameCollectionUndoable）。
Future<void> renameTreeSelection(
    BuildContext context, FavTreeController c) async {
  final ids = c.selected.toList();
  if (ids.length != 1) {
    toast(context, ids.isEmpty ? '先选中一项（点击条目）' : '请只选中一项');
    return;
  }
  final node = c.find(ids.first);
  if (node == null || !context.mounted) {
    if (context.mounted) toast(context, '所选条目已失效');
    return;
  }
  await renameFavNode(context, c, node);
}

/// 全选当前控制器索引中的全部节点（folders + projects + 已加载的子节点）。
void selectAllTreeNodes(FavTreeController c) {
  c.selectAll(c.allIndexedIds);
}
