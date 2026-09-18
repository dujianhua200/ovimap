import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../sync/sync_controller.dart';
import '../../sync/sync_models.dart';
import '../dialogs.dart';

/// 桌面工具栏（架构文档 §3.2 / T11，高度 48）。
///
/// 打点 / 连线路 / 测距 / 轨迹 / 定位 / 撤销重做 / 删除选中 / 缩放 / 图源 /
/// 导出 / 同步（占位）/ 左右栏折叠。
class Toolbar extends StatelessWidget {
  const Toolbar({
    super.key,
    required this.st,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onTopo,
    required this.onTrack,
    required this.onLocate,
    required this.onUndo,
    required this.onRedo,
    required this.onDeleteSelection,
    required this.onExport,
    required this.onSync,
    required this.leftCollapsed,
    required this.rightCollapsed,
    required this.onToggleLeft,
    required this.onToggleRight,
    this.sync,
  });

  final AppState st;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onTopo;
  final VoidCallback onTrack;
  final VoidCallback onLocate;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onDeleteSelection;
  final VoidCallback onExport;
  final VoidCallback onSync;
  final bool leftCollapsed;
  final bool rightCollapsed;
  final VoidCallback onToggleLeft;
  final VoidCallback onToggleRight;

  /// 云同步编排器（可为 null：未接入同步的环境 → 圆点显示「仅本地」）。
  final SyncController? sync;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: const BoxDecoration(
        color: Color(0xFF11161B),
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 6),
          _btn(Icons.pan_tool_alt,
              tooltip: st.mode == AppMode.edit ? '退出打点' : '打点（标记）',
              active: st.mode == AppMode.edit,
              onTap: () => st.setMode(
                  st.mode == AppMode.edit ? AppMode.view : AppMode.edit)),
          _btn(Icons.account_tree_outlined,
              tooltip: '连线路（拓扑）',
              active: st.mode == AppMode.topoLink,
              onTap: onTopo),
          _measureBtn(context),
          _btn(Icons.route, tooltip: '轨迹记录', onTap: onTrack),
          _btn(Icons.my_location, tooltip: '定位', onTap: onLocate),
          _sep(),
          _btn(Icons.undo, tooltip: '撤销 Ctrl+Z', onTap: onUndo),
          _btn(Icons.redo, tooltip: '重做 Ctrl+Y', onTap: onRedo),
          _btn(Icons.delete_outline,
              tooltip: '删除选中 Delete',
              enabled: st.selectedIds.isNotEmpty,
              onTap: onDeleteSelection),
          _sep(),
          _btn(Icons.add, tooltip: '放大', onTap: onZoomIn),
          _btn(Icons.remove, tooltip: '缩小', onTap: onZoomOut),
          _sep(),
          _btn(Icons.layers_outlined,
              tooltip: '图源 / 图层',
              onTap: () => showSourceDialog(context, st)),
          _btn(Icons.ios_share, tooltip: '导出成果 Ctrl+E', onTap: onExport),
          _syncBtn(context),
          const Spacer(),
          _btn(leftCollapsed ? Icons.chevron_right : Icons.chevron_left,
              tooltip: leftCollapsed ? '展开左栏' : '收起左栏',
              onTap: onToggleLeft),
          _btn(
              rightCollapsed ? Icons.chevron_left : Icons.chevron_right,
              tooltip: rightCollapsed ? '展开右栏' : '收起右栏',
              onTap: onToggleRight),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _measureBtn(BuildContext context) {
    final active = st.mode == AppMode.measureDist ||
        st.mode == AppMode.measureArea;
    return PopupMenuButton<String>(
      tooltip: '测距 / 测面积',
      color: kPanelBg,
      position: PopupMenuPosition.under,
      onSelected: (v) {
        st.setMode(v == 'area' ? AppMode.measureArea : AppMode.measureDist);
      },
      itemBuilder: (ctx) => const [
        PopupMenuItem(
            value: 'dist',
            child: Text('测距', style: TextStyle(color: kTextMain))),
        PopupMenuItem(
            value: 'area',
            child: Text('测面积', style: TextStyle(color: kTextMain))),
      ],
      child: SizedBox(
        width: 40,
        height: 48,
        child: Center(
          child: Icon(Icons.straighten,
              size: 20, color: active ? kAccent : kTextMain),
        ),
      ),
    );
  }

  Widget _syncBtn(BuildContext context) {
    // 状态取自可空快照（无 `?? throw` getter）；未接入同步时显示「仅本地」灰点。
    final status = sync?.aggregateStatus ?? SyncStatus.localOnly;
    final dot = Color(status.argb);
    final pending = sync?.pendingCount ?? 0;
    final tip = '云同步 · ${status.label}'
        '${pending > 0 ? ' · 待上传 $pending' : ''}';
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onSync,
        child: SizedBox(
          width: 40,
          height: 48,
          child: Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Icon(Icons.sync, size: 20, color: kTextMain),
                Positioned(
                  right: 6,
                  bottom: 12,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: dot,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _btn(IconData icon,
      {required String tooltip,
      required VoidCallback onTap,
      bool active = false,
      bool enabled = true}) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 40,
          height: 48,
          child: Center(
            child: Icon(icon,
                size: 20,
                color: !enabled
                    ? Colors.white24
                    : active
                        ? kAccent
                        : kTextMain),
          ),
        ),
      ),
    );
  }

  Widget _sep() => Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: Colors.white12);
}
