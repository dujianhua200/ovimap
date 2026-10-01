// AppPaths 单测（零网络 / 零插件）：验证「权威数据目录」单点收口与
// Windows/Android 同构目录结构（labels/ 为整目录互换的前提）。
//
// 通过 `AppPaths.setBaseForTest` 注入临时目录，完全绕开 path_provider 插件
// （flutter_test 无 platform channel）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '_dxf_fixture.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ovimap_paths_');
    AppPaths.setBaseForTest(tmp);
  });

  tearDown(() {
    AppPaths.clearForTest();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('baseDir = 注入目录；子目录逐级派生且自动创建', () async {
    final base = await AppPaths.baseDir();
    expect(base.path, tmp.path);

    final labels = await AppPaths.labelsDir();
    final tiles = await AppPaths.tilesDir();
    final basemap = await AppPaths.basemapDir();
    final export = await AppPaths.exportDir();

    expect(labels.path, '${tmp.path}/labels');
    expect(tiles.path, '${tmp.path}/tiles');
    expect(basemap.path, '${tmp.path}/labels/basemap');
    expect(export.path, '${tmp.path}/labels/export');

    expect(labels.existsSync(), isTrue);
    expect(tiles.existsSync(), isTrue);
    expect(basemap.existsSync(), isTrue);
    expect(export.existsSync(), isTrue);
  });

  test('labels/ 结构 = index/draft 同级（与 Android 逐字同构）', () async {
    final labels = await AppPaths.labelsDir();
    // 目录名为 labels（relocatable：整目录拷贝即可两端互换）。
    expect(labels.uri.pathSegments.where((s) => s.isNotEmpty).last, 'labels');
    // basemap / export 都挂在 labels 之下（不散落在根目录）。
    final basemap = await AppPaths.basemapDir();
    final export = await AppPaths.exportDir();
    expect(basemap.path.startsWith(labels.path), isTrue);
    expect(export.path.startsWith(labels.path), isTrue);
  });

  test('photosDir 落在 <root>/photos（注入态）', () async {
    final photos = await AppPaths.photosDir();
    expect(photos.path, '${tmp.path}/photos');
    expect(photos.existsSync(), isTrue);
  });

  test('baseDir 幂等：多次调用返回同一路径', () async {
    final a = await AppPaths.baseDir();
    final b = await AppPaths.baseDir();
    expect(a.path, b.path);
  });

  test('clearForTest 后重新注入到新目录生效', () async {
    AppPaths.clearForTest();
    final tmp2 = Directory.systemTemp.createTempSync('ovimap_paths2_');
    try {
      AppPaths.setBaseForTest(tmp2);
      final base = await AppPaths.baseDir();
      expect(base.path, tmp2.path);
      expect(base.path, isNot(tmp.path));
    } finally {
      if (tmp2.existsSync()) tmp2.deleteSync(recursive: true);
    }
  });

  group('Windows 真实目录判据（回归：Windows CI 上用例共享 %APPDATA% 串扰）', () {
    test('测试环境（FLUTTER_TEST=true）的 Windows 不走 %APPDATA% 真实目录', () {
      expect(
        AppPaths.useRealAppDataDir(
          isWindows: true,
          env: {
            'FLUTTER_TEST': 'true',
            'APPDATA': r'C:\Users\x\AppData\Roaming',
          },
        ),
        isFalse,
        reason: '测试环境必须走 path_provider，让各用例的 FakePathProvider 生效',
      );
    });

    test('非测试环境的 Windows 仍走 %APPDATA% 真实目录', () {
      expect(
        AppPaths.useRealAppDataDir(
          isWindows: true,
          env: {'APPDATA': r'C:\Users\x\AppData\Roaming'},
        ),
        isTrue,
        reason: '生产行为不变：Windows 落盘 %APPDATA%\\ovimap',
      );
    });

    test('非 Windows 平台从不走 %APPDATA% 分支', () {
      expect(AppPaths.useRealAppDataDir(isWindows: false, env: {}), isFalse);
      expect(
        AppPaths.useRealAppDataDir(
            isWindows: false, env: {'FLUTTER_TEST': 'true'}),
        isFalse,
      );
    });

    test('baseDir 接线：非注入态走 FakePathProvider（不碰真实磁盘目录）', () async {
      // 本用例即在 FLUTTER_TEST=true 下运行；不断言平台，只断言接线：
      // 未注入 _force 时，baseDir 必须派生自当前 FakePathProvider 的目录。
      AppPaths.clearForTest();
      final dir = Directory.systemTemp.createTempSync('ovimap_paths_fake_');
      addTearDown(() {
        AppPaths.clearForTest();
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      PathProviderPlatform.instance = FakePathProvider(dir.path);

      final base = await AppPaths.baseDir();
      expect(base.path.startsWith(dir.path), isTrue,
          reason: 'baseDir 必须派生自 FakePathProvider，否则 Windows 上会落到'
              '真实 %APPDATA%\\ovimap，造成用例间缓存串扰');
    });
  });
}
