import 'dart:io' show InternetAddressType, NetworkInterface;

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/platform_caps.dart';
import '../../sync/sync_protocol.dart';
import '../../sync/server/pairing.dart';
import '../../sync/server/photo_upload.dart';
import '../../sync/server/secure_token_store.dart';
import '../../sync/server/server_store.dart';
import '../../sync/server/sync_server.dart';
import '../design_tokens.dart';
import '../dialogs.dart';
import 'tunnel_settings.dart';

/// 同步服务端管理面板（仅 Windows）。
///
/// 入口：同步面板 →「服务端管理」（Windows 可见）。
/// 功能：启动/停止服务、账号管理（新建/删除/重置密钥）、配对二维码展示、
/// 远程通道（Tunnel）设置入口。
Future<void> showSyncServerPanel(BuildContext context) {
  if (!PlatformCaps.isWindows) {
    return showDarkDialog(
      context,
      title: '同步服务端',
      content: const Text('同步服务端仅在 Windows 版可用。', style: TextStyle(color: kTextMain)),
      actions: [darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub)],
    );
  }
  return showDarkDialog(
    context,
    title: '同步服务端（Windows）',
    width: 520,
    content: const _ServerPanelBody(),
    actions: [darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub)],
  );
}

/// 服务端单例（应用级持有）。
class SyncServerHost {
  SyncServerHost._();
  static final SyncServerHost instance = SyncServerHost._();

  SyncServer? _server;
  PairingService? _pairing;

  bool get running => _server?.running ?? false;
  int get port => _server?.port ?? kSyncServerPort;
  PairingService? get pairing => _pairing;

  Future<SyncServer> _build() async {
    final store = ServerStore();
    final tokens = SecureTokenStore();
    final pairing = PairingService(store: store, tokens: tokens);
    final photos = PhotoUploadManager(store: store);
    _pairing = pairing;
    return SyncServer(
      store: store,
      pairing: pairing,
      photos: photos,
      tokens: tokens,
      serverName: 'ovimap-sync',
    );
  }

  Future<void> start({int port = kSyncServerPort}) async {
    if (running) return;
    _server ??= await _build();
    await _server!.start(port: port);
  }

  Future<void> stop() async {
    await _server?.stop();
  }
}

class _ServerPanelBody extends StatefulWidget {
  const _ServerPanelBody();

  @override
  State<_ServerPanelBody> createState() => _ServerPanelBodyState();
}

