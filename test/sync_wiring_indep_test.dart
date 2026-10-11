// T16/T17/T18 接线断言（源级 / 零网络）：确认同步的 Provider 注入、AppState 回调接线、
// UI 以「可空快照」接入（AOT 安全）、无新增依赖、Worker 关键语义齐备。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String rel) => File(rel).readAsStringSync();

void main() {
  group('T16 AppState / main.dart 接线', () {
    test('main.dart 注入 SyncController 并启动（MultiProvider）', () {
      final s = read('lib/main.dart');
      expect(s.contains('MultiProvider('), isTrue);
      expect(s.contains('ChangeNotifierProvider<SyncController>'), isTrue);
      // ★ 必须 eager（精确匹配「provider 构造调用」，不匹配注释/文档串）：
      // 移动端 HomePage 启动不读 SyncController，惰性创建会导致
      // start()/attachSyncController 都不跑（冷启动不自动同步）。
      // 用正则锚定到 `ChangeNotifierProvider<SyncController>(` 之后的 `lazy: false`，
      // 这样删掉代码行（仅留注释）时断言会 RED，真正锁住回归。
      expect(
          RegExp(r'ChangeNotifierProvider<SyncController>\(\s*lazy:\s*false')
              .hasMatch(s),
          isTrue,
          reason: 'SyncController provider 必须 lazy:false（两端启动即起同步）');
      expect(s.contains('attachSyncController('), isTrue);
      expect(s.contains('sc.start'), isTrue);
      // 平台分支：桌面三平台（含 macOS）→ WorkspacePage；移动 → HomePage。
      // 判据必须是 PlatformCaps.isDesktop（曾写成 Platform.isWindows，
      // 使 macOS 落进移动竖屏壳）。此处按行归一化后断言，避免缩进/换行影响。
      final flat = s.replaceAll(RegExp(r'\s+'), ' ');
      expect(flat.contains('PlatformCaps.isDesktop ? const WorkspacePage() : const HomePage()'),
          isTrue,
          reason: 'main.dart 的界面壳分支应改用 PlatformCaps.isDesktop');
    });

    test('AppState：保存/删除回调同步器，且 sync 可为 null（本地可用）', () {
      final s = read('lib/state/app_state.dart');
      expect(s.contains('SyncController? syncController;'), isTrue);
      expect(s.contains('void attachSyncController(SyncController sc)'), isTrue);
      expect(s.contains('syncController?.onLocalSaved(cid)'), isTrue);
      expect(s.contains('syncController?.onLocalDeleted(cid)'), isTrue);
      expect(s.contains('Future<void> deleteCollection(String cid)'), isTrue);
      expect(s.contains('syncController?.pullProject'), isTrue);
    });

    test('依赖方向单向：SyncController 不 import AppState（无循环）', () {
      final s = read('lib/sync/sync_controller.dart');
      expect(s.contains('state/app_state.dart'), isFalse,
          reason: 'SyncController 不得依赖 AppState（避免循环）');
      expect(s.contains('onRemoteApplied'), isTrue,
          reason: '反向刷新走回调');
    });
  });

  group('T17 UI 接入（AOT 安全：可空快照）', () {
    test('同步面板存在', () {
      final panel = read('lib/ui/sync/sync_panel.dart');
      expect(panel.contains('class SyncBadge'), isTrue);
      expect(panel.contains('showSyncSettingsDialog'), isTrue);
    });

    test('工具栏/状态栏/左栏/抽屉：以 SyncController? 可空接入', () {
      final toolbar = read('lib/ui/desktop/toolbar.dart');
      final status = read('lib/ui/desktop/status_bar.dart');
      final left = read('lib/ui/desktop/left_panel.dart');
      final drawer = read('lib/ui/drawer_panel.dart');
      expect(toolbar.contains('SyncController? sync'), isTrue);
      expect(status.contains('SyncController? sync'), isTrue);
      expect(left.contains('context.watch<SyncController?>()'), isTrue);
      // 抽屉经 FavTree.projectTrailing 闭包接入（形参名 mctx），判据放宽到调用本身。
      expect(drawer.contains('watch<SyncController?>()'), isTrue,
          reason: '抽屉以 SyncController? 可空方式接入（AOT 安全）');
      expect(left.contains('SyncBadge('), isTrue);
      expect(drawer.contains('SyncBadge('), isTrue);
      // 「同步该工程」入口随 7 个移动端工程操作收拢到共享模块
      // fav_mobile_actions.dart（FavMenuExtra 扩展点），抽屉经 menuExtra 接入。
      expect(drawer.contains('favMobileProjectExtra()'), isTrue,
          reason: '抽屉经 menuExtra 接入 7 个移动端工程操作');
      final mobileActions =
          read('lib/ui/favorites/fav_mobile_actions.dart');
      expect(mobileActions.contains("'extra:sync_project'"), isTrue,
          reason: '「同步该工程」仍在（旧抽屉 ⋯ 菜单能力不丢失）');
    });

    test('设置面板含「云同步」入口', () {
      final s = read('lib/ui/settings_menu.dart');
      expect(s.contains("sheetGroupTitle('云同步')"), isTrue);
      expect(s.contains('showSyncPanel('), isTrue);
      expect(s.contains('showSyncSettingsDialog('), isTrue);
    });
  });

  group('T18/T19 Cloudflare 侧文件齐备', () {
    test('cloudflare 目录四件套存在', () {
      for (final f in [
        'cloudflare/wrangler.toml',
        'cloudflare/schema.sql',
        'cloudflare/src/index.js',
        'cloudflare/README.md',
      ]) {
        expect(File(f).existsSync(), isTrue, reason: '$f 应存在');
      }
    });

    test('Worker 关键语义：鉴权/乐观并发/保留/软删除/历史恢复', () {
      final s = read('cloudflare/src/index.js');
      expect(s.contains('SYNC_TOKEN'), isTrue);
      expect(s.contains('unauthorized('), isTrue);
      expect(s.contains('revAccepts('), isTrue);
      expect(s.contains('revsToPrune('), isTrue);
      expect(s.contains('409'), isTrue);
      expect(s.contains('RETENTION'), isTrue);
      expect(s.contains('deleted = 1') || s.contains('deleted = 1,'), isTrue);
      expect(s.contains('/restore') || s.contains('restore'), isTrue);
    });

    test('schema.sql 覆盖 projects + snapshots', () {
      final s = read('cloudflare/schema.sql');
      expect(s.contains('CREATE TABLE IF NOT EXISTS projects'), isTrue);
      expect(s.contains('CREATE TABLE IF NOT EXISTS snapshots'), isTrue);
      expect(s.contains('rev'), isTrue);
    });

    test('部署文档存在且含关键步骤', () {
      final s = read('docs/DEPLOY-sync.md');
      expect(s.contains('wrangler'), isTrue);
      expect(s.contains('SYNC_TOKEN'), isTrue);
      expect(s.contains('r2 bucket create') || s.contains('r2_buckets'), isTrue);
    });
  });

  group('硬约束：同步服务端依赖白名单', () {
    // 2026-10-11 架构变更：Windows 内嵌同步服务端（shelf）替代纯 Worker 方案，
    // "零新增依赖"旧约束作废，改为白名单制。白名单外新增运行时依赖需更新此测试。
    test('pubspec 依赖在白名单内', () {
      final s = read('pubspec.yaml');
      const allowed = {
        'flutter', 'flutter_map', 'latlong2', 'provider', 'geolocator',
        'flutter_compass', 'path_provider', 'shared_preferences', 'share_plus',
        'http', 'intl', 'gbk_codec', 'image_picker', 'archive', 'file_picker',
        // 同步服务端（2026-10-11 新增）
        'shelf', 'shelf_router', 'shelf_web_socket', 'web_socket_channel',
        'qr', 'mobile_scanner', 'flutter_secure_storage', 'crypto',
      };
      // 只取 dependencies: 段（dev_dependencies 之前）的一级 key
      final afterDeps = s.split('\ndependencies:').last;
      final depsSection = afterDeps.split('dev_dependencies:').first;
      final found = RegExp(r'\n  ([a-z0-9_]+):', multiLine: true)
          .allMatches(depsSection)
          .map((m) => m.group(1)!)
          .toSet();
      final extra = found.difference(allowed);
      expect(extra, isEmpty, reason: 'pubspec 出现白名单外的新依赖: $extra');
      expect(s.contains('http: ^1.2.0'), isTrue);
    });
  });
}
