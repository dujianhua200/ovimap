import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/fav_node.dart';
import '../../state/app_state.dart';
import '../../state/fav_tree_controller.dart';
import '../design_tokens.dart';
import '../dialogs.dart';
import 'fav_actions.dart';
import 'fav_tree.dart';
import 'trash.dart';

/// 收藏树节点菜单的追加项扩展点（桌面/移动通用）。
///
/// - 桌面：如「把当前画布收藏到此」（left_panel 传入）；
/// - 移动：如 7 个工程操作（`favMobileProjectExtra()`，drawer_panel 传入）。
/// 桌面走 showMenu 追加；移动走底弹菜单追加（PopupMenuItem 的 tap 即
/// Navigator.pop 返回 value，同样可用）。
class FavMenuExtra {
  const FavMenuExtra({required this.entries, required this.onSelected});

  /// 追加的菜单项（value 建议以 `extra:` 开头以便区分）。
  final List<PopupMenuEntry<String>> Function(FavNode node) entries;

  final Future<void> Function(BuildContext context, FavTreeController c,
      FavNode node, String value) onSelected;
}

class _Mi {
  final String value;
  final String label;
  final bool danger;
  const _Mi(this.value, this.label, {this.danger = false});
}

/// 收藏树节点右键/长按菜单（桌面/移动共用）。
///
/// - 桌面（[isDesktop]=true）：在 [position] 处弹 `showMenu`；
/// - 移动：底部弹出菜单。
/// 菜单项按 kind 取舍；删除一律进回收站（审计问题 8），确认框显示影响数量。
Future<void> showFavNodeMenu(BuildContext context, FavTreeController c,
    FavNode node,
    {required bool isDesktop, Offset? position, FavMenuExtra? extra}) async {
  final st = Provider.of<AppState>(context, listen: false);

  final items = <_Mi>[];
  if (node.isFolder) {
    items.addAll(const [
      _Mi('newSub', '新建子文件夹'),
      _Mi('rename', '重命名'),
      _Mi('moveTo', '移动到…'),
      _Mi('toggleVisible', '显隐'),
      _Mi('delete', '删除（进回收站）', danger: true),
    ]);
  } else if (node.isProject) {
    items.addAll(const [
      _Mi('rename', '重命名'),
      _Mi('moveTo', '移动到…'),
      _Mi('toggleVisible', '显隐'),
      _Mi('locate', '定位'),
      _Mi('style', '改样式'),
      _Mi('merge', '合并到…'),
      _Mi('export', '导出'),
      _Mi('delete', '删除（进回收站）', danger: true),
    ]);
  } else if (node.isMark) {
    items.addAll(const [
      _Mi('locate', '定位'),
      _Mi('moveTo', '移动到…'),
      _Mi('toggleVisible', '显隐'),
      _Mi('style', '查看 / 修改属性'),
      _Mi('delete', '删除标记', danger: true),
    ]);
  } else if (node.isChain) {
    items.addAll(const [
      _Mi('locate', '定位到线组'),
      _Mi('moveTo', '移动到…'),
      _Mi('delete', '删除整条线', danger: true),
    ]);
  }

  String? sel;
  if (isDesktop) {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final pos = position ??
        Offset(overlay.size.width / 2, overlay.size.height / 2);
    final entries = <PopupMenuEntry<String>>[
      for (final it in items)
        PopupMenuItem(
          value: it.value,
          height: 34,
          child: Text(it.label,
              style: TextStyle(
                  color: it.danger ? kDanger : kTextMain,
                  fontSize: TokFs.body)),
        ),
      if (extra != null) ...extra.entries(node),
    ];
    sel = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
          Rect.fromPoints(pos, pos), Offset.zero & overlay.size),
      color: kPanelBg,
      items: entries,
    );
  } else {
    sel = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final it in items)
                ListTile(
                  dense: true,
                  title: Text(it.label,
                      style: TextStyle(
                          color: it.danger ? kDanger : kTextMain)),
                  onTap: () => Navigator.pop(ctx, it.value),
                ),
              // 追加项（value 以 `extra:` 开头）：桌面/移动通用扩展点。
              // PopupMenuItem 的 handleTap 即 Navigator.pop(ctx, value)，
              // 在底弹里同样能返回值。
              if (extra != null) ...extra.entries(node),
            ],
          ),
        ),
      ),
    );
  }
  if (sel == null || !context.mounted) return;
  if (extra != null && sel.startsWith('extra:')) {
    await extra.onSelected(context, c, node, sel);
    return;
  }
  await _handleMenuAction(context, c, st, node, sel);
}

