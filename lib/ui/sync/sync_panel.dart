import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/device_identity.dart';
import '../../services/platform_caps.dart';
import '../../state/app_state.dart';
import '../../sync/sync_controller.dart';
import '../../sync/sync_models.dart';
import '../dialogs.dart';
import '../../ui/design_tokens.dart';
import 'pairing_page.dart';
import 'server_panel.dart';
import '../../services/photos.dart';
import '../../sync/client/photo_sync_queue.dart';
import '../../models/map_label.dart';

/// 「连上自动同步」开关的 prefs 键（默认关）。
const String kPrefAutoSyncOnConnect = 'syncAutoOnConnect';

/// 同步徽标（✓ 已同步 / ↑ 待上传 / ⚠ 有冲突 / ● 仅本地）。
///
/// 纯展示组件，[status] 由调用方从 `SyncController` 以**可空快照**方式取得，
/// 自身不做任何可能抛异常的读取（AOT 安全规则）。
class SyncBadge extends StatelessWidget {
  const SyncBadge({super.key, required this.status, this.compact = true});

  final SyncStatus status;

  /// 紧凑模式：只显示徽标字符；否则「字符 + 中文」。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = Color(status.argb);
    return Tooltip(
      message: status.label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              status.badge,
              style: TextStyle(color: color, fontSize: 9.5, height: 1.2),
            ),
            if (!compact) ...[
              const SizedBox(width: 3),
              Text(
                status.label,
                style: TextStyle(color: color, fontSize: 9.5, height: 1.2),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 打开同步面板（工具栏 🔄 / 抽屉入口）。
///
/// [sync] 可为 null（未接入同步的环境）：面板退化为「本地模式」说明，不报错。
Future<void> showSyncPanel(
  BuildContext context,
  SyncController? sync,
  AppState? st,
) async {
  await showDarkDialog(
    context,
    title: '云同步',
    content: _SyncPanelBody(sync: sync, st: st),
    actions: [darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub)],
  );
}

class _SyncPanelBody extends StatefulWidget {
  const _SyncPanelBody({required this.sync, required this.st});

  final SyncController? sync;
  final AppState? st;

  @override
  State<_SyncPanelBody> createState() => _SyncPanelBodyState();
}

class _SyncPanelBodyState extends State<_SyncPanelBody> {
  bool _busy = false;

  /// 「连上自动同步」开关（默认关，存 shared_preferences）。
  bool _autoSync = false;

  /// 照片同步进度文案（空 = 不显示）。
  String _photoProgress = '';

  @override
  void initState() {
    super.initState();
    // 打开时刷新身份（设置页可能刚改过令牌/地址）。
    final sc = widget.sync;
    if (sc != null) {
      sc.reloadIdentity().then((_) {
        if (mounted) setState(() {});
      });
    }
    _loadAutoSyncPref();
  }

  Future<void> _loadAutoSyncPref() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getBool(kPrefAutoSyncOnConnect) ?? false;
      if (!mounted) return;
      setState(() => _autoSync = v);
      // 开关开着且当前已连通 → 自动执行一次同步（只做触发，不改控制器内部）。
      if (v) _maybeAutoSync();
    } catch (_) {}
  }

  /// 开关打开 / 面板打开时：若已连通服务器，自动触发一次同步。
  Future<void> _maybeAutoSync() async {
    final sc = widget.sync;
    if (sc == null || _busy || !sc.configured) return;
    if (!sc.online) return; // 离线不触发，等 ping 轮询恢复后再由用户手动同步
    await _manualSync();
  }

