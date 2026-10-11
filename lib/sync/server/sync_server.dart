/// 同步服务端 HTTP 服务（Windows 内嵌，设计稿 §2.1/§2.2/§2.6）。
///
/// 实现与既有 [SyncApi] 客户端兼容的同一套 REST 协议：
/// `GET /ping`、`/index`、`/project/:cid`（`PUT`/`DELETE` 带 `baseRev` 乐观并发，
/// 判据复用 [revAccepts]）、`/history`、`/restore`，统一响应体
/// `{code, data, message}`，`Authorization: Bearer <账号token>` 鉴权。
///
/// 新增：`POST /pair`（配对码换 token）、照片分块上传
/// （`.../photos/init|chunk|status|complete`）、`GET /ws`（进度推送）。
///
/// 所有 handler 异常统一转 500 中文响应，不抛到 shelf。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../sync_protocol.dart';
import '../sync_models.dart';
import 'pairing.dart';
import 'photo_upload.dart';
import 'server_store.dart';

/// 服务端标识（`GET /ping` 返回）。
const String kSyncServerName = 'ovimap-sync-server';

/// `SyncServer` 未显式传版本时的占位。
const String kSyncServerVersionUnknown = 'dev';

/// 统一响应体。
Response _ok(Object? data, [String message = 'ok']) => Response.ok(
      jsonEncode({'code': 0, 'data': data, 'message': message}),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
    );

Response _fail(int httpStatus, int code, String message,
        [Object? data]) =>
    Response(
      httpStatus,
      body: jsonEncode(
          {'code': code, 'data': data ?? <String, dynamic>{}, 'message': message}),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
    );

/// Windows 同步服务端。
///
/// 用法：
/// ```dart
/// final server = SyncServer(store: store, pairing: pairing, photos: photos, tokens: tokens);
/// await server.start(port: 47820);
/// // ...
/// await server.stop();
/// ```
///
/// 测试可直接调 [handler]（不绑端口）。
class SyncServer {
  SyncServer({
    required this._store,
    required this._pairing,
    required this._photos,
    required this._tokens,
    this.serverName = kSyncServerName,
    this.version = kSyncServerVersionUnknown,
    this.onProgress,
  });

  final ServerStore _store;
  final PairingService _pairing;
  final PhotoUploadManager _photos;
  final TokenStore _tokens;

  /// 服务端名称（UDP 发现广播用）。
  final String serverName;

  /// 版本（`/ping` 返回）。
  final String version;

  /// 进度/事件回调（默认走 WebSocket 广播；测试可注入）。
  final void Function(Map<String, dynamic> event)? onProgress;

  HttpServer? _http;
  final Set<WebSocketChannel> _sockets = {};

  bool get running => _http != null;

  int get port => _http?.port ?? -1;

  /// shelf handler（测试直调用；[start] 内部同样使用）。
  Handler get handler => _buildHandler();

  Future<void> start({int port = kSyncServerPort}) async {
    if (running) return;
    _http = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
    serverLog('服务已启动：http://0.0.0.0:${_http!.port}');
  }

  Future<void> stop() async {
    final http = _http;
    _http = null;
    for (final s in _sockets.toList()) {
      try {
        await s.sink.close();
      } catch (_) {}
    }
    _sockets.clear();
    await http?.close(force: true);
    serverLog('服务已停止');
  }

  /// 向所有 WebSocket 客户端推送事件（如照片上传进度）。
  void broadcast(Map<String, dynamic> event) {
    final payload = jsonEncode(event);
    for (final s in _sockets.toList()) {
      try {
        s.sink.add(payload);
      } catch (_) {
        _sockets.remove(s);
      }
    }
    onProgress?.call(event);
  }

  // ===================== 路由 =====================

  Handler _buildHandler() {
    final router = Router()
      ..get(kPathPing, _ping)
      ..get(kPathIndex, _index)
      ..get('/project/<cid>', _getProject)
      ..put('/project/<cid>', _putProject)
      ..delete('/project/<cid>', _deleteProject)
      ..get('/project/<cid>/history', _history)
      ..post('/project/<cid>/restore', _restore)
      ..post(kPathPair, _pair)
      ..post('/project/<cid>/photos/init', _photoInit)
      ..put('/project/<cid>/photos/<uid>/chunk/<i>', _photoChunk)
      ..get('/project/<cid>/photos/<uid>/status', _photoStatus)
      ..post('/project/<cid>/photos/<uid>/complete', _photoComplete)
      ..get(kPathWs, _ws);

    final withAuth = _authMiddleware();
    return const Pipeline()
        .addMiddleware(logRequests(logger: _logLine))
        .addMiddleware(withAuth)
        .addHandler(_safeOuter(router.call));
  }