TrashStore _trashOf(BuildContext context, AppState st) {
  try {
    return Provider.of<TrashStore>(context, listen: false);
  } catch (_) {
    return TrashStore(onChanged: () => st.refreshCollections());
  }
}

Future<void> _handleMenuAction(BuildContext context, FavTreeController c,
    AppState st, FavNode node, String action) async {
  switch (action) {
    case 'rename':
      final name = await askText(context,
          title: node.isFolder ? '重命名文件夹' : '重命名', initial: node.name);
      if (name == null || !context.mounted) return;
      if (node.isFolder) {
        await st.store.renameFolder(node.id, name);
      } else if (node.isProject) {
        await st.store.renameCollection(node.id, name);
      }
      await st.refreshCollections();
      break;

    case 'newSub':
      final name = await askText(context,
          title: '新建子文件夹', hint: '文件夹名称（建在「${node.name}」内）');
      if (name == null || !context.mounted) return;
      await st.store.addFolder(name, node.id);
      await st.refreshCollections();
      if (context.mounted) toast(context, '已创建文件夹「$name」');
      break;

    case 'moveTo': {
      final target = await pickFavFolder(context, c,
          title: '移动「${node.name}」',
          excludeSubtree: node.isFolder ? node.id : '',
          initial: node.pid);
      if (target == null || !context.mounted) return;
      if (target == node.pid) return;
      final ok = await c.moveToFolder(node, target);
      if (context.mounted) {
        toast(context, ok ? '已移动「${node.name}」' : '移动失败');
      }
      break;
    }

    case 'toggleVisible':
      if (!context.mounted) return;
      await setNodeVisible(context, c, node, !c.isVisible(node.id));
      break;

    case 'locate': {
      final scope = FavTreeScope.of(context);
      final cb = scope?.onLocate;
      if (cb == null) {
        if (context.mounted) toast(context, '当前视图不支持定位');
        return;
      }
      if (node.isMark && node.label != null) {
        await cb(node);
      } else {
        final cid = node.isProject ? node.id : (node.chainCid ?? '');
        if (cid.isEmpty) return;
        final labels = await c.labelsOf(cid);
        if (labels.isEmpty) {
          if (context.mounted) toast(context, '「${node.name}」内无点位');
          return;
        }
        await cb(FavNode.markNode(labels.first, pid: cid, cid: cid));
      }
      break;
    }

    case 'style':
      if (node.isProject) {
        final meta = node.project;
        final picked = await pickProjectStyle(context,
            initialColor: meta?.color ?? 0,
            initialWidth: (meta?.width ?? 0) > 0
                ? meta!.width
                : 3.0);
        if (picked == null || !context.mounted) return;
        await st.store
            .setCollectionStyle(node.id, picked.$1, picked.$2);
        await st.refreshCollections();
        if (context.mounted) toast(context, '已更新「${node.name}」样式');
      } else if (node.isMark && node.label != null) {
        if (!context.mounted) return;
        await showLabelProperties(context, st, node.label!,
            sourceCid: node.labelCid ?? '', title: node.name);
      }
      break;

    case 'merge': {
      final others = c.projects
          .where((p) => p.id != node.id && p.project?.kind != 'mark')
          .toList();
      if (others.isEmpty) {
        if (context.mounted) toast(context, '没有可合并的目标工程');
        return;
      }
      String? toCid = others.first.id;
      var picked = false;
      await showDarkDialog(
        context,
        title: '合并「${node.name}」到…',
        content: StatefulBuilder(
          builder: (ctx, setSt) => DropdownButtonFormField<String>(
            initialValue: toCid,
            dropdownColor: TokC.panelSolid,
            isExpanded: true,
            style:
                const TextStyle(color: kTextMain, fontSize: TokFs.body),
            decoration: dec('合并到…'),
            items: [
              for (final p in others)
                DropdownMenuItem(value: p.id, child: Text(p.name)),
            ],
            onChanged: (v) => setSt(() => toCid = v),
          ),
        ),
        actions: [
          darkTextBtn('取消', () => Navigator.pop(context),
              color: kTextSub),
          darkTextBtn('下一步', () {
            picked = true;
            Navigator.pop(context);
          }, color: kGreen),
        ],
      );
      if (!picked || toCid == null || !context.mounted) return;
      final toName = c.find(toCid!)?.name ?? '';
      final fromLabels = await c.labelsOf(node.id);
      if (!context.mounted) return;
      final ok = await askConfirm(context,
          title: '合并工程',
          content: '将「${node.name}」（${fromLabels.length} 点）并入「$toName」，'
              '「${node.name}」随后会被删除（先备份进回收站，可还原）。确定？',
          okText: '合并');
      if (!ok || !context.mounted) return;
      // 先备份进回收站再合：源工程被删后 mergeProject 读不到点，
      // 所以这里手动把已捕获的点追加到目标工程。
      await _trashOf(context, st).trashNode(c, node);
      if (fromLabels.isNotEmpty) {
        final toMeta = c.find(toCid!)?.project;
        if (toMeta != null) {
          final toLabels = await c.store.loadCollection(toCid!);
          for (final l in fromLabels) {
            l.seq = toLabels.length + 1;
            toLabels.add(l);
          }
          await c.store.finishCollection(
            existingId: toCid!,
            name: toMeta.name,
            kind: toMeta.kind,
            folderId: toMeta.folder,
            editMode: toMeta.editMode,
            labels: toLabels,
          );
          await st.refreshCollections();
        }
      }
      if (context.mounted) {
        toast(context, '已合并 ${fromLabels.length} 点到「$toName」');
      }
      break;
    }

    case 'export': {
      if (!node.isProject || !context.mounted) return;
      final labels = await c.labelsOf(node.id);
      if (!context.mounted) return;
      await showExportDialog(
          context, List.of(labels), node.name, segPrefix: st.segPrefix);
      break;
    }

    case 'delete':
      await _deleteNode(context, c, st, node);
      break;
  }
}

