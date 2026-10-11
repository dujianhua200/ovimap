import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/services/secure_store.dart';
import 'package:ovimap/sync/tunnel/qr_payload.dart';
import 'package:ovimap/sync/tunnel/tunnel_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内存 Map 版安全存储（测试用 fake）。
class FakeSecureStore extends FlutterSecureStorage {
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
  }) async =>
      values[key];

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.clear();
  }
}

/// 可注入的假 cloudflared 子进程。
class FakeTunnelProcess implements TunnelProcess {
  final stdoutCtl = StreamController<List<int>>();
  final stderrCtl = StreamController<List<int>>();
  final _exitCode = Completer<int>();

  bool killed = false;
  String? capturedExe;
  List<String>? capturedArgs;

  void emitStdout(String line) =>
      stdoutCtl.add(utf8.encode('$line\n'));
  void emitStderr(String line) =>
      stderrCtl.add(utf8.encode('$line\n'));
  void exit(int code) {
    if (!_exitCode.isCompleted) _exitCode.complete(code);
  }

  @override
  Stream<List<int>> get stdout => stdoutCtl.stream;
  @override
  Stream<List<int>> get stderr => stderrCtl.stream;
  @override
  Future<int> get exitCode => _exitCode.future;
  @override
  bool kill() {
    killed = true;
    return true;
  }
}

