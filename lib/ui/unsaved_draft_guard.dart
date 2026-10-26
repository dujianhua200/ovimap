import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'design_tokens.dart';
import 'dialogs.dart';

/// 切换工程前的未保存草稿护栏。
///
/// 用户手头的草稿只存在 `draft.json`；打开其它工程会立刻用目标工程覆盖它。
/// 以前没有任何提示，切错工程就丢一批现场点。这里给三个明确选择：
/// 取消 / 放弃草稿 / 保存后继续。
///
/// 返回 true = 可以继续（本来就没有草稿、已保存、或用户明确放弃）；
/// false = 用户取消（调用方 must return，不做任何切换）。
Future<bool> confirmReplaceUnsavedDraft(
    BuildContext context, AppState st) async {
  if (!st.hasUnsavedDraft) return true;

  var action = '';
  await showDarkDialog(
    context,
    title: '当前草稿还没保存',
    content: Text(
      '当前有 ${st.labels.length} 个点尚未保存为工程。\n'
      '继续打开 / 新建会替换这份草稿。',
      style: const TextStyle(color: kTextMain, fontSize: TokFs.body, height: 1.5),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('放弃草稿', () {
        action = 'discard';
        Navigator.pop(context);
      }, color: TokC.danger),
      darkTextBtn('保存后继续', () {
        action = 'save';
        Navigator.pop(context);
      }, color: kGreen),
    ],
  );

  if (action == 'save') {
    if (st.projectName.trim().isEmpty) st.projectName = _timestampDraftName();
    try {
      await st.finishCollection();
    } catch (e) {
      if (context.mounted) toast(context, '保存草稿失败：$e');
      return false;
    }
    if (context.mounted) {
      toast(context, '已保存当前草稿为「${st.projectName}」，继续打开目标工程');
    }
    return true;
  }
  return action == 'discard';
}

/// 这组外部文件里是否包含 `.ovimap`（导入它会替换当前草稿）。
///
/// 拖放、左栏导入、Ctrl+O 三个入口都用它判断是否需要先弹草稿护栏。
bool containsProjectFile(List<String> paths) =>
    paths.any((p) => p.toLowerCase().endsWith('.ovimap'));

/// 自动保存未命名草稿时的默认工程名。
String _timestampDraftName([DateTime? now]) {
  final d = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '草稿 ${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}';
}