  /// 外层兜底：任何未捕获异常 → 500 中文，不抛到 shelf。
  Handler _safeOuter(Handler inner) => (Request req) async {
        try {
          return await inner(req);
        } catch (e) {
          serverLog('未捕获异常 ${req.method} ${req.requestedUri.path}：$e');
          return _fail(500, 500, '服务器内部错误：$e');
        }
      };

  /// 鉴权中间件：除 `/ping`、`/pair` 外一律要求 `Authorization: Bearer <token>`。
  Middleware _authMiddleware() => (Handler inner) => (Request req) async {
        final path = req.requestedUri.path;
        if (path == kPathPing || path == kPathPair) {
          return inner(req);
        }
        final auth = req.headers['authorization'] ?? '';
        final token = auth.startsWith('Bearer ')
            ? auth.substring('Bearer '.length).trim()
            : '';
        if (token.isEmpty) {
          return _fail(401, 401, '未授权：缺少同步令牌（Authorization: Bearer）');
        }
        final accountId = await _store.accountIdForToken(_tokens, token);
        if (accountId == null) {
          serverLog('鉴权失败 token=${maskToken(token)}');
          return _fail(401, 401, '未授权：同步令牌无效');
        }
        return inner(req.change(context: {
          ...req.context,
          'accountId': accountId,
        }));
      };

  static void _logLine(String message, bool isError) {
    // 日志里不打 token：shelf 的 logRequests 只记方法/路径/耗时，无 header。
    serverLog(message);
  }

  String _accountId(Request req) => req.context['accountId'] as String;