class _ServerPanelBodyState extends State<_ServerPanelBody> {
  final _host = SyncServerHost.instance;
  List<Map<String, dynamic>> _accounts = [];
  bool _busy = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _refreshAccounts();
  }

  Future<void> _refreshAccounts() async {
    final pairing = _host.pairing;
    if (pairing == null) {
      setState(() => _accounts = []);
      return;
    }
    try {
      final list = await pairing.listAccounts();
      if (mounted) setState(() => _accounts = list);
    } catch (e) {
      if (mounted) setState(() => _status = '读取账号失败：$e');
    }
  }

  Future<void> _toggleServer() async {
    setState(() { _busy = true; _status = ''; });
    try {
      if (_host.running) {
        await _host.stop();
        _status = '服务已停止';
      } else {
        await _host.start();
        _status = '服务运行中（端口 ${_host.port}）';
      }
      await _refreshAccounts();
    } catch (e) {
      _status = '操作失败：$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _createAccount() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kPanelBg,
        title: const Text('新建同步账号', style: TextStyle(color: kTextMain, fontSize: 16)),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          style: const TextStyle(color: kTextMain),
          decoration: const InputDecoration(
            hintText: '账号名称（如：张三的手机）',
            hintStyle: TextStyle(color: kTextHint),
          ),
        ),
        actions: [
          darkTextBtn('取消', () => Navigator.pop(ctx), color: kTextSub),
          darkTextBtn('创建', () => Navigator.pop(ctx, nameCtrl.text.trim())),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() { _busy = true; _status = ''; });
    try {
      if (!_host.running) await _host.start();
      final pairing = _host.pairing!;
      final acc = await pairing.createAccount(name);
      _status = '账号已创建：${acc.accountId}';
      await _refreshAccounts();
      if (mounted) {
        // 创建后直接展示配对二维码
        await _showPairQr(acc.accountId, name);
      }
    } catch (e) {
      _status = '创建失败：$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _deleteAccount(String accountId, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kPanelBg,
        title: const Text('删除账号', style: TextStyle(color: kTextMain, fontSize: 16)),
        content: Text('确定删除账号「$name」？\n其同步数据目录将一并删除，手机端需重新配对。',
            style: const TextStyle(color: kTextMain)),
        actions: [
          darkTextBtn('取消', () => Navigator.pop(ctx, false), color: kTextSub),
          darkTextBtn('删除', () => Navigator.pop(ctx, true), color: kDanger),
        ],
      ),
    );
    if (ok != true) return;
    setState(() { _busy = true; _status = ''; });
    try {
      await _host.pairing!.deleteAccount(accountId);
      _status = '账号已删除';
      await _refreshAccounts();
    } catch (e) {
      _status = '删除失败：$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _showPairQr(String accountId, String name) async {
    setState(() { _busy = true; _status = ''; });
    try {
      final pairing = _host.pairing!;
      final code = await pairing.issuePairCode(accountId);
      // LAN 地址：取本机第一个非回环 IPv4
      final lanIp = await _localLanIp();
      final lanUrl = 'http://$lanIp:${_host.port}';
      final prefs = await SharedPreferences.getInstance();
      final remoteUrl = (prefs.getString('syncTunnelUrl') ?? '').trim();
      final payloadJson = buildQrPayload(
        accountId: accountId,
        code: code,
        name: name,
        lanUrl: lanUrl,
        remoteUrl: remoteUrl.isEmpty ? null : remoteUrl,
      );
      if (!mounted) return;
      await showDarkDialog(
        context,
        title: '扫码配对（5 分钟有效）',
        width: 420,
        content: _PairQrView(
          payloadJson: payloadJson,
          code: code,
          lanUrl: lanUrl,
          remoteUrl: remoteUrl.isEmpty ? null : remoteUrl,
        ),
        actions: [
          darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
        ],
      );
    } catch (e) {
      _status = '签发配对码失败：$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  /// 取本机 LAN IPv4（失败回退 127.0.0.1）。
  Future<String> _localLanIp() async {
    try {
      final ifs = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final i in ifs) {
        for (final a in i.addresses) {
          final ip = a.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              ip.startsWith('172.')) {
            return ip;
          }
        }
      }
      if (ifs.isNotEmpty && ifs.first.addresses.isNotEmpty) {
        return ifs.first.addresses.first.address;
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 服务开关行
          Row(
            children: [
              Container(
                width: 10, height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _host.running ? TokC.ok : kTextHint,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _host.running ? '运行中（端口 ${_host.port}）' : '未运行',
                style: const TextStyle(color: kTextMain, fontSize: 14),
              ),
              const Spacer(),
              darkTextBtn(
                _host.running ? '停止服务' : '启动服务',
                _busy ? () {} : _toggleServer,
                color: _host.running ? kDanger : kAccent,
              ),
            ],
          ),
          const SizedBox(height: 8),
          darkTextBtn('远程通道设置（Cloudflare Tunnel）', () {
            showTunnelSettingsDialog(context);
          }),
          const Divider(height: 24),
          // 账号列表
          Row(
            children: [
              const Text('同步账号', style: TextStyle(color: kTextMain, fontSize: 14)),
              const Spacer(),
              darkTextBtn('新建账号', _busy ? () {} : _createAccount),
            ],
          ),
          const SizedBox(height: 8),
          if (_accounts.isEmpty)
            const Text('暂无账号。点「新建账号」创建一个，手机扫码即可绑定。',
                style: TextStyle(color: kTextSub, fontSize: 12)),
          for (final acc in _accounts)
            _AccountRow(
              id: (acc['id'] ?? '').toString(),
              name: (acc['name'] ?? '').toString(),
              onPair: () => _showPairQr((acc['id'] ?? '').toString(), (acc['name'] ?? '').toString()),
              onDelete: () => _deleteAccount((acc['id'] ?? '').toString(), (acc['name'] ?? '').toString()),
            ),
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_status, style: const TextStyle(color: kTextSub, fontSize: 12)),
          ],
          const SizedBox(height: 8),
          const Text(
            '数据按「账号 / 日期 / 工程」自动归档，存于应用数据目录 ovimap-sync/。\n手机端只追加不修改；冲突时服务端保留双份，在此手动处理。',
            style: TextStyle(color: kTextHint, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.id,
    required this.name,
    required this.onPair,
    required this.onDelete,
  });

  final String id;
  final String name;
  final VoidCallback onPair;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: kCardBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(color: kTextMain, fontSize: 13)),
                Text(id, style: const TextStyle(color: kTextHint, fontSize: 10)),
              ],
            ),
          ),
          darkTextBtn('配对码', onPair),
          const SizedBox(width: 4),
          darkTextBtn('删除', onDelete, color: kDanger),
        ],
      ),
    );
  }
}

/// 配对二维码展示（含 6 位码 + 地址）。
class _PairQrView extends StatelessWidget {
  const _PairQrView({
    required this.payloadJson,
    required this.code,
    required this.lanUrl,
    this.remoteUrl,
  });

  final String payloadJson;
  final String code;
  final String lanUrl;
  final String? remoteUrl;

  @override
  Widget build(BuildContext context) {
    final qrImage = QrImage(QrCode(payload: QrPayload.fromString(payloadJson)));
    final n = qrImage.moduleCount;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: 220, height: 220,
            child: CustomPaint(painter: _QrPainter(qrImage, n)),
          ),
        ),
        const SizedBox(height: 12),
        Text('配对码：$code',
            style: const TextStyle(color: kTextMain, fontSize: 20, letterSpacing: 4)),
        const SizedBox(height: 8),
        Text('局域网：$lanUrl', style: const TextStyle(color: kTextSub, fontSize: 12)),
        if (remoteUrl != null)
          Text('远程：$remoteUrl', style: const TextStyle(color: kTextSub, fontSize: 12)),
        const SizedBox(height: 4),
        const Text('手机打开同步面板 → 扫码配对，对准此二维码即可。',
            style: TextStyle(color: kTextHint, fontSize: 11)),
      ],
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image, this.n);
  final QrImage image;
  final int n;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black;
    final cell = size.width / n;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (image.isDark(r, c)) {
          canvas.drawRect(Rect.fromLTWH(c * cell, r * cell, cell, cell), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
