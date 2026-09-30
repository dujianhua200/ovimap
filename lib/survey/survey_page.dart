library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/map_label.dart';
import '../state/app_state.dart';
import '../ui/design_tokens.dart';
import '../ui/dialogs.dart';
import 'survey_form.dart';
import 'survey_store.dart';

/// 勘察表单页（移动端优先：大按钮、大字号输入、底部常驻保存）。
///
/// - GPS/标记坐标只读显示（WGS-84）；
/// - 照片缩略图网格只加载缩略图（`cacheWidth`），点击看大图，长按删除；
/// - 保存：表单写回 `label.extra['survey']`，走 AppState 现有
///   `updateLabel` / `updateOverlayLabel` 路径（Phase 3 已接 UndoStack）。
class SurveyPage extends StatefulWidget {
  const SurveyPage({
    super.key,
    required this.st,
    required this.label,
    required this.cid,
  });

  final AppState st;
  final MapLabel label;

  /// 标记所属工程 id；草稿标记传空串。
  final String cid;

  @override
  State<SurveyPage> createState() => _SurveyPageState();
}

class _SurveyPageState extends State<SurveyPage> {
  late final SurveyForm _form;
  late final TextEditingController _surveyorCtl;
  late final TextEditingController _poleTypeCtl;
  late final TextEditingController _poleHeightCtl;
  late final TextEditingController _envCtl;
  late final TextEditingController _adviceCtl;
  bool _canErect = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _form = SurveyForm.fromLabel(widget.label) ?? SurveyForm();
    _surveyorCtl = TextEditingController(text: _form.surveyor);
    _poleTypeCtl = TextEditingController(text: _form.poleType);
    _poleHeightCtl = TextEditingController(
        text: _form.poleHeight == null
            ? ''
            : _form.poleHeight.toString().replaceAll(RegExp(r'\.0$'), ''));
    _envCtl = TextEditingController(text: _form.envDesc);
    _adviceCtl = TextEditingController(text: _form.advice);
    _canErect = _form.canErect;
  }

  @override
  void dispose() {
    _surveyorCtl.dispose();
    _poleTypeCtl.dispose();
    _poleHeightCtl.dispose();
    _envCtl.dispose();
    _adviceCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    _form
      ..surveyor = _surveyorCtl.text.trim()
      ..poleType = _poleTypeCtl.text.trim()
      ..poleHeight = double.tryParse(_poleHeightCtl.text.trim())
      ..envDesc = _envCtl.text.trim()
      ..canErect = _canErect
      ..advice = _adviceCtl.text.trim();
    _form.applyTo(widget.label);
    if (widget.cid.isEmpty) {
      widget.st.updateLabel(widget.label);
    } else {
      await widget.st.updateOverlayLabel(widget.cid, widget.label);
    }
    if (mounted) {
      setState(() => _saving = false);
      toast(context, '勘察表单已保存');
      Navigator.pop(context, true);
    }
  }

  Future<void> _addPhoto(ImageSource src) async {
    final rel = await SurveyStore.pickAndImport(
        widget.cid, widget.label.id, src);
    if (rel == null) {
      if (mounted) toast(context, '未获取到照片');
      return;
    }
    setState(() => _form.photos.add(rel));
    if (mounted) toast(context, '已添加照片（${_form.photos.length} 张）');
  }

  Future<void> _removePhoto(int index) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除照片'),
            content: const Text('从表单移除这张照片？（文件保留在照片目录）'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('删除',
                      style: TextStyle(color: kDanger))),
            ],
          ),
        ) ??
        false;
    if (ok && mounted) setState(() => _form.photos.removeAt(index));
  }

  Future<void> _viewPhoto(String rel) async {
    final abs = await SurveyStore.absPath(rel);
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: InteractiveViewer(
          maxScale: 4,
          child: Image.file(File(abs), fit: BoxFit.contain,
              errorBuilder: (_, _, _) =>
                  const Center(child: Text('照片文件不存在'))),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.label.name.isEmpty
        ? widget.label.type.name
        : widget.label.name;
    return Scaffold(
      appBar: AppBar(
        title: Text('勘察表单 · $name'),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save, color: kGreen),
            label: const Text('保存',
                style: TextStyle(color: kGreen, fontSize: 16)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _coordCard(),
              const SizedBox(height: 12),
              _field('勘察人', _surveyorCtl, hint: '姓名'),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                      child: _field('杆型', _poleTypeCtl,
                          hint: '如：8米水泥杆')),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _field('杆高（米）', _poleHeightCtl,
                        hint: '如：8',
                        keyboard:
                            const TextInputType.numberWithOptions(
                                decimal: true)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _erectToggle(),
              const SizedBox(height: 10),
              _field('周边环境', _envCtl,
                  hint: '如：道路东侧绿化带，无遮挡', maxLines: 3),
              const SizedBox(height: 10),
              _field('敷设建议', _adviceCtl,
                  hint: '如：沿路东侧架空敷设', maxLines: 3),
              const SizedBox(height: 12),
              _photoSection(),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
          child: SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save, size: 22),
              label: Text(_saving ? '保存中…' : '保存勘察表单',
                  style: const TextStyle(fontSize: 18)),
              style: ElevatedButton.styleFrom(
                backgroundColor: kGreen,
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 标记坐标只读卡（WGS-84）+ 勘察时间。
  Widget _coordCard() {
    final t = _form.surveyedAt;
    final ts =
        '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return Card(
      color: kCardBg,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('点位坐标（WGS-84，只读）',
                style: TextStyle(color: kTextSub, fontSize: TokFs.small)),
            const SizedBox(height: 4),
            SelectableText(
              '${widget.label.lat.toStringAsFixed(6)}, '
              '${widget.label.lon.toStringAsFixed(6)}',
              style:
                  const TextStyle(color: kTextMain, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text('勘察时间：$ts',
                style: TextStyle(color: kTextSub, fontSize: TokFs.small)),
          ],
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController ctl,
      {String hint = '',
      int maxLines = 1,
      TextInputType? keyboard}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: kTextMain, fontSize: 16)),
        const SizedBox(height: 6),
        TextField(
          controller: ctl,
          maxLines: maxLines,
          keyboardType: keyboard,
          style: const TextStyle(fontSize: 16),
          decoration: dec(hint).copyWith(
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 14),
          ),
        ),
      ],
    );
  }

  /// 是否可立杆：两个大按钮二选一（移动端手指友好）。
  Widget _erectToggle() {
    Widget btn(bool value, String text, IconData icon) {
      final sel = _canErect == value;
      return Expanded(
        child: SizedBox(
          height: 52,
          child: OutlinedButton.icon(
            onPressed: () => setState(() => _canErect = value),
            icon: Icon(icon,
                color: sel
                    ? (value ? kGreen : kDanger)
                    : kTextSub),
            label: Text(text,
                style: TextStyle(
                    fontSize: 17,
                    color: sel
                        ? (value ? kGreen : kDanger)
                        : kTextSub)),
            style: OutlinedButton.styleFrom(
              side: BorderSide(
                  color: sel
                      ? (value ? kGreen : kDanger)
                      : kTextSub,
                  width: sel ? 2 : 1),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('是否可立杆',
            style: TextStyle(color: kTextMain, fontSize: 16)),
        const SizedBox(height: 6),
        Row(
          children: [
            btn(true, '可立杆', Icons.check_circle),
            const SizedBox(width: 10),
            btn(false, '不可立杆', Icons.cancel),
          ],
        ),
      ],
    );
  }

  Widget _photoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('勘察照片',
                style: TextStyle(color: kTextMain, fontSize: 16)),
            const SizedBox(width: 8),
            Text('（${_form.photos.length} 张，点击看大图，长按删除）',
                style:
                    TextStyle(color: kTextSub, fontSize: TokFs.small)),
          ],
        ),
        const SizedBox(height: 8),
        if (_form.photos.isNotEmpty)
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate:
                const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: _form.photos.length,
            itemBuilder: (ctx, i) {
              final rel = _form.photos[i];
              return GestureDetector(
                onTap: () => _viewPhoto(rel),
                onLongPress: () => _removePhoto(i),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: FutureBuilder<String>(
                    future: SurveyStore.absPath(rel),
                    builder: (ctx, snap) {
                      if (!snap.hasData) {
                        return Container(color: kFieldBg);
                      }
                      // 缩略图：只解码到 256px 宽，列表不加载原图。
                      return Image.file(
                        File(snap.data!),
                        fit: BoxFit.cover,
                        cacheWidth: 256,
                        errorBuilder: (_, _, _) => Container(
                          color: kFieldBg,
                          child: const Icon(Icons.broken_image,
                              color: kTextSub),
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          ),
        if (_form.photos.isNotEmpty) const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () => _addPhoto(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera,
                      color: kAccent),
                  label: const Text('拍照',
                      style:
                          TextStyle(color: kAccent, fontSize: 17)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () => _addPhoto(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library,
                      color: kAccent),
                  label: const Text('从相册选择',
                      style:
                          TextStyle(color: kAccent, fontSize: 17)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
