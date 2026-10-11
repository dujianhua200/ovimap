// Windows 同步服务端路由级测试（直调 shelf handler，不绑真实端口）。
//
// 覆盖：配对流程（签发→兑换→二次兑换失败→过期失败）、PUT 乐观并发
// （200/409）、照片分块上传（含断点续传位图、缺块 400、sha256 校验）、
// 按日期归档（跨天 index 合并去重取最新）。

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';

import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/sync/server/pairing.dart';
import 'package:ovimap/sync/server/photo_upload.dart';
import 'package:ovimap/sync/server/server_store.dart';
import 'package:ovimap/sync/server/sync_server.dart';
import 'package:ovimap/sync/sync_protocol.dart';

/// 内存 TokenStore（测试替身；生产由 Worker C 的 secure_store 实现）。
class _MemTokenStore implements TokenStore {
  final Map<String, String> _map = {};

  @override
  Future<String?> readAccountToken(String accountId) async => _map[accountId];

  @override
  Future<void> writeAccountToken(String accountId, String token) async {
    _map[accountId] = token;
  }

  @override
  Future<void> deleteAccountToken(String accountId) async {
    _map.remove(accountId);
  }
}

class _Env {
  _Env({
    required this.tmp,
    required this.store,
    required this.tokens,
    required this.pairing,
    required this.photos,
    required this.server,
    required this.now,
  });

  final Directory tmp;
  final ServerStore store;
  final _MemTokenStore tokens;
  final PairingService pairing;
  final PhotoUploadManager photos;
  final SyncServer server;
  DateTime now;
}

Future<_Env> _makeEnv({DateTime? now}) async {
  final tmp = await Directory.systemTemp.createTemp('sync_server_test_');
  AppPaths.setBaseForTest(tmp);
  final fakeNow = now ?? DateTime(2026, 10, 11, 10, 0, 0);
  final store = ServerStore(now: () => fakeNow);
  final tokens = _MemTokenStore();
  final pairing = PairingService(
    store: store,
    tokens: tokens,
    now: () => fakeNow,
    random: Random(42),
    enableCleanupTimer: false,
  );
  final photos = PhotoUploadManager(store: store, random: Random(7));
  final server = SyncServer(
    store: store,
    pairing: pairing,
    photos: photos,
    tokens: tokens,
    serverName: 'test-pc',
    version: '4.0.23',
  );
  final env = _Env(
    tmp: tmp,
    store: store,
    tokens: tokens,
    pairing: pairing,
    photos: photos,
    server: server,
    now: fakeNow,
  );
  return env;
}

Future<({int status, Map<String, dynamic> json})> _call(
  _Env env,
  String method,
  String path, {
  Map<String, String>? headers,
  Object? body,
}) async {
  final req = Request(
    method,
    Uri.parse('http://localhost$path'),
    headers: headers,
    body: body,
  );
  final resp = await env.server.handler(req);
  final text = await resp.readAsString();
  return (status: resp.statusCode, json: Map<String, dynamic>.from(jsonDecode(text)));
}

Map<String, String> _auth(String token) =>
    {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};

Map<String, dynamic> _putBody(int baseRev, {String payload = '{}'}) => {
      'baseRev': baseRev,
      'name': '测试工程',
      'kind': 'label',
      'folder': '',
      'editMode': '',
      'count': 3,
      'payload': payload,
      'deviceId': 'dev-1',
      'deviceName': '测试手机',
      'updatedAt': 1000,
    };