  Future<Map<String, dynamic>> _readJson(Request req) async {
    final body = await req.readAsString();
    if (body.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(body);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const FormatException('请求体不是 JSON 对象');
  }

  /// 单个 handler 的异常 → 业务状态码（中文）。
  Future<Response> _guard(Future<Response> Function() fn) async {
    try {
      return await fn();
    } on PairingException catch (e) {
      return _fail(400, 400, e.message);
    } on PhotoUploadException catch (e) {
      return _fail(e.httpStatus, e.httpStatus, e.message);
    } on FormatException catch (e) {
      return _fail(400, 400, '请求格式错误：${e.message}');
    } catch (e) {
      serverLog('handler 异常：$e');
      return _fail(500, 500, '服务器内部错误：$e');
    }
  }

  // ===================== 基础 =====================

  Future<Response> _ping(Request req) =>
      _guard(() async => _ok({'name': serverName, 'version': version}));

  Future<Response> _index(Request req) => _guard(() async {
        final accountId = _accountId(req);
        final since =
            int.tryParse(req.requestedUri.queryParameters['since'] ?? '');
        var items = await _store.buildIndex(accountId);
        if (since != null) {
          items = [
            for (final e in items)
              if (((e['updatedAt'] as num?)?.toInt() ?? 0) > since) e
          ];
        }
        return _ok({'items': items});
      });

  // ===================== 工程 =====================

  Future<Response> _getProject(Request req) => _guard(() async {
        final accountId = _accountId(req);
        final cid = req.params['cid'] ?? '';
        final rev = int.tryParse(req.requestedUri.queryParameters['rev'] ?? '');
        final ServerSnapshot? s;
        if (rev != null) {
          s = await _store.snapshotOfRev(accountId, cid, rev);
        } else {
          s = await _store.latestSnapshot(accountId, cid);
        }
        if (s == null) return _fail(404, 404, '工程不存在：$cid');
        return _ok(_snapshotToData(s));
      });

  Map<String, dynamic> _snapshotToData(ServerSnapshot s) => {
        'id': s.id,
        'rev': s.rev,
        'updatedAt': s.updatedAt,
        'lastDeviceId': s.lastDeviceId,
        'lastDeviceName': s.lastDeviceName,
        'meta': s.meta,
        'payload': s.payload,
        'deleted': s.deleted,
      };

  Future<Response> _putProject(Request req) => _guard(() async {
        final accountId = _accountId(req);
        final cid = req.params['cid'] ?? '';
        if (cid.isEmpty) return _fail(400, 400, '工程 id 不能为空');
        final body = await _readJson(req);
        final Object? rawBaseRev = body['baseRev'];
        final int? baseRev =
            rawBaseRev is num ? rawBaseRev.toInt() : null;

        final current = await _store.latestSnapshot(accountId, cid);
        final currentRev = current?.rev ?? 0;
        if (!revAccepts(baseRev: baseRev, currentRev: currentRev)) {
          // 409：留双份——把客户端试图上传的快照存为冲突快照。
          final attempted = ServerSnapshot(
            id: cid,
            rev: currentRev,
            updatedAt: (body['updatedAt'] as num?)?.toInt() ?? 0,
            lastDeviceId: (body['deviceId'] as String?) ?? '',
            lastDeviceName: (body['deviceName'] as String?) ?? '',
            meta: {
              'name': body['name'],
              'kind': body['kind'],
              'folder': body['folder'],
              'editMode': body['editMode'],
              'count': body['count'],
            },
            payload: (body['payload'] as String?) ?? '',
          );
          final conflictName = await _store.saveConflictSnapshot(
            accountId,
            attempted,
            serverRev: currentRev,
          );
          serverLog('PUT 冲突 $cid：baseRev=$baseRev ≠ serverRev=$currentRev，'
              '已留双份 $conflictName');
          return _fail(409, 409, '版本冲突：服务端已有更新', {
            'serverRev': currentRev,
            'serverUpdatedAt': current?.updatedAt ?? 0,
            'serverDeviceName': current?.lastDeviceName ?? '',
            'serverDeviceId': current?.lastDeviceId ?? '',
            'conflictSnapshot': conflictName,
          });
        }

        final next = ServerSnapshot(
          id: cid,
          rev: currentRev + 1,
          updatedAt: (body['updatedAt'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
          lastDeviceId: (body['deviceId'] as String?) ?? '',
          lastDeviceName: (body['deviceName'] as String?) ?? '',
          meta: {
            'name': (body['name'] as String?) ?? '',
            'kind': (body['kind'] as String?) ?? 'label',
            'folder': (body['folder'] as String?) ?? '',
            'editMode': (body['editMode'] as String?) ?? '',
            'count': (body['count'] as num?)?.toInt() ?? 0,
          },
          payload: (body['payload'] as String?) ?? '',
        );
        await _store.saveSnapshot(accountId, next);
        broadcast({
          'type': 'progress',
          'op': 'put',
          'cid': cid,
          'rev': next.rev,
          'accountId': accountId,
        });
        return _ok({'rev': next.rev});
      });

  Future<Response> _deleteProject(Request req) => _guard(() async {
        final accountId = _accountId(req);
        final cid = req.params['cid'] ?? '';
        final body = await _readJson(req);
        final Object? rawBaseRev = body['baseRev'];
        final int? baseRev = rawBaseRev is num ? rawBaseRev.toInt() : null;

        final current = await _store.latestSnapshot(accountId, cid);
        if (current == null) return _fail(404, 404, '工程不存在：$cid');
        if (!revAccepts(baseRev: baseRev, currentRev: current.rev)) {
          return _fail(409, 409, '版本冲突：服务端已有更新', {
            'serverRev': current.rev,
            'serverUpdatedAt': current.updatedAt,
            'serverDeviceName': current.lastDeviceName,
            'serverDeviceId': current.lastDeviceId,
          });
        }
        // 软删：rev+1 的 tombstone 快照。
        final tombstone = ServerSnapshot(
          id: cid,
          rev: current.rev + 1,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          lastDeviceId: (body['deviceId'] as String?) ?? '',
          lastDeviceName: (body['deviceName'] as String?) ?? '',
          meta: current.meta,
          payload: '',
          deleted: true,
        );
        await _store.saveSnapshot(accountId, tombstone);
        broadcast({
          'type': 'progress',
          'op': 'delete',
          'cid': cid,
          'rev': tombstone.rev,
          'accountId': accountId,
        });
        return _ok({'rev': tombstone.rev});
      });

  Future<Response> _history(Request req) => _guard(() async {
        final accountId = _accountId(req);
        final cid = req.params['cid'] ?? '';
        final versions = await _store.history(accountId, cid);
        if (versions.isEmpty) return _fail(404, 404, '工程不存在：$cid');
        return _ok({'versions': versions});
      });

  Future<Response> _restore(Request req) => _guard(() async {
        final accountId = _accountId(req);
        final cid = req.params['cid'] ?? '';
        final body = await _readJson(req);
        final rev = (body['rev'] as num?)?.toInt();
        if (rev == null) return _fail(400, 400, '缺少 rev 参数');
        final old = await _store.snapshotOfRev(accountId, cid, rev);
        if (old == null) return _fail(404, 404, '版本不存在：rev=$rev');
        final current = await _store.latestSnapshot(accountId, cid);
        final next = ServerSnapshot(
          id: cid,
          rev: (current?.rev ?? 0) + 1,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          lastDeviceId: (body['deviceId'] as String?) ?? '',
          lastDeviceName: (body['deviceName'] as String?) ?? '',
          meta: old.meta,
          payload: old.payload,
        );
        await _store.saveSnapshot(accountId, next);
        serverLog('恢复工程 $cid 到 rev=$rev（新 rev=${next.rev}）');
        return _ok({'rev': next.rev});
      });

  // ===================== 配对 =====================

  Future<Response> _pair(Request req) => _guard(() async {
        final body = await _readJson(req);
        final accountId = (body['accountId'] as String?) ?? '';
        final code = (body['code'] as String?) ?? '';
        final deviceId = (body['deviceId'] as String?) ?? '';
        final deviceName = (body['deviceName'] as String?) ?? '';
        if (accountId.isEmpty || code.isEmpty) {
          return _fail(400, 400, '缺少 accountId 或 code');
        }
        final token =
            await _pairing.redeemPairCode(accountId, code, deviceId, deviceName);
        return _ok({'token': token, 'accountId': accountId}, '配对成功');
      });

  // ===================== 照片 =====================

  Future<Response> _photoInit(Request req) => _guard(() async {
        // 照片路由与工程路由同账号鉴权（中间件已做）；cid 归属由落盘路径自然隔离。
        final accountId = _accountId(req);
        final cid = req.params['cid'] ?? '';
        final body = await _readJson(req);
        final r = await _photos.init(
          accountId,
          cid,
          filename: (body['filename'] as String?) ?? '',
          size: (body['size'] as num?)?.toInt() ?? 0,
          sha256: (body['sha256'] as String?) ?? '',
        );
        return _ok(r);
      });

  Future<Response> _photoChunk(Request req) => _guard(() async {
        _accountId(req); // 鉴权（中间件已做），顺带触发 401
        final uid = req.params['uid'] ?? '';
        final i = int.tryParse(req.params['i'] ?? '');
        if (i == null) return _fail(400, 400, '分块序号非法');
        final bytes = await req.read().expand((e) => e).toList();
        final done = await _photos.putChunk(uid, i, bytes);
        broadcast({
          'type': 'progress',
          'op': 'photo-chunk',
          'uploadId': uid,
          'done': done,
        });
        return _ok({'done': done});
      });

  Future<Response> _photoStatus(Request req) => _guard(() async {
        _accountId(req);
        final uid = req.params['uid'] ?? '';
        return _ok(_photos.status(uid));
      });

  Future<Response> _photoComplete(Request req) => _guard(() async {
        final accountId = _accountId(req);
        final uid = req.params['uid'] ?? '';
        final r = await _photos.complete(uid);
        broadcast({
          'type': 'progress',
          'op': 'photo-complete',
          'uploadId': uid,
          'accountId': accountId,
          'sha256': r['sha256'],
        });
        return _ok(r, '照片上传完成');
      });

  // ===================== WebSocket =====================

  Future<Response> _ws(Request req) => _guard(() async {
        // shelf_web_socket 接管：401 已在中间件处理。
        final handler = webSocketHandler((WebSocketChannel ws, String? _) {
          _sockets.add(ws);
          serverLog('WebSocket 客户端接入（当前 ${_sockets.length} 个）');
          ws.sink.add(jsonEncode({
            'type': 'hello',
            'server': serverName,
            'version': version,
          }));
          ws.stream.listen(
            (_) {},
            onDone: () {
              _sockets.remove(ws);
              serverLog('WebSocket 客户端断开（剩余 ${_sockets.length} 个）');
            },
            onError: (_) => _sockets.remove(ws),
            cancelOnError: true,
          );
        });
        return handler(req);
      });
}

/// UDP 局域网发现广播（设计稿 §2.5）。
///
/// 服务端每 5s 向 `255.255.255.255:47821` 广播
/// `OVIMAP_SYNC/1 <serverName> <port>`；手机端监听 3s 列出服务器。
class DiscoveryBeacon {
  DiscoveryBeacon({
    required this.serverName,
    required this.port,
    this.interval = kDiscoveryBeaconInterval,
  });

  final String serverName;
  final int port;
  final Duration interval;

  RawDatagramSocket? _socket;
  Timer? _timer;

  bool get running => _timer != null;

  /// 广播报文（纯函数，手机端解析/单测用）。
  String beaconMessage() => '$kDiscoveryMagic $serverName $port';

  /// 解析广播报文 → `(serverName, port)`；格式不对 → null。
  static ({String serverName, int port})? parseBeacon(String message) {
    final parts = message.trim().split(RegExp(r'\s+'));
    if (parts.length != 3 || parts[0] != kDiscoveryMagic) return null;
    final port = int.tryParse(parts[2]);
    if (port == null || port <= 0 || port > 65535) return null;
    return (serverName: parts[1], port: port);
  }

  Future<void> start() async {
    if (running) return;
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket!.broadcastEnabled = true;
    _send();
    _timer = Timer.periodic(interval, (_) => _send());
    serverLog('UDP 发现广播已启动（:$kSyncDiscoveryPort，每 ${interval.inSeconds}s）');
  }

  void _send() {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.send(
        utf8.encode(beaconMessage()),
        InternetAddress('255.255.255.255'),
        kSyncDiscoveryPort,
      );
    } catch (e) {
      serverLog('UDP 广播失败：$e');
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
    serverLog('UDP 发现广播已停止');
  }
}
