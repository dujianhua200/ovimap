import 'dart:convert';

import '../sync_protocol.dart';

/// 配对二维码载荷（JSON 字符串，Worker B 的配对页调用）。
///
/// 字段与设计稿 §2.3 一致：`{v, name, accountId, code, lan, remote}`，
/// 手机优先用 `lan`，失败切 `remote`。
///
/// 纯函数、无 UI/IO 依赖，方便单测。
///
/// [remoteUrl] 由调用方从 prefs（`syncTunnelUrl`）读取后传入；
/// 为空时 `remote` 为空字符串（手机端仅用局域网地址）。
String buildQrPayload({
  required String accountId,
  required String code,
  String? name,
  String? lanUrl,
  String? remoteUrl,
}) {
  return jsonEncode(<String, Object>{
    'v': kQrPayloadVersion,
    'name': name ?? '',
    'accountId': accountId,
    'code': code,
    'lan': lanUrl ?? '',
    'remote': remoteUrl ?? '',
  });
}
