import 'package:flutter/foundation.dart';

/// 全局撤销/重做核心（W1）。
///
/// 与 [AppState] 的草稿快照栈（pushUndoSnapshot / undoDraft / redo）并存：
/// 草稿栈管"正在编辑的草稿点位"，本栈管"收藏结构性操作"（移动/重命名/
 /// 回收站/合并/标记编辑等）。UI（workspace_page._undo/_redo）按
/// [UndoStack.lastChangeAt] 与 [AppState.lastDraftUndoPushAt] 二选一。
///
/// 设计约束（DESIGN.md §1）：
/// - 磁盘格式零改动；undo 只存反向操作最小数据（mergeProject 例外，
///   见 [FavTreeController.mergeProject] 注释——复合操作需全量快照）。
/// - 栈是纯内存的，重启即清空；上限 50。
class UndoCommand {
  UndoCommand({
    required this.description,
    required this.doIt,
    required this.undoIt,
  });

  /// 面向用户的中文描述（如"移动文件夹「A」"），用于按钮 tooltip。
  final String description;

  /// 执行本体。返回 true = 成功（成功才压栈）；返回 false = 无事发生，
  /// 不压栈；抛异常 = 不压栈，异常向上传播。
  final Future<bool> Function() doIt;

  /// 逆操作。返回 false = 失败但不抛错（如目标工程已被删），此时命令
  /// 不进入 redo 栈；抛异常则向上传播，命令同样不进入 redo 栈。
  final Future<bool> Function() undoIt;
}

/// 可撤销操作栈。
///
/// suspend 机制：[execute]/[undo]/[redo] 运行 do/undo/redo 期间内部
/// [_suspended] 置 true；此期间的重入 [execute] 调用只执行本体、
/// 不再记录（外层命令已拥有本次变更）——防止"撤销的撤销"被重复记录。
class UndoStack extends ChangeNotifier {
  UndoStack({this.maxSize = 50});

  final int maxSize;

  final List<UndoCommand> _undo = [];
  final List<UndoCommand> _redo = [];

  bool _suspended = false;

  /// 最近一次 execute/undo/redo 成功改变栈的时间（UI 二选一逻辑用）。
  ///
  /// 失败的 undo（undoIt 返回 false）不改变有效状态，故不更新——否则
  /// 下一次 _undo 会反复选中这个走不通的全局栈。
  DateTime lastChangeAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 是否正处于 do/undo/redo 执行中（重入保护标志；测试可见）。
  bool get isSuspended => _suspended;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  int get undoCount => _undo.length;
  int get redoCount => _redo.length;

  /// 最近一条可撤销/可重做的描述（UI tooltip 用）。
  String? get lastUndoDescription =>
      _undo.isEmpty ? null : _undo.last.description;
  String? get lastRedoDescription =>
      _redo.isEmpty ? null : _redo.last.description;

  /// 执行并记录一条命令。
  ///
  /// - suspend 期间调用：只执行 [doIt]，不压栈（防重入记录）。
  /// - [doIt] 返回 false 或抛异常：不压栈、不清空 redo 栈。
  /// - 成功：压栈并清空 redo 栈（标准语义），更新 [lastChangeAt]。
  Future<bool> execute(String description, Future<bool> Function() doIt,
      Future<bool> Function() undoIt) async {
    if (_suspended) return doIt();
    _suspended = true;
    bool ok;
    try {
      ok = await doIt();
    } finally {
      _suspended = false;
    }
    if (!ok) return false;
    _undo.add(UndoCommand(description: description, doIt: doIt, undoIt: undoIt));
    if (_undo.length > maxSize) {
      _undo.removeRange(0, _undo.length - maxSize);
    }
    _redo.clear();
    lastChangeAt = DateTime.now();
    notifyListeners();
    return true;
  }

  /// 撤销最近一条。成功后命令进入 redo 栈；undoIt 返回 false/抛异常时
  /// 不进入 redo 栈（状态未干净回退，重做无意义）。
  Future<bool> undo() async {
    if (_undo.isEmpty) return false;
    final cmd = _undo.last;
    _suspended = true;
    bool ok;
    try {
      ok = await cmd.undoIt();
    } finally {
      _suspended = false;
    }
    _undo.removeLast();
    if (ok) {
      _redo.add(cmd);
      if (_redo.length > maxSize) {
        _redo.removeRange(0, _redo.length - maxSize);
      }
      lastChangeAt = DateTime.now();
    }
    notifyListeners();
    return ok;
  }

  /// 重做最近一条撤销（与 [undo] 对偶）。
  Future<bool> redo() async {
    if (_redo.isEmpty) return false;
    final cmd = _redo.last;
    _suspended = true;
    bool ok;
    try {
      ok = await cmd.doIt();
    } finally {
      _suspended = false;
    }
    _redo.removeLast();
    if (ok) {
      _undo.add(cmd);
      if (_undo.length > maxSize) {
        _undo.removeRange(0, _undo.length - maxSize);
      }
      lastChangeAt = DateTime.now();
    }
    notifyListeners();
    return ok;
  }

  void clear() {
    _undo.clear();
    _redo.clear();
    notifyListeners();
  }
}

/// 全局栈 vs 草稿栈二选一（workspace_page._undo/_redo 用；纯函数便于单测）。
///
/// 规则：全局栈非空 **且** 其最近变更严格晚于草稿栈最近压栈时，走全局；
/// 否则走草稿。两边都空时调用方无操作。
bool shouldUseGlobalUndo({
  required bool canUndo,
  required DateTime lastChangeAt,
  required DateTime lastDraftPushAt,
}) =>
    canUndo && lastChangeAt.isAfter(lastDraftPushAt);
