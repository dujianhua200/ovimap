/// 扫码配对页（手机端）。
///
/// 上半：[MobileScanner] 全屏取景，扫到二维码自动解析配对（防重复触发）。
/// 下半：模式切换 ——「扫码」/「手动输入」（6 位码 + 账号 ID + 服务器地址），
/// 手动模式下可「从局域网发现」点选服务器填入地址。
///
/// 配对成功 → token 经 [SecureStore] 存储 →
/// `DeviceIdentity.saveConfig(token:, serverBase:)` → 返回 true。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/device_identity.dart';
import '../../services/secure_store.dart';
import '../../sync/client/pairing_client.dart';
import '../../sync/client/server_discovery.dart';
import '../dialogs.dart';
import '../design_tokens.dart';

/// 打开扫码配对页；配对成功返回 true。
Future<bool?> showPairingPage(BuildContext context) =>
    Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const PairingPage()));

class PairingPage extends StatefulWidget {
  const PairingPage({super.key});

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  bool _manual = false; // false=扫码模式，true=手动输入模式
  bool _handled = false; // 防扫码重复触发
  bool _busy = false;
  bool _discovering = false;
  String _error = '';

  final _codeCtl = TextEditingController();
  final _accountCtl = TextEditingController();
  final _baseCtl = TextEditingController();

  // 安全存储：Worker C 的 flutter_secure_storage 封装
  //（Windows Credential Manager / Android Keystore）。
  final SecureStore _secureStore = SecureStore.instance;
  final PairingClient _pairing = PairingClient();

  @override
  void dispose() {
    _codeCtl.dispose();
    _accountCtl.dispose();
    _baseCtl.dispose();
    super.dispose();
  }

  // ===================== 扫码 =====================

  void _onDetect(BarcodeCapture capture) {
    if (_handled || _busy) return;
    String? raw;
    for (final b in capture.barcodes) {
      if ((b.rawValue ?? '').trim().isNotEmpty) {
        raw = b.rawValue!.trim();
        break;
      }
    }
    if (raw == null) return;
    _handled = true; // 先占位，防同一帧/连续帧重复触发
    _pairFromQr(raw);
  }

