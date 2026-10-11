/// 配对客户端（手机端）：二维码解析 + `POST /pair` + 配对编排。
///
/// 二维码载荷（设计稿 §2.3）：`{v:1, name, accountId, code, lan, remote}`，
/// 手机优先用 lan，失败/缺失时用 remote。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/device_identity.dart';
import '../../services/secure_store.dart';
import '../sync_protocol.dart';

/// 二维码/配对流程异常（message 均为中文，直接展示）。
class PairingException implements Exception {
  PairingException(this.message);
  final String message;

  @override
  String toString() => 'PairingException: $message';
}

/// 扫码得到的配对信息。
class QrPairPayload {
  const QrPairPayload({
    required this.name,
    required this.accountId,
    required this.code,
    required this.lan,
    required this.remote,
  });

  /// 服务端显示名（配对码弹窗上的名字）。
  final String name;

  /// 账号 id（`acc-<随机>`）。
  final String accountId;

  /// 6 位数字配对码（一次性，5 分钟有效）。
  final String code;

  /// 局域网地址（`http://192.168.x.x:47820`），可能为空。
  final String lan;

  /// 远程地址（Tunnel 域名，`https://...`），可能为空。
  final String remote;

  /// 优先地址：lan 优先，其次 remote。
  String get preferredBase => lan.isNotEmpty ? lan : remote;
}

/// 解析二维码文本为 [QrPairPayload]；字段缺失/非法 → 抛中文 [PairingException]。
QrPairPayload parseQrPayload(String text) {
  final raw = text.trim();
  if (raw.isEmpty) throw PairingException('二维码内容为空');
  Map<String, dynamic> m;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('not a map');
    m = Map<String, dynamic>.from(decoded);
  } catch (_) {
    throw PairingException('二维码不是有效的配对信息（JSON 解析失败）');
  }
  if ((m['v'] as num?)?.toInt() != kQrPayloadVersion) {
    throw PairingException('二维码版本不支持（需要 v$kQrPayloadVersion）');
  }
  final accountId = (m['accountId'] as String? ?? '').trim();
  final code = (m['code'] as String? ?? '').trim();
  final lan = (m['lan'] as String? ?? '').trim();
  final remote = (m['remote'] as String? ?? '').trim();
  if (accountId.isEmpty) throw PairingException('二维码缺少账号 ID');
  if (!RegExp(r'^\d{6}$').hasMatch(code)) {
    throw PairingException('配对码格式错误（应为 6 位数字）');
  }
  if (lan.isEmpty && remote.isEmpty) throw PairingException('二维码缺少服务器地址');
  return QrPairPayload(
    name: (m['name'] as String? ?? '').trim(),
    accountId: accountId,
    code: code,
    lan: lan,
    remote: remote,
  );
}

/// 配对客户端：`POST /pair` 换账号 token。
///
/// [client] 可注入（测试用 `MockClient`）；缺省新建。
class PairingClient {
  PairingClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// 配对：成功返回账号 token；失败抛中文 [PairingException]。
  Future<String> pair({
    required String baseUrl,
    required String accountId,
    required String code,
    required String deviceId,
    required String deviceName,
  }) async {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) throw PairingException('服务器地址为空');
    late http.Response r;
    try {
      r = await _client.post(
        Uri.parse('$base$kPathPair'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'accountId': accountId,
          'code': code,
          'deviceId': deviceId,
          'deviceName': deviceName,
        }),
      );
    } catch (e) {
      throw PairingException('连接服务器失败：$e');
    }
    Map<String, dynamic>? env;
    try {
      final decoded = jsonDecode(utf8.decode(r.bodyBytes));
      if (decoded is Map) env = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    if (r.statusCode == 401) {
      throw PairingException('配对码错误、已过期或已被使用，请重新获取');
    }
    final bizCode = (env?['code'] as num?)?.toInt();
    if (r.statusCode >= 400 || (bizCode != null && bizCode != 0)) {
      final msg = (env?['message'] as String? ?? '').trim();
      throw PairingException(
        msg.isEmpty ? '配对失败（HTTP ${r.statusCode}）' : '配对失败：$msg',
      );
    }
    final data = env?['data'];
    final token = data is Map ? (data['token'] as String? ?? '').trim() : '';
    if (token.isEmpty) throw PairingException('配对失败：服务端未返回令牌');
    return token;
  }

  /// 完整配对编排：配对 → token 经 [SecureStore] 安全存储（Worker C 实现，
  /// Windows Credential Manager / Android Keystore）→
  /// `DeviceIdentity.saveConfig(token:, serverBase:)`。
  ///
  /// [baseUrlOverride] 非空时覆盖二维码里的地址（手动输入/局域网发现场景）。
  Future<void> completePairing({
    required QrPairPayload payload,
    String? baseUrlOverride,
    required DeviceIdentity identity,
    required SecureStore secureStore,
  }) async {
    final base = (baseUrlOverride ?? '').trim().isNotEmpty
        ? baseUrlOverride!.trim()
        : payload.preferredBase;
    if (base.isEmpty) throw PairingException('服务器地址为空');
    final token = await pair(
      baseUrl: base,
      accountId: payload.accountId,
      code: payload.code,
      deviceId: identity.deviceId,
      deviceName: identity.deviceName,
    );
    await secureStore.write(accountTokenKey(payload.accountId), token);
    await identity.saveConfig(token: token, serverBase: base);
  }
}