  Future<void> _setAutoSync(bool v) async {
    setState(() => _autoSync = v);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(kPrefAutoSyncOnConnect, v);
    } catch (_) {}
    if (v) _maybeAutoSync();
  }

  @override
  Widget build(BuildContext context) {
    final sc = widget.sync;
    if (sc == null) {
      return const SizedBox(
        width: 380,
        child: Text(
          '未接入云同步（当前为本地模式）。\n\n'
          '所有数据保存在本机，与 Android 端目录结构一致，可整目录拷贝互换。',
          style: TextStyle(color: kTextMain, fontSize: 13, height: 1.6),
        ),
      );
    }

    final st = sc.aggregateStatus;
    return SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(Icons.computer, '设备名', sc.deviceName),
          _serverRow(sc),
          _row(
            Icons.cloud_outlined,
            '状态',
            '${st.label}${sc.online ? '' : ' · 离线'}',
          ),
          _row(Icons.schedule, '最后同步', sc.lastSyncText),
          _row(Icons.cloud_upload_outlined, '待上传', '${sc.pendingCount} 项'),
          const SizedBox(height: 6),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text(
              '连上自动同步',
              style: TextStyle(color: kTextMain, fontSize: 13),
            ),
            subtitle: const Text(
              'SyncController 启动且能连通服务器时自动同步一次',
              style: TextStyle(color: kTextSub, fontSize: 11),
            ),
            value: _autoSync,
            activeThumbColor: kAccent,
            onChanged: _busy ? null : _setAutoSync,
          ),
          if (!sc.configured) ...[
            const SizedBox(height: 8),
            const Text(
              '尚未配置同步令牌：请在「同步设置」里填入令牌与服务器地址。',
              style: TextStyle(color: TokC.warn, fontSize: 12),
            ),
          ],
          if (sc.lastError.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '最近错误：${sc.lastError}',
              style: const TextStyle(color: TokC.danger, fontSize: 11.5),
            ),
          ],
          if (_photoProgress.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              _photoProgress,
              style: const TextStyle(color: kAccent, fontSize: 11.5),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton.icon(
                onPressed: !sc.configured || _busy ? null : _manualSync,
                icon: const Icon(Icons.sync, size: 18),
                label: const Text('立即同步'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: !sc.configured || _busy ? null : _syncPhotos,
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: const Text('同步照片'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _openPairing,
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: const Text('扫码配对'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _busy ? null : _openSettings,
                icon: const Icon(Icons.settings, size: 18),
                label: const Text('同步设置'),
              ),
              if (PlatformCaps.isWindows) ...[
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => showSyncServerPanel(context),
                  icon: const Icon(Icons.dns, size: 18),
                  label: const Text('服务端管理'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _manualSync() async {
    final sc = widget.sync;
    if (sc == null) return;
    setState(() => _busy = true);
    await sc.manualSync();
    if (mounted) setState(() => _busy = false);
  }

  /// 「同步照片」：遍历当前工程全部标记的 photoPaths，对服务端缺失的
  /// 经 [PhotoSyncQueue] 分块上传（断点续传）。不经过 SyncController。
  Future<void> _syncPhotos() async {
    final sc = widget.sync;
    final st = widget.st;
    if (sc == null || !sc.configured) return;
    final cid = st?.activeCollectionId ?? '';
    if (cid.isEmpty) {
      toast(context, '请先打开一个工程再同步照片');
      return;
    }
    final rels = <String>[
      for (final l in st?.labels ?? const <MapLabel>[]) ...l.photoPaths,
    ];
    if (rels.isEmpty) {
      toast(context, '当前工程没有照片');
      return;
    }
    setState(() {
      _busy = true;
      _photoProgress = '准备上传…';
    });
    try {
      final r = await PhotoSyncQueue().syncAll(
        baseUrl: sc.identity.serverBase,
        token: sc.identity.token,
        cid: cid,
        photoRelNames: rels,
        absPathOf: PhotoService.absPath,
        onFileProgress: (rel, s, t) {
          if (!mounted) return;
          setState(
            () => _photoProgress =
                '上传 $rel：${(s / 1024).round()}/${(t / 1024).round()} KB',
          );
        },
      );
      if (!mounted) return;
      toast(
        context,
        '照片同步完成：上传 ${r.uploaded} 张，跳过 ${r.skipped} 张${r.failed.isEmpty ? '' : '，失败 ${r.failed.length} 张'}',
      );
    } catch (e) {
      if (mounted) toast(context, '照片同步失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _photoProgress = '';
        });
      }
    }
  }

  Future<void> _openPairing() async {
    final sc = widget.sync;
    if (!mounted) return;
    final ok = await showPairingPage(context);
    if (ok == true && mounted) {
      // 配对成功后刷新身份显示（服务器地址已更新）。
      await sc?.reloadIdentity();
      if (mounted) setState(() {});
    }
  }

  /// 服务器地址行：点击切换「局域网 IP / Tunnel 域名」。
  Widget _serverRow(SyncController sc) {
    final value = sc.identity.serverBase.isEmpty
        ? '未配置（点此设置）'
        : sc.identity.serverBase;
    return InkWell(
      onTap: _busy ? null : () => _switchServerBase(sc),
      borderRadius: BorderRadius.circular(4),
      child: _row(Icons.dns_outlined, '服务器', value),
    );
  }

  /// 服务器地址切换：局域网 IP / Tunnel 域名两个输入框，各自「使用」。
  Future<void> _switchServerBase(SyncController sc) async {
    final id = sc.identity;
    final lanCtl = TextEditingController();
    final remoteCtl = TextEditingController();
    // 按当前地址形态预填到对应框。
    final cur = id.serverBase;
    if (cur.startsWith('http://')) {
      lanCtl.text = cur;
    } else if (cur.isNotEmpty) {
      remoteCtl.text = cur;
    }
    if (!mounted) return;
    final navigator = Navigator.of(context);
    await showDarkDialog(
      context,
      title: '切换服务器地址',
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '局域网地址（电脑端服务，如 http://192.168.1.x:47820）',
              style: TextStyle(color: kTextSub, fontSize: 12),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: lanCtl,
              keyboardType: TextInputType.url,
              style: const TextStyle(color: kTextMain, fontSize: 13),
              decoration: dec('http://192.168.1.x:47820'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: lanCtl.text.trim().isEmpty
                        ? null
                        : () async {
                            await id.saveConfig(serverBase: lanCtl.text.trim());
                            navigator.pop();
                            if (mounted) setState(() {});
                          },
                    child: const Text('使用局域网地址'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              '远程域名（Cloudflare Tunnel，如 https://sync.xxx.com）',
              style: TextStyle(color: kTextSub, fontSize: 12),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: remoteCtl,
              keyboardType: TextInputType.url,
              style: const TextStyle(color: kTextMain, fontSize: 13),
              decoration: dec('https://sync.你的域名'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: remoteCtl.text.trim().isEmpty
                        ? null
                        : () async {
                            await id.saveConfig(
                              serverBase: remoteCtl.text.trim(),
                            );
                            navigator.pop();
                            if (mounted) setState(() {});
                          },
                    child: const Text('使用远程域名'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      ],
    );
    lanCtl.dispose();
    remoteCtl.dispose();
  }

  Future<void> _openSettings() async {
    final sc = widget.sync;
    if (!mounted) return;
    await showSyncSettingsDialog(context, sc);
    if (mounted) setState(() {});
  }

  Widget _row(IconData icon, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: kTextSub),
        const SizedBox(width: 8),
        SizedBox(
          width: 68,
          child: Text(
            label,
            style: const TextStyle(color: kTextSub, fontSize: 12.5),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: kTextMain, fontSize: 12.5),
          ),
        ),
      ],
    ),
  );
}

/// 同步设置对话框：同步令牌 + 服务器地址 + 设备名（v1 手动粘贴，扫码归 P2）。
Future<void> showSyncSettingsDialog(
  BuildContext context,
  SyncController? sync,
) async {
  final id = sync?.identity ?? DeviceIdentity.instance;
  if (!id.loaded) {
    await id.load();
  }
  final tokenCtl = TextEditingController(text: id.token);
  final baseCtl = TextEditingController(text: id.serverBase);
  final nameCtl = TextEditingController(text: id.deviceName);

  if (!context.mounted) return;
  await showDarkDialog(
    context,
    title: '同步设置',
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '设备名（用于冲突提示，可自定义）',
            style: TextStyle(color: kTextSub, fontSize: 12),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: nameCtl,
            style: const TextStyle(color: kTextMain, fontSize: 13),
            decoration: dec('如：电脑-信阳办公室'),
          ),
          const SizedBox(height: 12),
          const Text(
            '服务器地址（专属子域，如 https://sync.example.com）',
            style: TextStyle(color: kTextSub, fontSize: 12),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: baseCtl,
            keyboardType: TextInputType.url,
            style: const TextStyle(color: kTextMain, fontSize: 13),
            decoration: dec('https://sync.你的域名'),
          ),
          const SizedBox(height: 12),
          const Text(
            '同步令牌（与 Worker Secret SYNC_TOKEN 一致）',
            style: TextStyle(color: kTextSub, fontSize: 12),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: tokenCtl,
            style: const TextStyle(color: kTextMain, fontSize: 13),
            decoration: dec('粘贴同步令牌'),
          ),
          const SizedBox(height: 10),
          const Text(
            '提示：令牌错误时同步请求会被服务端拒绝（401）。',
            style: TextStyle(color: kTextSub, fontSize: 11),
          ),
        ],
      ),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('保存并测试', () async {
        final navigator = Navigator.of(context);
        await id.saveConfig(
          token: tokenCtl.text,
          serverBase: baseCtl.text,
          deviceName: nameCtl.text,
        );
        if (navigator.mounted) navigator.pop();
        if (sync != null) {
          await sync.manualSync();
        }
      }),
    ],
  );
}

