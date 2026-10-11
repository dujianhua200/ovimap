import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/platform_caps.dart';
import '../../services/secure_store.dart';
import '../../sync/sync_protocol.dart';
import '../../sync/tunnel/tunnel_manager.dart';
import '../design_tokens.dart';
import '../dialogs.dart';

export '../../sync/tunnel/qr_payload.dart';

/// 手动安装指引（下载失败时显示）。
String get kCloudflaredManualGuide =>
    '手动安装指引：\n'
    '1. 打开 https://github.com/cloudflare/cloudflared/releases\n'
    '2. 下载版本 $kCloudflaredVersion 的 cloudflared-windows-amd64.exe\n'
    '3. 重命名为 cloudflared.exe，放入 %APPDATA%\\ovimap\\bin\\ 目录\n'
    '4. 回到本页打开「启用远程同步」开关';

/// 打开 Tunnel 配置对话框（设置页「云同步」分组加一个入口即可接入）。
Future<void> showTunnelSettingsDialog(BuildContext context,
    {TunnelManager? manager}) {
  return showDarkDialog(
    context,
    title: '远程同步通道（Cloudflare Tunnel）',
    width: 480,
    content: TunnelSettingsCard(manager: manager),
    actions: [
      darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
    ],
  );
}

/// Tunnel 配置卡片：token / 远程地址 / 启用开关 / 状态 / 日志 / 下载。
///
/// 可嵌入设置页或同步面板。仅 Windows 有效，其他平台显示提示文案。
class TunnelSettingsCard extends StatefulWidget {
  const TunnelSettingsCard({super.key, this.manager});

  /// 可注入（测试用）；缺省自建并持有。
  final TunnelManager? manager;

  @override
  State<TunnelSettingsCard> createState() => _TunnelSettingsCardState();
}

class _TunnelSettingsCardState extends State<TunnelSettingsCard> {
  late final TunnelManager _mgr;
  late final bool _ownManager;

  final _tokenCtl = TextEditingController();
  final _urlCtl = TextEditingController();

  bool _supported = true;
  bool _binaryReady = false;
  bool _tokenSaved = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ownManager = widget.manager == null;
    _mgr = widget.manager ?? TunnelManager();
    _mgr.addListener(_onMgr);
    _supported = PlatformCaps.isWindows;
    if (_supported) _load();
  }

  void _onMgr() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final token = await SecureStore.instance.read(kTunnelTokenKey);
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _tokenCtl.text = token ?? '';
      _tokenSaved = token != null && token.isNotEmpty;
      _urlCtl.text = prefs.getString(kTunnelUrlPrefKey) ?? '';
      _enabled = prefs.getBool(kTunnelEnabledPrefKey) ?? false;
    });
    final exists = await _mgr.binaryExists().catchError((_) => false);
    if (mounted) setState(() => _binaryReady = exists);
  }

  bool _enabled = false;

  @override
  void dispose() {
    _mgr.removeListener(_onMgr);
    if (_ownManager) _mgr.dispose();
    _tokenCtl.dispose();
    _urlCtl.dispose();
    super.dispose();
  }

  Future<void> _saveToken() async {
    final token = _tokenCtl.text.trim();
    if (token.isEmpty) {
      toast(context, '请先粘贴 Tunnel token');
      return;
    }
    setState(() => _busy = true);
    try {
      await SecureStore.instance.write(kTunnelTokenKey, token);
      if (mounted) {
        setState(() => _tokenSaved = true);
        toast(context, 'Token 已保存到系统安全存储（${maskSecret(token)}）');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveUrl() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kTunnelUrlPrefKey, _urlCtl.text.trim());
    if (mounted) toast(context, '远程地址已保存（配对二维码会自动带上）');
  }

  Future<void> _download() async {
    setState(() => _busy = true);
    try {
      await _mgr.ensureBinary();
      if (mounted) setState(() => _binaryReady = true);
    } catch (e) {
      if (mounted) toast(context, '下载失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kTunnelEnabledPrefKey, v);
    setState(() => _enabled = v);
    if (!v) {
      _mgr.stop();
      return;
    }
    setState(() => _busy = true);
    try {
      final token = await SecureStore.instance.read(kTunnelTokenKey);
      if (token == null || token.trim().isEmpty) {
        if (mounted) toast(context, '请先保存 Tunnel token');
        await prefs.setBool(kTunnelEnabledPrefKey, false);
        if (mounted) setState(() => _enabled = false);
        return;
      }
      await _mgr.ensureBinary();
      await _mgr.start(token);
      if (mounted) setState(() => _binaryReady = true);
    } catch (e) {
      if (mounted) toast(context, '启动失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) {
      return const SizedBox(
        width: 400,
        child: Text('远程 Tunnel 通道仅 Windows 服务端支持（手机/桌面其他平台请用局域网同步）。',
            style: TextStyle(color: kTextSub, fontSize: 12.5, height: 1.6)),
      );
    }
    return SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '在 Cloudflare Zero Trust → Networks → Tunnels 创建隧道后，'
              '把 token 粘贴到下面。远程同步即走 HTTPS，无需公网 IP。',
              style: TextStyle(color: kTextSub, fontSize: 12, height: 1.6),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _tokenCtl,
                    obscureText: true,
                    style: const TextStyle(color: kTextMain, fontSize: 13),
                    decoration: dec('粘贴 Tunnel token（只显示一次的那串）'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _busy ? null : _saveToken,
                  child: Text(_tokenSaved ? '已保存' : '保存'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtl,
                    keyboardType: TextInputType.url,
                    style: const TextStyle(color: kTextMain, fontSize: 13),
                    decoration: dec('远程地址，如 https://sync.你的域名'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _busy ? null : _saveUrl,
                  child: const Text('保存'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用远程同步',
                  style: TextStyle(color: kTextMain, fontSize: 13.5)),
              subtitle: Text(
                _mgr.running
                    ? '● 运行中'
                    : (_enabled ? '○ 已停止（开关开着但未运行）' : '○ 已停止'),
                style: TextStyle(
                    color: _mgr.running ? TokC.ok : kTextSub, fontSize: 12),
              ),
              value: _enabled,
              onChanged: _busy ? null : _toggleEnabled,
            ),
            if (!_binaryReady) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy || _mgr.downloading ? null : _download,
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('下载 cloudflared'),
                    ),
                  ),
                ],
              ),
              if (_mgr.downloading && _mgr.downloadProgress != null) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(
                    value: _mgr.downloadProgress, color: kAccent),
              ],
            ],
            if (_mgr.lastError != null && _mgr.lastError!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('⚠ ${_mgr.lastError}',
                  style:
                      const TextStyle(color: TokC.danger, fontSize: 11.5, height: 1.5)),
              const SizedBox(height: 6),
              Text(kCloudflaredManualGuide,
                  style:
                      const TextStyle(color: kTextSub, fontSize: 11.5, height: 1.6)),
            ],
            if (_mgr.logLines.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('最近日志（token 已脱敏）',
                  style: TextStyle(color: kTextSub, fontSize: 11.5)),
              const SizedBox(height: 4),
              Container(
                height: 120,
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: kTextSub.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _mgr.logLines.join('\n'),
                    style: const TextStyle(
                        color: kTextSub, fontSize: 10.5, height: 1.5,
                        fontFamily: 'monospace'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
