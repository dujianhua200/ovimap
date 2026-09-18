import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../geo/geo_util.dart';
import '../../state/app_state.dart';
import '../../sync/sync_controller.dart';
import '../../sync/sync_models.dart';
import '../dialogs.dart';

/// 桌面底部状态栏（架构文档 §3.2 / T11 / T17，高度 26）。
///
/// 左起：设备名 · 同步状态 · 最后同步时间 · 当前显示坐标 · 图源 · 缩放 · 选中数。
/// 同步区取自 [SyncController]（可为 null：未接入同步 → 「本地模式」）。
class StatusBar extends StatelessWidget {
  const StatusBar({
    super.key,
    required this.st,
    required this.centerText,
    required this.zoom,
    required this.selectedCount,
    this.sync,
  });

  final AppState st;
  final String centerText;
  final double zoom;
  final int selectedCount;

  /// 云同步编排器（可为 null）。
  final SyncController? sync;

  static final String _device = _resolveDevice();

  static String _resolveDevice() {
    try {
      final env = Platform.environment;
      final n = env['COMPUTERNAME'] ?? env['HOSTNAME'] ?? env['USERNAME'];
      if (n != null && n.trim().isNotEmpty) return n.trim();
    } catch (_) {}
    return '本机';
  }

  @override
  Widget build(BuildContext context) {
    final sc = sync;
    // 全部取自可空快照（无 `?? throw` getter），未接入同步时退化为「本地模式」。
    final configured = sc?.configured ?? false;
    final status = sc?.aggregateStatus;
    final statusText =
        configured ? (status?.label ?? '仅本地') : '本地模式';
    final statusIcon = configured
        ? (status == SyncStatus.synced
            ? Icons.cloud_done_outlined
            : status == SyncStatus.conflict
                ? Icons.cloud_off
                : Icons.cloud_upload_outlined)
        : Icons.cloud_off;
    final statusColor = configured ? Color(status?.argb ?? 0xFF9E9E9E) : kTextSub;
    final syncTime = configured ? (sc?.lastSyncText ?? '—') : '—';
    final device = configured && (sc?.deviceName.isNotEmpty ?? false)
        ? sc!.deviceName
        : _device;

    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF11161B),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          _item(Icons.computer, device),
          _divider(),
          _item(statusIcon, statusText, color: statusColor),
          _item(null, '最后同步：$syncTime'),
          if (configured && (sc?.pendingCount ?? 0) > 0) ...[
            _divider(),
            _item(Icons.cloud_upload_outlined, '待上传 ${sc!.pendingCount}',
                color: const Color(0xFFFFB74D)),
          ],
          _divider(),
          _item(Icons.my_location, centerText),
          _divider(),
          _item(Icons.layers_outlined, st.curSource.name),
          _divider(),
          _item(null, '缩放 ${zoom.toStringAsFixed(1)}'),
          if (selectedCount > 0) ...[
            _divider(),
            _item(Icons.check_circle_outline, '已选 $selectedCount 点',
                color: kAccent),
          ],
          const Spacer(),
          Text('坐标系 ${GeoUtil.fmtName(st.coordFmt)}',
              style: const TextStyle(color: kTextSub, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _item(IconData? icon, String text, {Color color = kTextSub}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
            ],
            Text(text,
                style: TextStyle(color: color, fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      );

  Widget _divider() =>
      Container(width: 1, height: 12, color: Colors.white12);
}
