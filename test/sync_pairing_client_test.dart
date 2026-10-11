// 配对客户端测试：二维码解析 + POST /pair（MockClient）+ 配对编排。
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ovimap/services/device_identity.dart';
import 'package:ovimap/services/secure_store.dart';
import 'package:ovimap/sync/client/pairing_client.dart';

const _qrOk =
    '{"v":1,"name":"办公电脑","accountId":"acc-abc123","code":"482913",'
    '"lan":"http://192.168.1.10:47820","remote":"https://sync.example.com"}';

http.Response _env(Object? data, {int code = 0, String message = 'ok'}) =>
    http.Response(
      jsonEncode({'code': code, 'data': data, 'message': message}),
      200,
      headers: {'Content-Type': 'application/json'},
    );

/// 内存版 FlutterSecureStorage（测试用 fake）。
class _FakeStorage extends FlutterSecureStorage {
  final Map<String, String> values = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];
}

void main() {
  group('parseQrPayload', () {
    test('合法二维码：lan 优先', () {
      final p = parseQrPayload(_qrOk);
      expect(p.accountId, 'acc-abc123');
      expect(p.code, '482913');
      expect(p.name, '办公电脑');
      expect(p.lan, 'http://192.168.1.10:47820');
      expect(p.preferredBase, 'http://192.168.1.10:47820');
    });

    test('只有 remote 时用 remote', () {
      final p = parseQrPayload(
        '{"v":1,"accountId":"acc-x","code":"123456","remote":"https://s.x.com"}',
      );
      expect(p.preferredBase, 'https://s.x.com');
    });

    test('非 JSON → 中文异常', () {
      expect(
        () => parseQrPayload('not-json'),
        throwsA(
          isA<PairingException>().having(
            (e) => e.message,
            'message',
            contains('JSON'),
          ),
        ),
      );
    });

    test('版本不对 → 中文异常', () {
      expect(
        () => parseQrPayload(
          '{"v":2,"accountId":"a","code":"123456","lan":"http://x"}',
        ),
        throwsA(isA<PairingException>()),
      );
    });

    test('缺 accountId → 中文异常', () {
      expect(
        () => parseQrPayload('{"v":1,"code":"123456","lan":"http://x"}'),
        throwsA(
          isA<PairingException>().having(
            (e) => e.message,
            'message',
            contains('账号 ID'),
          ),
        ),
      );
    });

    test('配对码非 6 位数字 → 中文异常', () {
      for (final bad in ['12345', '1234567', 'abcdef', '  ']) {
        expect(
          () => parseQrPayload(
            '{"v":1,"accountId":"a","code":"$bad","lan":"http://x"}',
          ),
          throwsA(
            isA<PairingException>().having(
              (e) => e.message,
              'message',
              contains('6 位数字'),
            ),
          ),
          reason: 'code=$bad',
        );
      }
    });

    test('lan/remote 都空 → 中文异常', () {
      expect(
        () => parseQrPayload('{"v":1,"accountId":"a","code":"123456"}'),
        throwsA(
          isA<PairingException>().having(
            (e) => e.message,
            'message',
            contains('服务器地址'),
          ),
        ),
      );
    });
  });

  group('PairingClient.pair', () {
    test('成功返回 token', () async {
      http.Request? seen;
      final c = PairingClient(
        client: MockClient((req) async {
          seen = req;
          return _env({'token': 'tok-xyz'});
        }),
      );
      final token = await c.pair(
        baseUrl: 'http://192.168.1.10:47820/',
        accountId: 'acc-1',
        code: '482913',
        deviceId: 'dev-1',
        deviceName: '手机',
      );
      expect(token, 'tok-xyz');
      expect(seen!.url.path, '/pair');
      final body = jsonDecode(seen!.body) as Map;
      expect(body['accountId'], 'acc-1');
      expect(body['code'], '482913');
    });

    test('401 → 配对码错误中文异常', () async {
      final c = PairingClient(
        client: MockClient((req) async => http.Response('{"code":401}', 401)),
      );
      await expectLater(
        c.pair(
          baseUrl: 'http://x',
          accountId: 'a',
          code: '000000',
          deviceId: 'd',
          deviceName: 'n',
        ),
        throwsA(
          isA<PairingException>().having(
            (e) => e.message,
            'message',
            contains('配对码'),
          ),
        ),
      );
    });

    test('业务码非 0 → 服务端 message', () async {
      final c = PairingClient(
        client: MockClient(
          (req) async => _env(null, code: 40001, message: '配对码已使用'),
        ),
      );
      await expectLater(
        c.pair(
          baseUrl: 'http://x',
          accountId: 'a',
          code: '000000',
          deviceId: 'd',
          deviceName: 'n',
        ),
        throwsA(
          isA<PairingException>().having(
            (e) => e.message,
            'message',
            contains('配对码已使用'),
          ),
        ),
      );
    });

    test('服务端未返回 token → 中文异常', () async {
      final c = PairingClient(
        client: MockClient((req) async => _env({'token': ''})),
      );
      await expectLater(
        c.pair(
          baseUrl: 'http://x',
          accountId: 'a',
          code: '123456',
          deviceId: 'd',
          deviceName: 'n',
        ),
        throwsA(
          isA<PairingException>().having(
            (e) => e.message,
            'message',
            contains('未返回令牌'),
          ),
        ),
      );
    });

    test('连不上 → 中文异常', () async {
      final c = PairingClient(
        client: MockClient((req) async => throw Exception('no route')),
      );
      await expectLater(
        c.pair(
          baseUrl: 'http://x',
          accountId: 'a',
          code: '123456',
          deviceId: 'd',
          deviceName: 'n',
        ),
        throwsA(
          isA<PairingException>().having(
            (e) => e.message,
            'message',
            contains('连接服务器失败'),
          ),
        ),
      );
    });
  });

  group('completePairing', () {
    test('配对成功：token 进 SecureStore，身份更新', () async {
      final c = PairingClient(
        client: MockClient((req) async => _env({'token': 'tok-999'})),
      );
      final fake = _FakeStorage();
      final store = SecureStore(storage: fake);
      final id = DeviceIdentity.forTest();
      await c.completePairing(
        payload: parseQrPayload(_qrOk),
        identity: id,
        secureStore: store,
      );
      expect(await store.read(accountTokenKey('acc-abc123')), 'tok-999');
      expect(fake.values[accountTokenKey('acc-abc123')], 'tok-999');
      expect(id.token, 'tok-999');
      expect(id.serverBase, 'http://192.168.1.10:47820');
    });

    test('baseUrlOverride 覆盖二维码地址', () async {
      http.Request? seen;
      final c = PairingClient(
        client: MockClient((req) async {
          seen = req;
          return _env({'token': 'tok-1'});
        }),
      );
      final id = DeviceIdentity.forTest();
      await c.completePairing(
        payload: parseQrPayload(_qrOk),
        baseUrlOverride: 'https://sync.example.com',
        identity: id,
        secureStore: SecureStore(storage: _FakeStorage()),
      );
      expect(seen!.url.host, 'sync.example.com');
      expect(id.serverBase, 'https://sync.example.com');
    });
  });
}