  Future<void> _pairFromQr(String raw) async {
    QrPairPayload payload;
    try {
      payload = parseQrPayload(raw);
    } on PairingException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _handled = false; // 解析失败允许重扫
      });
      return;
    }
    await _doPair(
      baseUrl: payload.preferredBase,
      accountId: payload.accountId,
      code: payload.code,
      payload: payload,
    );
    // 配对失败（网络/码错误）允许重扫。
    if (mounted && _error.isNotEmpty) setState(() => _handled = false);
  }

  // ===================== 手动输入 =====================

  Future<void> _pairManual() async {
    final code = _codeCtl.text.trim();
    final accountId = _accountCtl.text.trim();
    final base = _baseCtl.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = '配对码应为 6 位数字');
      return;
    }
    if (accountId.isEmpty) {
      setState(() => _error = '请填写账号 ID');
      return;
    }
    if (base.isEmpty) {
      setState(() => _error = '请填写服务器地址');
      return;
    }
    await _doPair(baseUrl: base, accountId: accountId, code: code);
  }

  Future<void> _doPair({
    required String baseUrl,
    required String accountId,
    required String code,
    QrPairPayload? payload,
  }) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final id = DeviceIdentity.instance;
      if (!id.loaded) await id.load();
      final p =
          payload ??
          QrPairPayload(
            name: '',
            accountId: accountId,
            code: code,
            lan: baseUrl,
            remote: '',
          );
      await _pairing.completePairing(
        payload: p,
        baseUrlOverride: payload == null ? baseUrl : null,
        identity: id,
        secureStore: _secureStore,
      );
      if (!mounted) return;
      toast(context, '配对成功，已连接到 $baseUrl');
      Navigator.of(context).pop(true);
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '配对失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ===================== 局域网发现 =====================

  Future<void> _discover() async {
    if (_discovering) return;
    setState(() {
      _discovering = true;
      _error = '';
    });
    List<DiscoveredServer> found;
    try {
      found = await discover();
    } catch (e) {
      found = const <DiscoveredServer>[];
    }
    if (!mounted) return;
    setState(() => _discovering = false);
    if (found.isEmpty) {
      setState(() => _error = '未发现局域网服务器，请确认电脑端服务已启动，或手动输入地址');
      return;
    }
    final picked = await showDialog<DiscoveredServer>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kPanelBg,
        title: Text(
          '发现的服务器（${found.length}）',
          style: const TextStyle(color: kTextMain, fontSize: 16),
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in found)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.computer, color: kAccent, size: 20),
                  title: Text(
                    s.name,
                    style: const TextStyle(color: kTextMain, fontSize: 13.5),
                  ),
                  subtitle: Text(
                    s.baseUrl,
                    style: const TextStyle(color: kTextSub, fontSize: 11.5),
                  ),
                  onTap: () => Navigator.of(ctx).pop(s),
                ),
            ],
          ),
        ),
        actions: [
          darkTextBtn('取消', () => Navigator.of(ctx).pop(), color: kTextSub),
        ],
      ),
    );
    if (picked != null && mounted) {
      setState(() => _baseCtl.text = picked.baseUrl);
    }
  }

  // ===================== 构建 =====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('扫码配对'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _manual = !_manual;
                    _error = '';
                  }),
            child: Text(
              _manual ? '扫码' : '手动输入',
              style: const TextStyle(color: kAccent, fontSize: 13.5),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_manual)
            Expanded(
              child: Stack(
                children: [
                  MobileScanner(
                    onDetect: _onDetect,
                    errorBuilder: (ctx, e) => const ColoredBox(
                      color: Colors.black,
                      child: Center(
                        child: Text(
                          '摄像头不可用，请检查相机权限',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ),
                    ),
                  ),
                  // 取景框装饰
                  Center(
                    child: Container(
                      width: 240,
                      height: 240,
                      decoration: BoxDecoration(
                        border: Border.all(color: kAccent, width: 2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 18,
                    child: Text(
                      '将电脑端的配对二维码放入框内',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            )
          else
            Expanded(child: _buildManualForm()),
          _buildStatusBar(),
        ],
      ),
    );
  }

  Widget _buildManualForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '配对码（6 位数字，电脑端显示）',
            style: TextStyle(color: kTextSub, fontSize: 12),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _codeCtl,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(color: kTextMain, fontSize: 15),
            decoration: dec('如：482913'),
          ),
          const SizedBox(height: 12),
          const Text(
            '账号 ID（电脑端账号，如 acc-xxxx）',
            style: TextStyle(color: kTextSub, fontSize: 12),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _accountCtl,
            style: const TextStyle(color: kTextMain, fontSize: 13.5),
            decoration: dec('acc-'),
          ),
          const SizedBox(height: 12),
          const Text(
            '服务器地址（局域网 IP 或远程域名）',
            style: TextStyle(color: kTextSub, fontSize: 12),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _baseCtl,
            keyboardType: TextInputType.url,
            style: const TextStyle(color: kTextMain, fontSize: 13.5),
            decoration: dec('http://192.168.1.x:47820'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy || _discovering ? null : _pairManual,
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('配对'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy || _discovering ? null : _discover,
                  icon: _discovering
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: kAccent,
                          ),
                        )
                      : const Icon(Icons.radar, size: 18),
                  label: Text(_discovering ? '搜索中…' : '从局域网发现'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
            ),
            SizedBox(width: 10),
            Text('配对中…', style: TextStyle(color: kTextSub, fontSize: 12.5)),
          ],
        ),
      );
    }
    if (_error.isEmpty) return const SizedBox(height: 12);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
      child: Text(
        _error,
        textAlign: TextAlign.center,
        style: const TextStyle(color: TokC.danger, fontSize: 12.5, height: 1.5),
      ),
    );
  }
}