void main() {
  // PairingService 的 now 闭包在 _makeEnv 里捕获局部变量 fakeNow；
  // 跨天测试需要可变的 now，这里用“重建 store/pairing”方式推进时间。
  group('配对流程', () {
    late _Env env;
    late String accountId;
    late String token;

    setUp(() async {
      env = await _makeEnv();
      final created = await env.pairing.createAccount('张三的电脑');
      accountId = created.accountId;
      token = created.token;
    });

    tearDown(() async {
      env.pairing.dispose();
      AppPaths.clearForTest();
      if (env.tmp.existsSync()) await env.tmp.delete(recursive: true);
    });

    test('createAccount 返回 64 位 hex token，accounts.json 不含密钥', () async {
      expect(token, hasLength(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(token), isTrue);
      final accounts = await env.store.readAccounts();
      expect(accounts, hasLength(1));
      expect(accounts.first['id'], accountId);
      expect(accounts.first['name'], '张三的电脑');
      expect(accounts.first.containsKey('token'), isFalse);
      // token 经 TokenStore 落安全存储。
      expect(await env.tokens.readAccountToken(accountId), token);
    });

    test('issue → redeem 成功返回 token；二次 redeem 失败', () async {
      final code = await env.pairing.issuePairCode(accountId);
      expect(code, hasLength(6));

      final ok = await _call(env, 'POST', '/pair', body: jsonEncode({
        'accountId': accountId,
        'code': code,
        'deviceId': 'dev-1',
        'deviceName': '测试手机',
      }));
      expect(ok.status, 200);
      expect(ok.json['code'], 0);
      expect(ok.json['data']['token'], token);

      // 二次兑换：code 已作废。
      final again = await _call(env, 'POST', '/pair', body: jsonEncode({
        'accountId': accountId,
        'code': code,
        'deviceId': 'dev-1',
        'deviceName': '测试手机',
      }));
      expect(again.status, 400);
      expect((again.json['message'] as String).contains('已使用'), isTrue);
    });

    test('过期 code 兑换失败（中文）', () async {
      DateTime clock = DateTime(2026, 10, 11, 10, 0, 0);
      final p = PairingService(
        store: env.store,
        tokens: env.tokens,
        now: () => clock,
        random: Random(99),
        enableCleanupTimer: false,
      );
      addTearDown(p.dispose);
      final code = await p.issuePairCode(accountId);
      clock = clock.add(const Duration(minutes: 6)); // 过期
      await expectLater(
        p.redeemPairCode(accountId, code, 'dev-1', '测试手机'),
        throwsA(isA<PairingException>().having(
            (e) => e.message, 'message', contains('过期'))),
      );
    });

    test('错误 code / 不存在账号 → 中文 400', () async {
      final bad = await _call(env, 'POST', '/pair', body: jsonEncode({
        'accountId': accountId,
        'code': '000000',
        'deviceId': 'dev-1',
        'deviceName': '测试手机',
      }));
      expect(bad.status, 400);
      expect(bad.json['message'], isNotEmpty);

      final noAcc = await _call(env, 'POST', '/pair', body: jsonEncode({
        'accountId': 'acc-not-exist',
        'code': '123456',
        'deviceId': 'dev-1',
        'deviceName': '测试手机',
      }));
      expect(noAcc.status, 400);
      expect((noAcc.json['message'] as String).contains('账号'), isTrue);
    });

    test('regenerateToken 后旧 token 失效', () async {
      final newToken = await env.pairing.regenerateToken(accountId);
      expect(newToken, isNot(equals(token)));

      final oldAuth = await _call(env, 'GET', '/index', headers: _auth(token));
      expect(oldAuth.status, 401);

      final newAuth =
          await _call(env, 'GET', '/index', headers: _auth(newToken));
      expect(newAuth.status, 200);
    });

    test('deleteAccount 后 token 失效、数据目录清空', () async {
      await env.pairing.deleteAccount(accountId);
      expect(await env.store.readAccounts(), isEmpty);
      expect(await env.tokens.readAccountToken(accountId), isNull);
      final r = await _call(env, 'GET', '/index', headers: _auth(token));
      expect(r.status, 401);
    });
  });

  group('鉴权与 ping', () {
    late _Env env;
    setUp(() async => env = await _makeEnv());
    tearDown(() async {
      env.pairing.dispose();
      AppPaths.clearForTest();
      if (env.tmp.existsSync()) await env.tmp.delete(recursive: true);
    });

    test('GET /ping 无需鉴权', () async {
      final r = await _call(env, 'GET', '/ping');
      expect(r.status, 200);
      expect(r.json['code'], 0);
      expect(r.json['data']['name'], 'test-pc');
      expect(r.json['data']['version'], '4.0.23');
    });

    test('无 Bearer → 401 中文；错 token → 401', () async {
      final noAuth = await _call(env, 'GET', '/index');
      expect(noAuth.status, 401);
      expect((noAuth.json['message'] as String).contains('未授权'), isTrue);

      final bad = await _call(env, 'GET', '/index',
          headers: _auth('deadbeef' * 8));
      expect(bad.status, 401);
    });
  });

  group('PUT 乐观并发', () {
    late _Env env;
    late String token;

    setUp(() async {
      env = await _makeEnv();
      final created = await env.pairing.createAccount('pc');
      token = created.token;
    });

    tearDown(() async {
      env.pairing.dispose();
      AppPaths.clearForTest();
      if (env.tmp.existsSync()) await env.tmp.delete(recursive: true);
    });

    test('baseRev 对上 200 递增；错开 409 并留双份', () async {
      // 新建：baseRev=0 → rev=1。
      var r = await _call(env, 'PUT', '/project/c1',
          headers: _auth(token), body: jsonEncode(_putBody(0)));
      expect(r.status, 200);
      expect(r.json['data']['rev'], 1);

      // 旧 baseRev → 409，data 带 serverRev；冲突快照落盘。
      r = await _call(env, 'PUT', '/project/c1',
          headers: _auth(token),
          body: jsonEncode(_putBody(0, payload: '{"v":2}')));
      expect(r.status, 409);
      expect(r.json['code'], 409);
      expect(r.json['data']['serverRev'], 1);
      final accId = (await env.store.readAccounts()).first['id'] as String;
      final realConflicts = await env.store.listConflictSnapshots(accId, 'c1');
      expect(realConflicts, hasLength(1));

      // baseRev=1 → 200 rev=2。
      r = await _call(env, 'PUT', '/project/c1',
          headers: _auth(token), body: jsonEncode(_putBody(1)));
      expect(r.status, 200);
      expect(r.json['data']['rev'], 2);

      // GET 最新 / 指定 rev。
      r = await _call(env, 'GET', '/project/c1', headers: _auth(token));
      expect(r.status, 200);
      expect(r.json['data']['rev'], 2);

      r = await _call(env, 'GET', '/project/c1?rev=1', headers: _auth(token));
      expect(r.status, 200);
      expect(r.json['data']['rev'], 1);

      // 不存在 → 404。
      r = await _call(env, 'GET', '/project/nope', headers: _auth(token));
      expect(r.status, 404);
    });

    test('DELETE 软删 rev+1；history/restore', () async {
      await _call(env, 'PUT', '/project/c2',
          headers: _auth(token), body: jsonEncode(_putBody(0)));
      await _call(env, 'PUT', '/project/c2',
          headers: _auth(token), body: jsonEncode(_putBody(1)));

      var r = await _call(env, 'DELETE', '/project/c2',
          headers: _auth(token),
          body: jsonEncode(
              {'baseRev': 2, 'deviceId': 'dev-1', 'deviceName': '测试手机'}));
      expect(r.status, 200);
      expect(r.json['data']['rev'], 3);

      r = await _call(env, 'GET', '/project/c2', headers: _auth(token));
      expect(r.json['data']['deleted'], isTrue);

      // DELETE baseRev 错开 → 409。
      r = await _call(env, 'DELETE', '/project/c2',
          headers: _auth(token),
          body: jsonEncode(
              {'baseRev': 1, 'deviceId': 'dev-1', 'deviceName': '测试手机'}));
      expect(r.status, 409);

      // history 倒序 3 条。
      r = await _call(env, 'GET', '/project/c2/history',
          headers: _auth(token));
      expect(r.status, 200);
      final versions = r.json['data']['versions'] as List;
      expect(versions.map((e) => e['rev']).toList(), [3, 2, 1]);

      // restore rev=1 → 新 rev=4。
      r = await _call(env, 'POST', '/project/c2/restore',
          headers: _auth(token),
          body: jsonEncode(
              {'rev': 1, 'deviceId': 'dev-1', 'deviceName': '测试手机'}));
      expect(r.status, 200);
      expect(r.json['data']['rev'], 4);

      r = await _call(env, 'GET', '/index', headers: _auth(token));
      final items = r.json['data']['items'] as List;
      final c2 = items.firstWhere((e) => e['id'] == 'c2');
      expect(c2['rev'], 4);
      expect(c2['deleted'], isFalse); // restore 后恢复非删除态
    });

    test('GET /index?since 过滤', () async {
      await _call(env, 'PUT', '/project/c3',
          headers: _auth(token), body: jsonEncode(_putBody(0)));
      var r = await _call(env, 'GET', '/index?since=9999999999999',
          headers: _auth(token));
      expect((r.json['data']['items'] as List), isEmpty);
      r = await _call(env, 'GET', '/index?since=0', headers: _auth(token));
      expect((r.json['data']['items'] as List), hasLength(1));
    });
  });

  group('照片分块上传', () {
    late _Env env;
    late String token;
    late List<int> bytes;
    late String hash;

    setUp(() async {
      env = await _makeEnv();
      token = (await env.pairing.createAccount('pc')).token;
      // 2.5 块 → 3 块。
      bytes = List<int>.generate(
          2 * kPhotoChunkSize + 100, (i) => i % 251);
      hash = sha256.convert(bytes).toString();
    });

    tearDown(() async {
      env.pairing.dispose();
      AppPaths.clearForTest();
      if (env.tmp.existsSync()) await env.tmp.delete(recursive: true);
    });

    Future<Map<String, dynamic>> initPhoto(
        {String? sha, int? size, String filename = 'p1.jpg'}) async {
      final r = await _call(env, 'POST', '/project/c1/photos/init',
          headers: _auth(token),
          body: jsonEncode({
            'filename': filename,
            'size': size ?? bytes.length,
            'sha256': sha ?? hash,
          }));
      expect(r.status, 200);
      return Map<String, dynamic>.from(r.json['data'] as Map);
    }

    Future<({int status, Map<String, dynamic> json})> putChunk(
        String uid, int i, List<int> data) async {
      return _call(env, 'PUT', '/project/c1/photos/$uid/chunk/$i',
          headers: {'Authorization': 'Bearer $token'},
          body: data);
    }

    test('init → 3 块 → status → complete，sha256 校验通过', () async {
      final init = await initPhoto();
      final uid = init['uploadId'] as String;
      expect(init['chunkSize'], kPhotoChunkSize);
      expect(init['totalChunks'], 3);
      expect(init['exists'], isFalse);

      // 断点续传：先传第 0 块，查 status。
      var r = await putChunk(uid, 0, bytes.sublist(0, kPhotoChunkSize));
      expect(r.status, 200);
      expect(r.json['data']['done'], 1);

      r = await _call(env, 'GET', '/project/c1/photos/$uid/status',
          headers: _auth(token));
      expect(r.status, 200);
      expect(r.json['data']['received'], [true, false, false]);

      // 传完剩余块。
      await putChunk(uid, 1,
          bytes.sublist(kPhotoChunkSize, 2 * kPhotoChunkSize));
      await putChunk(uid, 2, bytes.sublist(2 * kPhotoChunkSize));

      r = await _call(env, 'POST', '/project/c1/photos/$uid/complete',
          headers: _auth(token));
      expect(r.status, 200);
      expect(r.json['data']['sha256'], hash);

      // 文件落盘：<cid>.photos/<sha256>.jpg。
      final accId = (await env.store.readAccounts()).first['id'] as String;
      final f = await env.store.findPhotoByHash(accId, 'c1', hash);
      expect(f, isNotNull);
      expect(await f!.readAsBytes(), bytes);

      // 同 hash 再 init → exists=true（去重）。
      final init2 = await initPhoto();
      expect(init2['exists'], isTrue);
    });

    test('缺块 complete → 400 中文', () async {
      final init = await initPhoto();
      final uid = init['uploadId'] as String;
      await putChunk(uid, 0, bytes.sublist(0, kPhotoChunkSize));
      // 第 1、2 块没传。
      final r = await _call(env, 'POST', '/project/c1/photos/$uid/complete',
          headers: _auth(token));
      expect(r.status, 400);
      expect((r.json['message'] as String).contains('缺失'), isTrue);
    });

    test('sha256 不符 → 400', () async {
      final wrongHash = '0' * 64;
      final init = await initPhoto(sha: wrongHash);
      final uid = init['uploadId'] as String;
      await putChunk(uid, 0, bytes.sublist(0, kPhotoChunkSize));
      await putChunk(
          uid, 1, bytes.sublist(kPhotoChunkSize, 2 * kPhotoChunkSize));
      await putChunk(uid, 2, bytes.sublist(2 * kPhotoChunkSize));
      final r = await _call(env, 'POST', '/project/c1/photos/$uid/complete',
          headers: _auth(token));
      expect(r.status, 400);
      expect((r.json['message'] as String).contains('sha256'), isTrue);
    });
  });

  group('按日期归档', () {
    test('跨天 PUT 落不同日期目录；index 合并去重取最新', () async {
      // 可变时钟 holder：ServerStore 与 PairingService 共享。
      DateTime clock = DateTime(2026, 10, 10, 23, 50, 0);
      final tmp = await Directory.systemTemp.createTemp('sync_date_test_');
      AppPaths.setBaseForTest(tmp);
      addTearDown(() async {
        AppPaths.clearForTest();
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      });

      final store = ServerStore(now: () => clock);
      final tokens = _MemTokenStore();
      final pairing = PairingService(
        store: store,
        tokens: tokens,
        now: () => clock,
        random: Random(5),
        enableCleanupTimer: false,
      );
      addTearDown(pairing.dispose);
      final photos = PhotoUploadManager(store: store);
      final server = SyncServer(
          store: store, pairing: pairing, photos: photos, tokens: tokens);
      final env = _Env(
          tmp: tmp,
          store: store,
          tokens: tokens,
          pairing: pairing,
          photos: photos,
          server: server,
          now: clock);

      final token = (await pairing.createAccount('pc')).token;

      // 10-10 日 PUT → rev=1 落 2026-10-10/。
      var r = await _call(env, 'PUT', '/project/c1',
          headers: _auth(token), body: jsonEncode(_putBody(0)));
      expect(r.json['data']['rev'], 1);
      final accId = (await store.readAccounts()).first['id'] as String;
      expect(
          File('${tmp.path}/ovimap-sync/$accId/2026-10-10/c1.r1.json')
              .existsSync(),
          isTrue);

      // 跨天到 10-11：PUT → rev=2 落 2026-10-11/。
      clock = DateTime(2026, 10, 11, 0, 5, 0);
      r = await _call(env, 'PUT', '/project/c1',
          headers: _auth(token), body: jsonEncode(_putBody(1)));
      expect(r.json['data']['rev'], 2);
      expect(
          File('${tmp.path}/ovimap-sync/$accId/2026-10-11/c1.r2.json')
              .existsSync(),
          isTrue);

      // index 合并：只 1 条，取最大 rev=2。
      r = await _call(env, 'GET', '/index', headers: _auth(token));
      final items = r.json['data']['items'] as List;
      expect(items, hasLength(1));
      expect(items.first['rev'], 2);

      // history 能看到两个日期的版本。
      r = await _call(env, 'GET', '/project/c1/history',
          headers: _auth(token));
      expect((r.json['data']['versions'] as List), hasLength(2));
    });
  });

  group('UDP 发现报文', () {
    test('beaconMessage ↔ parseBeacon 往返；非法报文 → null', () {
      final beacon =
          DiscoveryBeacon(serverName: 'pc-1', port: kSyncServerPort);
      final msg = beacon.beaconMessage();
      expect(msg, 'OVIMAP_SYNC/1 pc-1 $kSyncServerPort');
      final parsed = DiscoveryBeacon.parseBeacon(msg);
      expect(parsed?.serverName, 'pc-1');
      expect(parsed?.port, kSyncServerPort);

      expect(DiscoveryBeacon.parseBeacon('OVIMAP_SYNC/1 pc-1'), isNull);
      expect(DiscoveryBeacon.parseBeacon('HELLO pc-1 47820'), isNull);
      expect(DiscoveryBeacon.parseBeacon('OVIMAP_SYNC/1 pc-1 abc'), isNull);
      expect(DiscoveryBeacon.parseBeacon(''), isNull);
    });
  });

  group('token 脱敏', () {
    test('maskToken 只保留前 4 位', () {
      expect(maskToken('abcdef123456'), 'abcd***');
      expect(maskToken('abc'), '***');
      expect(maskToken(''), '***');
      expect(maskToken(null), '***');
    });
  });
}
