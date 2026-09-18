import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 桌面快捷键（架构文档 §3.3 / T12）。
///
/// 用 Flutter 原生 `Shortcuts` + `Actions` + `Intent`（**零新依赖**）实现，
/// 包在 `WorkspacePage` 最外层。事件按焦点链自内向外冒泡：当焦点在文本框内时，
/// 文本框自身的编辑动作优先（如录入时按 Delete 是"向后删除字符"而非删除选中点），
/// 因此无需额外守卫；焦点不在文本框时，落到本层。
///
/// | 键 | Intent | Action |
/// |---|---|---|
/// | Ctrl+S | [SaveIntent] | 保存收藏 |
/// | Ctrl+Z | [UndoIntent] | 撤销 |
/// | Ctrl+Y / Ctrl+Shift+Z | [RedoIntent] | 重做 |
/// | Delete | [DeleteSelectionIntent] | 删除选中 |
/// | Ctrl+E | [ExportIntent] | 打开导出对话框 |
/// | Ctrl+F | [FocusSearchIntent] | 聚焦左栏搜索 |
class SaveIntent extends Intent {
  const SaveIntent();
}

/// Ctrl+Z：撤销。
class UndoIntent extends Intent {
  const UndoIntent();
}

/// Ctrl+Y / Ctrl+Shift+Z：重做。
class RedoIntent extends Intent {
  const RedoIntent();
}

/// Delete：删除选择集。
class DeleteSelectionIntent extends Intent {
  const DeleteSelectionIntent();
}

/// Ctrl+E：打开导出。
class ExportIntent extends Intent {
  const ExportIntent();
}

/// Ctrl+F：聚焦搜索框。
class FocusSearchIntent extends Intent {
  const FocusSearchIntent();
}

/// Ctrl+O：打开工程文件（`.ovimap`）。
class OpenProjectIntent extends Intent {
  const OpenProjectIntent();
}

/// 桌面快捷键容器：把一组回调接到对应 Intent 上。
class DesktopShortcuts extends StatelessWidget {
  const DesktopShortcuts({
    super.key,
    required this.child,
    required this.onSave,
    required this.onUndo,
    required this.onRedo,
    required this.onDeleteSelection,
    required this.onExport,
    required this.onFocusSearch,
    required this.onOpenProject,
  });

  final Widget child;
  final VoidCallback onSave;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onDeleteSelection;
  final VoidCallback onExport;
  final VoidCallback onFocusSearch;
  final VoidCallback onOpenProject;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyS, control: true): SaveIntent(),
        SingleActivator(LogicalKeyboardKey.keyZ, control: true): UndoIntent(),
        SingleActivator(LogicalKeyboardKey.keyY, control: true): RedoIntent(),
        SingleActivator(
            LogicalKeyboardKey.keyZ, control: true, shift: true): RedoIntent(),
        SingleActivator(LogicalKeyboardKey.delete): DeleteSelectionIntent(),
        SingleActivator(LogicalKeyboardKey.keyE, control: true): ExportIntent(),
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            FocusSearchIntent(),
        SingleActivator(LogicalKeyboardKey.keyO, control: true):
            OpenProjectIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          SaveIntent: CallbackAction<SaveIntent>(
              onInvoke: (_) => _run(onSave)),
          UndoIntent: CallbackAction<UndoIntent>(
              onInvoke: (_) => _run(onUndo)),
          RedoIntent: CallbackAction<RedoIntent>(
              onInvoke: (_) => _run(onRedo)),
          DeleteSelectionIntent: CallbackAction<DeleteSelectionIntent>(
              onInvoke: (_) => _run(onDeleteSelection)),
          ExportIntent: CallbackAction<ExportIntent>(
              onInvoke: (_) => _run(onExport)),
          FocusSearchIntent: CallbackAction<FocusSearchIntent>(
              onInvoke: (_) => _run(onFocusSearch)),
          OpenProjectIntent: CallbackAction<OpenProjectIntent>(
              onInvoke: (_) => _run(onOpenProject)),
        },
        // autofocus 保证快捷键在无其它可聚焦控件时也能命中。
        child: Focus(autofocus: true, child: child),
      ),
    );
  }

  /// 统一的 Action 包装：执行回调并返回 null（满足 `CallbackAction` 签名）。
  Object? _run(VoidCallback cb) {
    cb();
    return null;
  }
}
