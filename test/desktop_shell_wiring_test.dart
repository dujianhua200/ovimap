// 桌面板接线断言（源级 / 零网络）：确认 T08~T12 的桌面壳、快捷键、右键菜单、
// 三栏与平台单点收口确实接线，且业务 UI 未散落平台/交付分支。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String rel) => File(rel).readAsStringSync();

void main() {
  group('T08 桌面壳 + main.dart 平台分支', () {
    test('main.dart：Windows → WorkspacePage，其余 → HomePage；桌面不强制竖屏', () {
      final s = read('lib/main.dart');
      expect(s.contains("import 'ui/desktop/workspace_page.dart';"), isTrue);
      expect(s.contains('Platform.isWindows ? const WorkspacePage() : const HomePage()'),
          isTrue);
      expect(s.contains('if (!Platform.isWindows)'), isTrue);
    });

    test('workspace_page：三栏 + 可拖拽分隔 + 折叠 + LayoutBuilder 自适应', () {
      final s = read('lib/ui/desktop/workspace_page.dart');
      expect(s.contains('DesktopShortcuts('), isTrue);
      expect(s.contains('LayoutBuilder('), isTrue);
      expect(s.contains('AppMenuBar('), isTrue);
      expect(s.contains('Toolbar('), isTrue);
      expect(s.contains('StatusBar('), isTrue);
      expect(s.contains('LeftPanel('), isTrue);
      expect(s.contains('RightPanel('), isTrue);
      // 共享地图核心：桌面点选交给右栏，不直接弹对话框。
      expect(s.contains('openDetailOnTap: false,'), isTrue);
      expect(s.contains('InteractiveFlag.all,'), isTrue);
      // 鼠标右键 → 右键菜单
      expect(s.contains('onSecondaryTap:'), isTrue);
      expect(s.contains('showMapContextMenu('), isTrue);
      // 窗口 < 1180 自动收起右栏
      expect(s.contains('1180'), isTrue);
    });
  });

  group('T12 快捷键 + 右键菜单', () {
    test('shortcuts：Shortcuts/Actions/Intent（零依赖）', () {
      final s = read('lib/ui/desktop/shortcuts.dart');
      expect(s.contains('Shortcuts('), isTrue);
      expect(s.contains('Actions('), isTrue);
      expect(s.contains('SingleActivator(LogicalKeyboardKey.keyS, control: true):'),
          isTrue);
      expect(s.contains('SingleActivator(LogicalKeyboardKey.delete):'), isTrue);
      expect(s.contains('class SaveIntent'), isTrue);
      expect(s.contains('class UndoIntent'), isTrue);
      expect(s.contains('class RedoIntent'), isTrue);
      expect(s.contains('class DeleteSelectionIntent'), isTrue);
      expect(s.contains('class ExportIntent'), isTrue);
      expect(s.contains('class FocusSearchIntent'), isTrue);
      // Ctrl+Shift+Z 也映射到 Redo
      expect(s.contains('logicalKeyboardKey.keyZ') ||
          s.contains('LogicalKeyboardKey.keyZ, control: true, shift: true'),
          isTrue);
    });

    test('context_menu：showMenu + 点/线/空白三态菜单项', () {
      final s = read('lib/ui/desktop/context_menu.dart');
      expect(s.contains('showMenu<String>('), isTrue);
      // 点
      expect(s.contains("value: 'edit'"), isTrue);
      expect(s.contains("value: 'branch'"), isTrue);
      expect(s.contains("value: 'drag'"), isTrue);
      expect(s.contains("value: 'del_point'"), isTrue);
      // 线段
      expect(s.contains("value: 'seg_kind'"), isTrue);
      expect(s.contains("value: 'seg_cable'"), isTrue);
      expect(s.contains("value: 'seg_slack'"), isTrue);
      // 空白
      expect(s.contains("value: 'add'"), isTrue);
      expect(s.contains("value: 'paste_coord'"), isTrue);
      expect(s.contains("value: 'import_file'"), isTrue);
    });
  });

  group('T09/T10/T11 三栏件', () {
    test('left_panel：搜索 + 文件夹 + 工程列表 + 同步徽标位 + 拖拽导入占位', () {
      final s = read('lib/ui/desktop/left_panel.dart');
      expect(s.contains('onNewProject'), isTrue);
      expect(s.contains('文件夹'), isTrue);
      expect(s.contains('DragTarget<Object>'), isTrue);
      // 同步徽标位：T17 已由「本地」占位升级为真实 SyncBadge（可空接入 SyncController）。
      expect(s.contains("'SyncBadge'") || s.contains('SyncBadge(status:'), isTrue);
      expect(s.contains('context.watch<SyncController?>('), isTrue);
      expect(s.contains('searchFocus'), isTrue);
    });

    test('right_panel：复用属性编辑逻辑（草稿/收藏两路保存）', () {
      final s = read('lib/ui/desktop/right_panel.dart');
      expect(s.contains('st.updateLabel('), isTrue);
      expect(s.contains('updateOverlayLabel('), isTrue);
      expect(s.contains('showLabelProperties('), isTrue);
      expect(s.contains('ChoiceChip('), isTrue); // 敷设方式
    });

    test('toolbar / status_bar：工具入口 + 设备名/同步状态/坐标/图源', () {
      final tb = read('lib/ui/desktop/toolbar.dart');
      expect(tb.contains('AppMode.measureArea'), isTrue);
      expect(tb.contains('onSync'), isTrue);
      expect(tb.contains('showSourceDialog('), isTrue);

      final sb = read('lib/ui/desktop/status_bar.dart');
      expect(sb.contains('本地模式'), isTrue);
      expect(sb.contains('最后同步'), isTrue);
      expect(sb.contains('curSource.name'), isTrue);
    });
  });

  group('平台单点收口 / 禁止散落', () {
    test('业务 UI（lib/ui）不得直接调用 Share.* 或 FilePicker.saveFile', () {
      final files = Directory('lib/ui')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      for (final f in files) {
        final s = f.readAsStringSync();
        expect(s.contains('Share.'), isFalse,
            reason: '${f.path} 直接调用 Share，应走 ExportSaver');
        expect(s.contains('FilePicker.platform.saveFile'), isFalse,
            reason: '${f.path} 直接调用 saveFile，应走 ExportSaver');
      }
    });

    test('业务 UI（lib/ui）不得出现 Platform.isWindows（须走 PlatformCaps）', () {
      final files = Directory('lib/ui')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      for (final f in files) {
        expect(f.readAsStringSync().contains('Platform.isWindows'), isFalse,
            reason: '${f.path} 散落 Platform.isWindows，应走 PlatformCaps');
      }
    });

    test('loc.dart：罗盘订阅经 PlatformCaps.hasCompass 拦截（无 Windows 实现）', () {
      final s = read('lib/services/loc.dart');
      expect(s.contains('PlatformCaps.hasCompass'), isTrue);
    });

    test('dialogs.dart：交付出口收敛到 ExportSaver（不再直接 import share_plus）', () {
      final s = read('lib/ui/dialogs.dart');
      expect(s.contains('ExportSaver.saveOrShare'), isTrue);
      expect(s.contains("import 'package:share_plus/share_plus.dart';"), isFalse);
      expect(s.contains('PlatformCaps.hasCamera'), isTrue);
    });

    test('app_paths.dart：Windows 走 %APPDATA%（APPDATA 环境变量）', () {
      final s = read('lib/services/app_paths.dart');
      expect(s.contains("Platform.environment['APPDATA']"), isTrue);
      expect(s.contains('\\\\ovimap'), isTrue); // %APPDATA%\ovimap
    });
  });
}