// ===================== 版本历史与恢复（T20） =====================

/// 版本历史与恢复入口（工程右键 / 移动端长按「历史版本」）。
///
/// 未接入同步或未配置令牌 → **中文提示**后返回（不崩）。
/// 列表每条显示：`rev` / 设备名 / 时间 / 点数；点「恢复」→ 二次确认 →
/// `SyncController.restoreVersion`（服务端生成新 rev，本地落盘并刷新）。
Future<void> showVersionHistoryDialog(
  BuildContext context,
  SyncController? sync,
  String cid,
  String name,
) async {
  if (sync == null || !sync.configured) {
    toast(context, '未配置云同步，请在「同步设置」里填入令牌');
    return;
  }
  if (cid.isEmpty) {
    toast(context, '该工程尚未同步，暂无历史版本');
    return;
  }
  await showDarkDialog(
    context,
    title: '历史版本：${name.isEmpty ? '未命名' : name}',
    content: _VersionHistoryBody(sync: sync, cid: cid, name: name),
    actions: [darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub)],
  );
}

class _VersionHistoryBody extends StatefulWidget {
  const _VersionHistoryBody({
    required this.sync,
    required this.cid,
    required this.name,
  });

  final SyncController sync;
  final String cid;
  final String name;

  @override
  State<_VersionHistoryBody> createState() => _VersionHistoryBodyState();
}

