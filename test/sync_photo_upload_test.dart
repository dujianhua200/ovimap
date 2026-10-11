// 照片分块上传测试（MockClient 零网络）：断点续传 / 重试 / 校验。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/sync/client/photo_sync.dart';
import 'package:ovimap/sync/client/photo_sync_queue.dart';

http.Response _env(Object? data, {int code = 0}) => http.Response(
  jsonEncode({'code': code, 'data': data, 'message': 'ok'}),
  200,
  headers: {'Content-Type': 'application/json'},
);

Future<File> _tmpFile(List<int> bytes) async {
  final f = File(
    '${Directory.systemTemp.path}/ovimap_photo_test_${DateTime.now().microsecondsSinceEpoch}.bin',
  );
  await f.writeAsBytes(bytes);
  return f;
}

Future<void> _noSleep(Duration d) async {}

void main() {
  group('sha256Hex', () {
    test('已知向量 abc', () {
      expect(
        sha256Hex('abc'.codeUnits),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });
  });

  group('uploadPhoto', () {
    test('服务端已有同 hash → 跳过，不发 chunk/complete', () async {
      final log = <String>[];
      final client = MockClient((req) async {
        log.add('${req.method} ${req.url.path}');
        return _env({'exists': true});
      });
      final f = await _tmpFile(List<int>.generate(10, (i) => i));
      try {
        final progress = <List<int>>[];
        final r = await uploadPhoto(
          baseUrl: 'http://pc:47820',
          token: 'tok',
          cid: 'cid-1',
          file: f,
          client: client,
          sleeper: _noSleep,
          onProgress: (s, t) => progress.add([s, t]),
        );
        expect(r.uploaded, isFalse);
        expect(r.size, 10);
        expect(log, ['POST /project/cid-1/photos/init']);
        expect(progress.last, [10, 10]);
      } finally {
        await f.delete();
      }
    });

    test('断点续传：status 已传 chunk0，只 PUT 余下分块', () async {
      final puts = <int>[];
      String? completeHash;
      final client = MockClient((req) async {
        final p = req.url.path;
        if (p.endsWith('/init')) {
          return _env({'uploadId': 'u1', 'chunkSize': 4, 'exists': false});
        }
        if (p.endsWith('/status')) {
          return _env({
            'uploaded': [0],
          });
        }
        if (p.contains('/chunk/')) {
          final idx = int.parse(p.split('/').last);
          puts.add(idx);
          expect(req.bodyBytes.length, idx == 2 ? 2 : 4);
          return _env({});
        }
        if (p.endsWith('/complete')) {
          completeHash = (jsonDecode(req.body) as Map)['sha256'] as String?;
          return _env({'sha256': completeHash});
        }
        return http.Response('not found', 404);
      });
      // 10 字节，chunkSize=4 → 3 块(4,4,2)；chunk0 已在服务端
      final f = await _tmpFile(List<int>.generate(10, (i) => i + 1));
      try {
        final progress = <List<int>>[];
        final r = await uploadPhoto(
          baseUrl: 'http://pc:47820',
          token: 'tok',
          cid: 'cid-1',
          file: f,
          client: client,
          sleeper: _noSleep,
          onProgress: (s, t) => progress.add([s, t]),
        );
        expect(r.uploaded, isTrue);
        expect(puts, [1, 2]); // chunk0 被跳过
        expect(completeHash, r.sha256);
        expect(progress.last, [10, 10]);
      } finally {
        await f.delete();
      }
    });

    test('分块失败重试：第一次 500，第二次成功', () async {
      var attempts = 0;
      final client = MockClient((req) async {
        final p = req.url.path;
        if (p.endsWith('/init')) {
          return _env({'uploadId': 'u1', 'chunkSize': 1024, 'exists': false});
        }
        if (p.endsWith('/status')) return _env({'uploaded': []});
        if (p.contains('/chunk/')) {
          attempts++;
          if (attempts == 1) return http.Response('boom', 500);
          return _env({});
        }
        if (p.endsWith('/complete')) {
          return _env({'sha256': (jsonDecode(req.body) as Map)['sha256']});
        }
        return http.Response('not found', 404);
      });
      final f = await _tmpFile(List<int>.generate(100, (i) => i));
      try {
        final r = await uploadPhoto(
          baseUrl: 'http://pc:47820',
          token: 'tok',
          cid: 'cid-1',
          file: f,
          client: client,
          sleeper: _noSleep,
        );
        expect(r.uploaded, isTrue);
        expect(attempts, 2);
      } finally {
        await f.delete();
      }
    });

    test('分块 4 次全失败 → 中文异常（含已重试 3 次）', () async {
      final client = MockClient((req) async {
        final p = req.url.path;
        if (p.endsWith('/init')) {
          return _env({'uploadId': 'u1', 'chunkSize': 1024, 'exists': false});
        }
        if (p.endsWith('/status')) return _env({'uploaded': []});
        if (p.contains('/chunk/')) return http.Response('boom', 500);
        return http.Response('not found', 404);
      });
      final f = await _tmpFile(List<int>.generate(10, (i) => i));
      try {
        await expectLater(
          uploadPhoto(
            baseUrl: 'http://pc:47820',
            token: 'tok',
            cid: 'cid-1',
            file: f,
            client: client,
            sleeper: _noSleep,
          ),
          throwsA(
            isA<PhotoSyncException>().having(
              (e) => e.message,
              'message',
              contains('已重试 3 次'),
            ),
          ),
        );
      } finally {
        await f.delete();
      }
    });

    test('complete 返回不一致 sha256 → 中文校验异常', () async {
      final client = MockClient((req) async {
        final p = req.url.path;
        if (p.endsWith('/init')) {
          return _env({'uploadId': 'u1', 'chunkSize': 1024, 'exists': false});
        }
        if (p.endsWith('/status')) return _env({'uploaded': []});
        if (p.contains('/chunk/')) return _env({});
        if (p.endsWith('/complete')) {
          return _env({'sha256': 'deadbeef'});
        }
        return http.Response('not found', 404);
      });
      final f = await _tmpFile(List<int>.generate(10, (i) => i));
      try {
        await expectLater(
          uploadPhoto(
            baseUrl: 'http://pc:47820',
            token: 'tok',
            cid: 'cid-1',
            file: f,
            client: client,
            sleeper: _noSleep,
          ),
          throwsA(
            isA<PhotoSyncException>().having(
              (e) => e.message,
              'message',
              contains('校验失败'),
            ),
          ),
        );
      } finally {
        await f.delete();
      }
    });

    test('bitmap 形态的 status 也能解析', () async {
      final puts = <int>[];
      final client = MockClient((req) async {
        final p = req.url.path;
        if (p.endsWith('/init')) {
          return _env({'uploadId': 'u1', 'chunkSize': 4, 'exists': false});
        }
        if (p.endsWith('/status')) return _env({'bitmap': '101'});
        if (p.contains('/chunk/')) {
          puts.add(int.parse(p.split('/').last));
          return _env({});
        }
        if (p.endsWith('/complete')) {
          return _env({'sha256': (jsonDecode(req.body) as Map)['sha256']});
        }
        return http.Response('not found', 404);
      });
      final f = await _tmpFile(List<int>.generate(10, (i) => i));
      try {
        await uploadPhoto(
          baseUrl: 'http://pc:47820',
          token: 'tok',
          cid: 'cid-1',
          file: f,
          client: client,
          sleeper: _noSleep,
        );
        expect(puts, [1]); // bitmap 101 → 只传 chunk1
      } finally {
        await f.delete();
      }
    });

    test('401 → 令牌无效中文异常', () async {
      final client = MockClient(
        (req) async => http.Response('{"code":401}', 401),
      );
      final f = await _tmpFile([1, 2, 3]);
      try {
        await expectLater(
          uploadPhoto(
            baseUrl: 'http://pc:47820',
            token: 'bad',
            cid: 'cid-1',
            file: f,
            client: client,
            sleeper: _noSleep,
          ),
          throwsA(
            isA<PhotoSyncException>().having(
              (e) => e.message,
              'message',
              contains('令牌无效'),
            ),
          ),
        );
      } finally {
        await f.delete();
      }
    });
  });

  group('PhotoSyncQueue', () {
    test('增量：第二次同步直接跳过已传 hash', () async {
      SharedPreferences.setMockInitialValues({});
      var inits = 0;
      final client = MockClient((req) async {
        final p = req.url.path;
        if (p.endsWith('/init')) {
          inits++;
          return _env({
            'uploadId': 'u$inits',
            'chunkSize': 1024,
            'exists': false,
          });
        }
        if (p.endsWith('/status')) return _env({'uploaded': []});
        if (p.contains('/chunk/')) return _env({});
        if (p.endsWith('/complete')) {
          return _env({'sha256': (jsonDecode(req.body) as Map)['sha256']});
        }
        return http.Response('not found', 404);
      });
      final dir = await Directory.systemTemp.createTemp('ovimap_q_');
      final f = File('${dir.path}/a.jpg');
      await f.writeAsBytes(List<int>.generate(50, (i) => i));
      try {
        final q = PhotoSyncQueue(httpClient: client);
        Future<String> abs(String rel) async => '${dir.path}/$rel';
        final r1 = await q.syncAll(
          baseUrl: 'http://pc:47820',
          token: 'tok',
          cid: 'cid-1',
          photoRelNames: ['a.jpg', 'a.jpg', 'missing.jpg'],
          absPathOf: abs,
        );
        expect(r1.total, 2); // 去重 + 去空
        expect(r1.uploaded, 1);
        expect(r1.skipped, 1); // missing.jpg 文件不存在
        expect(inits, 1);
        // 第二次：hash 已记，直接跳过，不发 init
        final r2 = await q.syncAll(
          baseUrl: 'http://pc:47820',
          token: 'tok',
          cid: 'cid-1',
          photoRelNames: ['a.jpg'],
          absPathOf: abs,
        );
        expect(r2.uploaded, 0);
        expect(r2.skipped, 1);
        expect(inits, 1);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
