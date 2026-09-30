import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/fav_node.dart';
import '../../state/app_state.dart';
import '../../state/fav_tree_controller.dart';
import '../../state/undo_stack.dart';
import '../design_tokens.dart';
import '../dialogs.dart';
import 'fav_actions.dart';
import 'trash.dart';
import 'tree_drag.dart';

/// 收藏树多选操作条（桌面/移动共用；移动线直接用）。
///
/// 显示「已选 n 项」；按钮：全选 / 取消 / 移动到 / 改样式 / 删除（进回收站）/ 关闭。
/// 无选中时渲染为空（调用方按需显隐）。
class FavSelectBar extends StatelessWidget {
  const FavSelectBar(
      {super.key, required this.controller, required this.isDesktop});

  final FavTreeController controller;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final st = Provider.of<AppState>(context, listen: false);
    return ListenableBuilder(
      listenable: controller,
      builder: (ctx, _) {
        final n = controller.selected.length;
        if (n > 0) {
          // 选择操作条：布局与基线完全一致（窄屏下加按钮会溢出，见
          // favorites_stack_nav_test；撤销/重做走下方 slim 条）。
          return Container(
            color: kAccent.withValues(alpha: 0.08),
            padding: const EdgeInsets.fromLTRB(12, 2, 6, 2),
            child: Row(children: [
              Text('已选 $n 项',
                  style: const TextStyle(
                      color: kAccent,
                      fontSize: TokFs.caption,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              _mini(ctx, Icons.select_all, '全选', () => _selectAll()),
              _mini(ctx, Icons.deselect, '取消选择',
                  () => controller.clearSelection()),
              _mini(ctx, Icons.drive_file_move_outlined, '移动到',
                  () => _moveTo(ctx)),
              _mini(ctx, Icons.palette_outlined, '改样式',
                  () => _restyle(ctx)),
              _mini(ctx, Icons.delete_outline, '删除（进回收站）',
                  () => _delete(ctx),
                  color: kDanger),
              _mini(ctx, Icons.close, '关闭',
                  () => controller.clearSelection()),
            ]),
          );
        }
        // 无选中：有可撤销/重做时显示 slim 撤销条，否则保持原行为渲染为空。
        // 桌面/移动共用（本组件两端都在用）。
        return ListenableBuilder(
          listenable: st.undoStack,
          builder: (ctx2, _) {
            final gs = st.undoStack;
            if (!gs.canUndo && !gs.canRedo) {
              return const SizedBox.shrink();
            }
            return Container(
              color: kAccent.withValues(alpha: 0.08),
              padding: const EdgeInsets.fromLTRB(12, 2, 6, 2),
              child: Row(children: [
                const Spacer(),
                _undoRedoBtn(ctx2, gs, true),
                _undoRedoBtn(ctx2, gs, false),
              ]),
            );
          },
        );
      },
    );
  }

  /// 撤销/重做按钮：canUndo/canRedo 控制 enable，tooltip 显示最近一条描述。
  Widget _undoRedoBtn(BuildContext context, UndoStack gs, bool isUndo) {
    final can = isUndo ? gs.canUndo : gs.canRedo;
    final desc = isUndo ? gs.lastUndoDescription : gs.lastRedoDescription;
    final tip = isUndo
        ? (can ? '撤销：$desc' : '没有可撤销的操作')
        : (can ? '重做：$desc' : '没有可重做的操作');
    return _mini(
      context,
      isUndo ? Icons.undo : Icons.redo,
      tip,
      can ? () => unawaited(isUndo ? gs.undo() : gs.redo()) : null,
      color: can ? kTextMain : kTextHint,
    );
  }

  Widget _mini(BuildContext context, IconData icon, String tip,
      VoidCallback? onTap,
      {Color color = kTextSub}) {
    final btn = isDesktop
        ? Tooltip(
            message: tip,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Icon(icon, size: 17, color: color),
              ),
            ),
          )
        : IconButton(
            tooltip: tip,
            visualDensity: VisualDensity.compact,
            onPressed: onTap,
            icon: Icon(icon, size: 20, color: color),
          );
    return btn;
  }

  /// 全选：全部文件夹 + 工程（标记需展开工程后单独选）。
  void _selectAll() {
    controller.selectAll([
      for (final f in controller.folders) f.id,
      for (final p in controller.projects) p.id,
    ]);
  }

  List<FavNode> _selectedNodes() => [
        for (final id in controller.selected)
          controller.find(id),
      ].whereType<FavNode>().toList();

  Future<void> _moveTo(BuildContext context) async {
    final nodes = _selectedNodes();
    if (nodes.isEmpty) return;
    final target = await pickFavFolder(context, controller, title: '移动所选到…');
    if (target == null || !context.mounted) return;
    var okCount = 0, skipCount = 0;
    for (final node in nodes) {
      final reason =
          favDropCheckSync(controller, [node.id], target);
      if (reason != null) {
        skipCount++;
        continue;
      }
      if (await controller.moveToFolder(node, target)) {
        okCount++;
      } else {
        skipCount++;
      }
    }
    controller.clearSelection();
    if (context.mounted) {
      toast(context,
          '已移动 $okCount 项${skipCount > 0 ? '，$skipCount 项跳过（无需移动/不允许）' : ''}');
    }
  }

  Future<void> _restyle(BuildContext context) async {
    final projects =
        _selectedNodes().where((n) => n.isProject).toList();
    if (projects.isEmpty) {
      toast(context, '所选条目中没有工程');
      return;
    }
    final picked = await pickProjectStyle(context);
    if (picked == null || !context.mounted) return;
    for (final p in projects) {
      // 经 controller 的 undoable 包裹（内部刷新），可撤销；不直接调 store。
      await controller.setCollectionStyleUndoable(p.id, picked.$1, picked.$2);
    }
    if (context.mounted) {
      toast(context, '已更新 ${projects.length} 个工程的样式');
    }
  }

  Future<void> _delete(BuildContext context) async {
    final st = Provider.of<AppState>(context, listen: false);
    final trash = _trashOf(context, st);
    final nodes = _selectedNodes();
    if (nodes.isEmpty) return;

    // 文件夹级联会带走整棵子树：子树内的工程/标记先剔除，避免重复处理。
    final doomedFolders = <String>{};
    for (final n in nodes) {
      if (!n.isFolder) continue;
      doomedFolders.add(n.id);
      var grew = true;
      while (grew) {
        grew = false;
        for (final f in controller.folders) {
          if (doomedFolders.contains(f.pid) &&
              doomedFolders.add(f.id)) {
            grew = true;
          }
        }
      }
    }
    bool inDoomed(FavNode n) {
      if (n.isFolder) return false; // 文件夹自身走 trashNode
      final pid = n.isProject
          ? n.pid
          : (controller.find(n.labelCid ?? '')?.pid ?? '');
      return doomedFolders.contains(pid);
    }

    final folders = <FavNode>[];
    final projects = <FavNode>[];
    final marks = <FavNode>[];
    for (final n in nodes) {
      if (inDoomed(n)) continue;
      if (n.isFolder) {
        folders.add(n);
      } else if (n.isProject) {
        projects.add(n);
      } else if (n.isMark && n.label != null) {
        marks.add(n);
      } else if (n.isChain) {
        for (final m in await controller.childrenOf(n.id)) {
          if (m.isMark && m.label != null) marks.add(m);
        }
      }
    }
    final parts = <String>[
      if (folders.isNotEmpty) '${folders.length} 个文件夹（含子树）',
      if (projects.isNotEmpty) '${projects.length} 个工程',
      if (marks.isNotEmpty) '${marks.length} 个标记',
    ];
    if (parts.isEmpty) {
      if (!context.mounted) return;
      toast(context, '所选条目已失效');
      controller.clearSelection();
      return;
    }
    if (!context.mounted) return;
    final ok = await askConfirm(context,
        title: '删除所选',
        content:
            '将删除：${parts.join('、')}。\n文件夹与工程进回收站（可还原），标记直接删除。确定？',
        okText: '删除');
    if (!ok || !context.mounted) return;
    for (final f in folders) {
      await trash.trashNode(controller, f);
      if (!context.mounted) return;
    }
    for (final p in projects) {
      await trash.trashNode(controller, p);
      if (!context.mounted) return;
    }
    for (final m in marks) {
      await st.removeOverlayLabel(m.labelCid ?? '', m.label!);
      if (!context.mounted) return;
    }
    controller.clearSelection();
    if (context.mounted) toast(context, '已删除所选（文件夹/工程已进回收站）');
  }
}

TrashStore _trashOf(BuildContext context, AppState st) {
  try {
    return Provider.of<TrashStore>(context, listen: false);
  } catch (_) {
    return TrashStore(
        onChanged: () => st.refreshCollections(), appState: st);
  }
}
