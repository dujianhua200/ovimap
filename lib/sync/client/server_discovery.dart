/// UDP 局域网发现（手机客户端）。
///
/// 服务端（Windows）每 5s 在 `255.255.255.255:47821` 广播
/// `OVIMAP_SYNC/1 <name> <port>`；手机监听一个窗口后列出发现的服务器。
/// [parseBeacon] 是纯函数，可零网络单测。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../sync_protocol.dart';

/// 发现到的服务器。
class DiscoveredServer {
  const DiscoveredServer({
    required this.name,
    required this.host,
    required this.port,
  });

  /// 服务端广播的显示名。
  final String name;

  /// 取自 UDP 包源 IP。
  final String host;

  /// 服务端 HTTP 端口。
  final int port;

  /// `http://<host>:<port>`（局域网内明文 HTTP）。
  String get baseUrl => 'http://$host:$port';

  @override
  String toString() => 'DiscoveredServer($name @ $baseUrl)';
}

/// 解析一条发现广播。
///
/// [msg] 为广播文本（`OVIMAP_SYNC/1 <name> <port>`），[srcIp] 为 UDP 包源 IP。
/// 格式不对 → 返回 null（不抛）。
DiscoveredServer? parseBeacon(String msg, String srcIp) {
  final parts = msg.trim().split(RegExp(r'\s+'));
  if (parts.length != 3) return null;
  if (parts[0] != kDiscoveryMagic) return null;
  final name = parts[1];
  final port = int.tryParse(parts[2]);
  if (name.isEmpty) return null;
  if (port == null || port <= 0 || port > 65535) return null;
  if (srcIp.isEmpty) return null;
  return DiscoveredServer(name: name, host: srcIp, port: port);
}

/// 监听发现端口 [timeout]，返回去重后的服务器列表。
///
/// 同一 `host:port` 多次广播只保留一条。监听期间的 socket 错误吞掉
/// （搜不到 → 调用方提示手动输入）。
Future<List<DiscoveredServer>> discover({
  Duration timeout = kDiscoveryListenWindow,
}) async {
  final found = <String, DiscoveredServer>{};
  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      kSyncDiscoveryPort,
    );
  } catch (_) {
    return const <DiscoveredServer>[];
  }
  final s = sock;
  final sub = s.listen((event) {
    if (event != RawSocketEvent.read) return;
    try {
      final dg = s.receive();
      if (dg == null) return;
      final msg = utf8.decode(dg.data, allowMalformed: true);
      final hit = parseBeacon(msg, dg.address.address);
      if (hit != null) found['${hit.host}:${hit.port}'] = hit;
    } catch (_) {
      // 单条坏包不影响继续监听。
    }
  });
  await Future<void>.delayed(timeout);
  await sub.cancel();
  s.close();
  return found.values.toList();
}