/// 删除节点：folder/project 进回收站（含影响数量确认框）；mark/chain 直接删。
Future<void> _deleteNode(BuildContext context, FavTreeController c,
    AppState st, FavNode node) async {
  final trash = _trashOf(context, st);
  if (node.isFolder) {
    final subCount =
        c.folders.where((f) => _isDescendant(c, f.id, node.id)).length;
    final n = await c.countOf(node.id);
    if (!context.mounted) return;
    final ok = await askConfirm(context,
        title: '删除文件夹',
        content: '将删除「${node.name}」'
            '${subCount > 0 ? '及其 $subCount 个子文件夹' : ''}'
            '（共 $n 个条目，含标记点），'
            '删除后可在回收站还原。确定？',
        okText: '删除');
    if (!ok || !context.mounted) return;
    await trash.trashNode(c, node);
    if (c.treeSelectedFolderId == node.id ||
        _isDescendant(c, c.treeSelectedFolderId, node.id)) {
      c.selectTreeFolder('');
    }
    if (context.mounted) toast(context, '「${node.name}」已移入回收站');
  } else if (node.isProject) {
    final n = (await c.labelsOf(node.id)).length;
    if (!context.mounted) return;
    final ok = await askConfirm(context,
        title: '删除工程',
        content: '将删除「${node.name}」（$n 点），可在回收站还原。确定？',
        okText: '删除');
    if (!ok || !context.mounted) return;
    await trash.trashNode(c, node);
    if (context.mounted) toast(context, '「${node.name}」已移入回收站');
  } else if (node.isMark && node.label != null) {
    final ok = await askConfirm(context,
        title: '删除标记', content: '将删除标记「${node.name}」。确定？',
        okText: '删除');
    if (!ok || !context.mounted) return;
    await st.removeOverlayLabel(node.labelCid ?? '', node.label!);
    if (context.mounted) toast(context, '已删除标记「${node.name}」');
  } else if (node.isChain) {
    final members = await c.childrenOf(node.id);
    if (!context.mounted) return;
    final ok = await askConfirm(context,
        title: '删除线组',
        content: '将删除「${node.name}」（${members.length} 点）。确定？',
        okText: '删除');
    if (!ok || !context.mounted) return;
    final cid = node.chainCid ?? '';
    for (final m in members) {
      if (m.label != null) await st.removeOverlayLabel(cid, m.label!);
    }
    if (context.mounted) toast(context, '已删除「${node.name}」');
  }
}

bool _isDescendant(FavTreeController c, String fid, String ancestor) {
  if (fid.isEmpty || fid == ancestor) return false;
  var p = c.find(fid)?.pid ?? '';
  final seen = <String>{};
  while (p.isNotEmpty && seen.add(p)) {
    if (p == ancestor) return true;
    p = c.find(p)?.pid ?? '';
  }
  return false;
}