void main() {
  group('maskSecret', () {
    test('null 与空字符串', () {
      expect(maskSecret(null), '(空)');
      expect(maskSecret(''), '(空)');
    });
    test('不足 4 位全星号', () {
      expect(maskSecret('a'), '*');
      expect(maskSecret('abc'), '***');
    });
    test('4 位及以上：前 4 位 + ***', () {
      expect(maskSecret('abcd'), 'abcd***');
      expect(maskSecret('xyz-123-token-secret'), 'xyz-***');
    });
  });

  group('key 命名', () {
    test('账号/服务端/隧道 key 格式', () {
      expect(accountTokenKey('acc-001'), 'sync.account.acc-001.token');
      expect(serverTokenKey('home'), 'sync.server.home.token');
      expect(kTunnelTokenKey, 'sync.tunnel.token');
    });
  });

  group('SecureStore（fake 注入）', () {
    test('write/read/delete/deleteAll', () async {
      final store = SecureStore(storage: FakeSecureStore());

      await store.write(accountTokenKey('acc-1'), 'tok-abc');
      expect(await store.read(accountTokenKey('acc-1')), 'tok-abc');
      expect(await store.read('sync.account.missing.token'), isNull);

      await store.delete(accountTokenKey('acc-1'));
      expect(await store.read(accountTokenKey('acc-1')), isNull);

      await store.write(kTunnelTokenKey, 'tunnel-xyz');
      await store.write(serverTokenKey('srv'), 'srv-tok');
      await store.deleteAll();
      expect(await store.read(kTunnelTokenKey), isNull);
      expect(await store.read(serverTokenKey('srv')), isNull);
    });
  });

  group('buildQrPayload', () {
    test('字段完整性（v/accountId/code/lan/remote/name）', () {
      final raw = buildQrPayload(
        accountId: 'acc-9',
        code: '123456',
        name: '书房电脑',
        lanUrl: 'http://192.168.1.10:47820',
        remoteUrl: 'https://sync.example.com',
      );
      final m = jsonDecode(raw) as Map<String, dynamic>;
      expect(m['v'], 1);
      expect(m['accountId'], 'acc-9');
      expect(m['code'], '123456');
      expect(m['name'], '书房电脑');
      expect(m['lan'], 'http://192.168.1.10:47820');
      expect(m['remote'], 'https://sync.example.com');
    });

    test('可选字段缺省为空字符串', () {
      final m = jsonDecode(
          buildQrPayload(accountId: 'a', code: '000000')) as Map<String, dynamic>;
      expect(m['name'], '');
      expect(m['lan'], '');
      expect(m['remote'], '');
    });
  });

  group('TunnelManager', () {
    test('非 Windows：ensureBinary 抛中文错误', () async {
      final mgr = TunnelManager(isWindows: false);
      await expectLater(
        mgr.ensureBinary(),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('仅 Windows'))),
      );
      mgr.dispose();
    });

    test('二进制已存在：ensureBinary 不下载直接返回', () async {
      final dir =
          await Directory.systemTemp.createTemp('ovimap-tunnel-test');
      final exe = File('${dir.path}${Platform.pathSeparator}cloudflared.exe');
      await exe.writeAsBytes([1, 2, 3]);
      var factoryCalls = 0;
      final mgr = TunnelManager(
        isWindows: true,
        binaryPathProvider: () async => exe.path,
        processFactory: (e, a) async {
          factoryCalls++;
          throw StateError('不应走到下载');
        },
      );
      expect(await mgr.ensureBinary(), exe.path);
      expect(factoryCalls, 0);
      expect(mgr.downloading, false);
      mgr.dispose();
      await dir.delete(recursive: true);
    });

    test('状态机：start → 日志脱敏 → 退出 → stop', () async {
      final dir =
          await Directory.systemTemp.createTemp('ovimap-tunnel-test');
      final exe = File('${dir.path}${Platform.pathSeparator}cloudflared.exe');
      await exe.writeAsBytes([1, 2, 3]);

      final fake = FakeTunnelProcess();
      String? gotExe;
      List<String>? gotArgs;
      final mgr = TunnelManager(
        isWindows: true,
        binaryPathProvider: () async => exe.path,
        processFactory: (e, a) async {
          gotExe = e;
          gotArgs = a;
          fake.capturedExe = e;
          fake.capturedArgs = a;
          return fake;
        },
      );

      const token = 'secrettoken-abcdef-123456';
      await mgr.start(token);
      expect(mgr.running, true);
      expect(gotExe, exe.path);
      expect(gotArgs,
          ['tunnel', '--no-autoupdate', 'run', '--token', token]);

      // stdout 里出现 token 原文 → 日志里只能有脱敏版。
      fake.emitStdout('INF token=$token registered');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final logs = mgr.logLines.join('\n');
      expect(logs.contains(token), false,
          reason: '日志里出现了完整 token 原文');
      expect(logs.contains(maskSecret(token)), true);

      // 进程退出 → running=false，日志记 exit code。
      fake.exit(1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(mgr.running, false);
      expect(mgr.logLines.last, contains('code=1'));

      // 再次 start 后 stop → kill 被调用。
      final fake2 = FakeTunnelProcess();
      final mgr2 = TunnelManager(
        isWindows: true,
        binaryPathProvider: () async => exe.path,
        processFactory: (e, a) async => fake2,
      );
      await mgr2.start(token);
      expect(mgr2.running, true);
      mgr2.stop();
      expect(mgr2.running, false);
      expect(fake2.killed, true);

      mgr.dispose();
      mgr2.dispose();
      await dir.delete(recursive: true);
    });

    test('start 缺二进制 / 空 token 抛错', () async {
      final mgr = TunnelManager(
        isWindows: true,
        binaryPathProvider: () async => r'C:\nope\cloudflared.exe',
      );
      await expectLater(mgr.start('x'), throwsStateError);
      mgr.dispose();

      final dir =
          await Directory.systemTemp.createTemp('ovimap-tunnel-test');
      final exe = File('${dir.path}${Platform.pathSeparator}cloudflared.exe');
      await exe.writeAsBytes([1]);
      final mgr2 = TunnelManager(
        isWindows: true,
        binaryPathProvider: () async => exe.path,
      );
      await expectLater(mgr2.start('  '), throwsStateError);
      mgr2.dispose();
      await dir.delete(recursive: true);
    });

    test('logLines 最多保留 50 行', () async {
      final dir =
          await Directory.systemTemp.createTemp('ovimap-tunnel-test');
      final exe = File('${dir.path}${Platform.pathSeparator}cloudflared.exe');
      await exe.writeAsBytes([1]);
      final fake = FakeTunnelProcess();
      final mgr = TunnelManager(
        isWindows: true,
        binaryPathProvider: () async => exe.path,
        processFactory: (e, a) async => fake,
      );
      await mgr.start('tok');
      for (var i = 0; i < 70; i++) {
        fake.emitStdout('line $i');
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(mgr.logLines.length, 50);
      expect(mgr.logLines.first, contains('line 20'));
      mgr.dispose();
      await dir.delete(recursive: true);
    });

    test('autoStartIfEnabled：开关开 + 有 token → 自动拉起', () async {
      SharedPreferences.setMockInitialValues(
          {kTunnelEnabledPrefKey: true});
      final dir =
          await Directory.systemTemp.createTemp('ovimap-tunnel-test');
      final exe = File('${dir.path}${Platform.pathSeparator}cloudflared.exe');
      await exe.writeAsBytes([1]);
      final fake = FakeTunnelProcess();
      final store = SecureStore(storage: FakeSecureStore());
      await store.write(kTunnelTokenKey, 'auto-token-xyz');
      final mgr = TunnelManager(
        isWindows: true,
        binaryPathProvider: () async => exe.path,
        processFactory: (e, a) async {
          fake.capturedArgs = a;
          return fake;
        },
        secureStore: store,
      );
      await mgr.autoStartIfEnabled();
      expect(mgr.running, true);
      expect(fake.capturedArgs?.last, 'auto-token-xyz');
      mgr.dispose();
      await dir.delete(recursive: true);
    });

    test('autoStartIfEnabled：开关关 → 不拉起', () async {
      SharedPreferences.setMockInitialValues(
          {kTunnelEnabledPrefKey: false});
      var started = false;
      final mgr = TunnelManager(
        isWindows: true,
        processFactory: (e, a) async {
          started = true;
          throw StateError('不应启动');
        },
      );
      await mgr.autoStartIfEnabled();
      expect(started, false);
      expect(mgr.running, false);
      mgr.dispose();
    });

    test('autoStartIfEnabled：开关开但无 token → 记 lastError 不抛', () async {
      SharedPreferences.setMockInitialValues(
          {kTunnelEnabledPrefKey: true});
      final store = SecureStore(storage: FakeSecureStore());
      final mgr = TunnelManager(
        isWindows: true,
        secureStore: store,
        binaryPathProvider: () async => r'C:\x\cloudflared.exe',
      );
      await mgr.autoStartIfEnabled();
      expect(mgr.running, false);
      expect(mgr.lastError, contains('token'));
      mgr.dispose();
    });
  });
}