class _VersionHistoryBodyState extends State<_VersionHistoryBody> {
  bool _loading = true;
  String _error = '';
  List<VersionInfo> _versions = const <VersionInfo>[];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final vs = await widget.sync.listHistory(widget.cid);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (vs == null) {
        final e = widget.sync.lastError;
        _error = widget.sync.configured
            ? (e.isEmpty ? '加载失败（网络不可用或鉴权失败）' : e)
            : '未配置云同步';
        _versions = const <VersionInfo>[];
      } else {
        _error = '';
        // 新版本在前（服务端已按 rev 倒序，这里再做一次兜底排序）。
        _versions = [...vs]..sort((a, b) => b.rev.compareTo(a.rev));
      }
    });
  }

  Future<void> _confirmRestore(VersionInfo v) async {
    final navigator = Navigator.of(context);
    // 数据安全提示（用户对覆盖敏感）：该工程在本机还有未上传的改动时，
    // 恢复会把这些改动丢掉 —— 必须在确认框里明示。
    final hasPending =
        widget.sync.statusFor(widget.cid) == SyncStatus.pendingUpload;
    var confirmed = false;
    await showDarkDialog(
      context,
      title: '恢复历史版本',
      content: Text(
        '确定恢复到 rev ${v.rev}（${v.deviceName.isEmpty ? '未知设备' : v.deviceName} · '
        '${_fmtTs(v.updatedAt)} · ${v.labelCount} 点）？\n\n'
        '当前云端内容将被该版本覆盖，并生成一个新的版本号（旧版本仍可再恢复）。'
        '${hasPending ? '\n\n⚠️ 恢复将以所选版本为准，本机未上传的改动将丢失。' : ''}',
        style: const TextStyle(color: kTextMain, fontSize: 13, height: 1.5),
      ),
      actions: [
        darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
        darkTextBtn('恢复', () {
          confirmed = true;
          Navigator.pop(context);
        }, color: kAccent),
      ],
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    final ok = await widget.sync.restoreVersion(widget.cid, v.rev);
    if (!mounted) return;
    setState(() => _busy = false);
    if (navigator.mounted) navigator.pop(); // 关闭历史对话框
    toast(
      context,
      ok ? '已恢复到 rev ${v.rev}，本地已刷新' : '恢复失败：${widget.sync.lastError}',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        width: 420,
        height: 160,
        child: Center(child: CircularProgressIndicator(color: kAccent)),
      );
    }
    if (_error.isNotEmpty) {
      return SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _error,
              style: const TextStyle(
                color: TokC.warn,
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _busy ? null : _load,
              child: const Text('重试', style: TextStyle(color: kAccent)),
            ),
          ],
        ),
      );
    }
    if (_versions.isEmpty) {
      return const SizedBox(
        width: 420,
        child: Text(
          '该工程还没有历史版本（首次上传后开始产生）。',
          style: TextStyle(color: kTextSub, fontSize: 12.5, height: 1.5),
        ),
      );
    }
    return SizedBox(
      width: 460,
      height: 360,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '共 ${_versions.length} 个版本（最新在前）',
            style: const TextStyle(color: kTextSub, fontSize: 11.5),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: ListView.separated(
              itemCount: _versions.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: TokC.divider),
              itemBuilder: (ctx, i) {
                final v = _versions[i];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 13,
                    backgroundColor: kAccent.withValues(alpha: 0.18),
                    child: Text(
                      '${v.rev}',
                      style: const TextStyle(color: kAccent, fontSize: 11),
                    ),
                  ),
                  title: Text(
                    '${v.deviceName.isEmpty ? '未知设备' : v.deviceName} · ${v.labelCount} 点',
                    style: const TextStyle(color: kTextMain, fontSize: 13),
                  ),
                  subtitle: Text(
                    _fmtTs(v.updatedAt),
                    style: const TextStyle(color: kTextSub, fontSize: 11),
                  ),
                  trailing: TextButton(
                    onPressed: _busy ? null : () => _confirmRestore(v),
                    child: const Text(
                      '恢复',
                      style: TextStyle(color: kAccent, fontSize: 12.5),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 毫秒时间戳 → `MM-dd HH:mm`（缺省/非法返回「—」）。
String _fmtTs(int ms) {
  if (ms <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String p2(int v) => v.toString().padLeft(2, '0');
  return '${p2(d.month)}-${p2(d.day)} ${p2(d.hour)}:${p2(d.minute)}';
}
