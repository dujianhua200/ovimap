import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/fav_tree_controller.dart';
import '../design_tokens.dart';
import '../dialogs.dart';

/// 收藏树拖拽（桌面/移动共用）。
///
/// - 整行 DragTarget 热区（审计问题 5：告别 30px 热区）；
/// - 边缘自动滚动 + 悬停文件夹 800ms 自动展开（审计问题 4）；
/// - 多选时整组跟随（审计问题 6）：行在 build 时按 `controller.selected`
///   计算 payload（`onDragStarted` 时 selection 已是最新）；
/// - 拒绝投放给出原因（审计问题 9 的一部分：失败不再静默）。

/// 拖拽载荷：被拖的节点 id 列表（多选 = 整组）。
class FavDragPayload {
  final List<String> nodeIds;
  const FavDragPayload(this.nodeIds);
}

/// 拖拽进行中标记：行级 Draggable 在 onDragStarted / onDragEnd /
/// onDraggableCanceled 里维护；[FavAutoScroller] 监听它来决定是否显示
/// 边缘滚动热区。
final ValueNotifier<bool> favDragInProgress = ValueNotifier<bool>(false);

/// 同步预检（供 DragTarget.onWillAcceptWithDetails 做即时视觉反馈）。
///
/// null = 可放；返回字符串 = 拒绝原因。
String? favDropCheckSync(
    FavTreeController c, List<String> ids, String targetFolderId) {
  for (final id in ids) {
    final node = c.find(id);
    if (node == null) return '条目已不存在，请刷新后重试';
    if (node.isFolder) {
      if (id == targetFolderId) return '不能把文件夹拖到自己身上';
      if (c.wouldCycle(id, targetFolderId)) return '不能拖入自己的子文件夹';
    } else if (node.isProject) {
      if (node.pid == targetFolderId) return '「${node.name}」已在该文件夹中';
    } else if (node.isMark) {
      final proj = c.find(node.labelCid ?? '');
      if (proj != null && proj.pid == targetFolderId) {
        return '标记「${node.name}」已在该文件夹中';
      }
    } else if (node.isChain) {
      final proj = c.find(node.chainCid ?? '');
      if (proj != null && proj.pid == targetFolderId) {
        return '该线组已在该文件夹中';
      }
    }
  }
  return null;
}

/// 异步版投放预检（签名按 Phase 2 任务书；目前检查全是内存操作）。
Future<String?> favDropCheck(
        FavTreeController c, List<String> ids, String targetFolderId) async =>
    favDropCheckSync(c, ids, targetFolderId);

/// 执行投放：先预检，不通过 / 移动失败都弹 SnackBar 说明原因。
Future<void> doFavDrop(BuildContext context, FavTreeController c,
    FavDragPayload payload, String targetFolderId) async {
  final reason = favDropCheckSync(c, payload.nodeIds, targetFolderId);
  void snack(String msg) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  if (reason != null) {
    snack('不能投放：$reason');
    return;
  }
  var okCount = 0;
  for (final id in payload.nodeIds) {
    final node = c.find(id);
    if (node == null) continue;
    var ok = false;
    try {
      ok = await c.moveToFolder(node, targetFolderId);
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      snack('移动「${node.name}」失败');
    } else {
      okCount++;
    }
  }
  if (okCount > 0) {
    snack(okCount == 1 ? '已移动 1 项' : '已移动 $okCount 项');
  }
}

/// 文件夹整行投放区：整行都是热区；悬停 800ms 自动展开；预检不通过时
/// 显示红色描边并在投放时给出原因。
class FavFolderDrop extends StatefulWidget {
  const FavFolderDrop({
    super.key,
    required this.controller,
    required this.folderId, // '' = 收藏夹根
    required this.child,
    this.onHoverExpand,
  });

  final FavTreeController controller;
  final String folderId;
  final Widget child;

  /// 悬停 800ms 后的回调（树用它展开该文件夹）。
  final VoidCallback? onHoverExpand;

  @override
  State<FavFolderDrop> createState() => _FavFolderDropState();
}

class _FavFolderDropState extends State<FavFolderDrop> {
  Timer? _hoverTimer;

  void _cancelHover() {
    _hoverTimer?.cancel();
    _hoverTimer = null;
  }

  @override
  void dispose() {
    _cancelHover();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<FavDragPayload>(
      onWillAcceptWithDetails: (d) =>
          favDropCheckSync(
              widget.controller, d.data.nodeIds, widget.folderId) ==
          null,
      onMove: (_) {
        if (widget.onHoverExpand != null && _hoverTimer == null) {
          _hoverTimer = Timer(const Duration(milliseconds: 800), () {
            _hoverTimer = null;
            widget.onHoverExpand!();
          });
        }
      },
      onLeave: (_) => _cancelHover(),
      onAcceptWithDetails: (d) {
        _cancelHover();
        doFavDrop(context, widget.controller, d.data, widget.folderId);
      },
      builder: (ctx, candidate, rejected) => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(TokR.s),
          border: candidate.isNotEmpty
              ? Border.all(color: kAccent, width: 1.5)
              : rejected.isNotEmpty
                  ? Border.all(
                      color: kDanger.withValues(alpha: 0.7), width: 1.5)
                  : null,
        ),
        child: widget.child,
      ),
    );
  }
}

/// 拖拽边缘自动滚动容器（桌面/移动共用；移动线直接用）。
///
/// 拖拽进行中（[favDragInProgress]）时在上下边缘各显示 56px 热区，
/// 指针悬停即按方向滚动 [scrollController]。
class FavAutoScroller extends StatelessWidget {
  const FavAutoScroller(
      {super.key, required this.scrollController, required this.child});

  final ScrollController scrollController;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: favDragInProgress,
      builder: (ctx, dragging, _) => Stack(
        children: [
          SingleChildScrollView(
            controller: scrollController,
            child: child,
          ),
          if (dragging) ...[
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 56,
              child: _FavEdgeZone(
                  controller: scrollController, direction: -1),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: 56,
              child: _FavEdgeZone(
                  controller: scrollController, direction: 1),
            ),
          ],
        ],
      ),
    );
  }
}

class _FavEdgeZone extends StatefulWidget {
  const _FavEdgeZone({required this.controller, required this.direction});

  final ScrollController controller;

  /// -1 = 向上滚，1 = 向下滚。
  final int direction;

  @override
  State<_FavEdgeZone> createState() => _FavEdgeZoneState();
}

class _FavEdgeZoneState extends State<_FavEdgeZone> {
  Timer? _timer;

  void _start() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final c = widget.controller;
      if (!c.hasClients) return;
      final next = (c.offset + widget.direction * 24)
          .clamp(0.0, c.position.maxScrollExtent);
      c.jumpTo(next);
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<FavDragPayload>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (_) => _start(),
      onLeave: (_) => _stop(),
      onAcceptWithDetails: (_) => _stop(),
      builder: (ctx, candidate, _) => Container(
        decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: widget.direction < 0
                  ? Alignment.topCenter
                  : Alignment.bottomCenter,
              end: widget.direction < 0
                  ? Alignment.bottomCenter
                  : Alignment.topCenter,
              colors: [
                kAccent.withValues(
                    alpha: candidate.isNotEmpty ? 0.22 : 0.10),
                Colors.transparent,
              ],
            ),
          ),
          child: Icon(
            widget.direction < 0
                ? Icons.keyboard_arrow_up
                : Icons.keyboard_arrow_down,
            color:
                kAccent.withValues(alpha: candidate.isNotEmpty ? 0.9 : 0.4),
          ),
      ),
    );
  }
}
