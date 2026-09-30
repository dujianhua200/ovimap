import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/fav_node.dart';
import '../../models/map_label.dart';
import '../../services/store.dart'
    show CollectionMeta, LabelStore, robustWriteAsString;
import '../../state/app_state.dart';
import '../../state/fav_tree_controller.dart';
import '../design_tokens.dart';
import '../dialogs.dart';
import 'fav_actions.dart';

/// 回收站（审计问题 8：删除不可撤销 → 删除进回收站，可还原/彻底删除）。
///
/// 磁盘格式零改动：只新增 `<labelsDir>/trash.json` 一个文件；
/// folders.json / index.json / `collection_<cid>.json` 的读写逻辑
/// 在本文件内自包含镜像（不动 `store.dart`）。

class TrashItem {
  String trashId;
  String kind; // folder | project
  String name;
  String payloadJson;
  DateTime deletedAt;

  TrashItem({
    required this.trashId,
    required this.kind,
    required this.name,
    required this.payloadJson,
    required this.deletedAt,
  });

  factory TrashItem.fromJson(Map<String, dynamic> o) => TrashItem(
        trashId: (o['trashId'] as String?) ?? '',
        kind: (o['kind'] as String?) ?? 'project',
        name: (o['name'] as String?) ?? '',
        payloadJson: (o['payloadJson'] as String?) ?? '{}',
        deletedAt: DateTime.tryParse((o['deletedAt'] as String?) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  Map<String, dynamic> toJson() => {
        'trashId': trashId,
        'kind': kind,
        'name': name,
        'payloadJson': payloadJson,
        'deletedAt': deletedAt.toIso8601String(),
      };
}

class TrashStore extends ChangeNotifier {
  TrashStore({this.onChanged, LabelStore? store, this.appState})
      : _store = store ?? LabelStore.instance;

  /// 删除/恢复/清空后调用（调用方接 `st.refreshCollections()` 等）。
  final Future<void> Function()? onChanged;
  final LabelStore _store;

  /// 宿主 [AppState]（undo 记录用；为 null 时退化为 raw 行为，不记录）。
  /// 生产环境经各 `_trashOf` 传入；测试按需传入。
  final AppState? appState;

  final List<TrashItem> _items = [];
  List<TrashItem> get items => List.unmodifiable(_items);

  Future<File> _file() async =>
      File('${(await _store.labelsDir()).path}/trash.json');

  Future<void> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) {
        _items.clear();
      } else {
        final decoded = jsonDecode(await f.readAsString());
        final list = decoded is List ? decoded : const [];
        _items
          ..clear()
          ..addAll(list.map((e) =>
              TrashItem.fromJson(Map<String, dynamic>.from(e as Map))));
        _items.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
      }
      // D1：30 天过期——deletedAt 超过 30 天的条目自动丢弃，并把裁剪后的
      // 列表写回 trash.json。解析失败的 deletedAt 兜底为 epoch（必过期被清）。
      final now = DateTime.now();
      final before = _items.length;
      _items.removeWhere((e) => now.difference(e.deletedAt).inDays > 30);
      if (_items.length != before) await _persist();
    } catch (_) {
      _items.clear();
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      await robustWriteAsString(
          await _file(), jsonEncode(_items.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  /// 把节点送进回收站（可撤销，返回 trashId）。
  ///
  /// undo = restore(trashId)；redo = 根据 nodeId 经 controller.find 找
  /// 当前节点重新 trash，找不到则 redo 返回 false 不抛错。
  /// 逆操作经 public [restore] 实现——suspend 机制保证 undo/redo 期间
  /// 内层 execute 只执行本体、不再重复记录。
  Future<String> trashNode(FavTreeController c, FavNode node) async {
    final st = c.appState;
    final nodeId = node.id;
    final kindName = node.isFolder ? '文件夹' : '工程';
    final displayName = node.name;
    var trashId = '';
    await st.undoStack.execute(
      '删除$kindName「$displayName」（进回收站）',
      () async {
        final cur = c.find(nodeId);
        if (cur == null) return false;
        trashId = await _trashNodeRaw(c, cur);
        return true;
      },
      () async {
        await restore(trashId);
        return true;
      },
    );
    return trashId;
  }

  /// 把节点送进回收站（raw：自身不记录撤销，由 [trashNode] 包裹）。
  ///
  /// - project → `deleteCollection`，payload 记 CollectionMeta JSON + labels；
  /// - folder → 整棵子树：子树内工程逐个 `deleteCollection`（payload 记
  ///   meta + labels），再 `store.deleteFolder` 删文件夹条目，payload 记
  ///   folder JSON 列表 + 工程 cid 列表。
  ///
  /// 返回本次的 trashId。
  Future<String> _trashNodeRaw(FavTreeController c, FavNode node) async {
    await load();
    final st = c.appState;
    final trashId = 't${DateTime.now().microsecondsSinceEpoch}';
    if (node.isProject) {
      final cid = node.id;
      final meta = node.project ??
          st.collections
              .where((m) => m.id == cid)
              .map((m) => m)
              .toList()
              .firstOrNullSafe();
      final labels = await c.labelsOf(cid);
      final payload = jsonEncode({
        'meta': (meta ?? CollectionMeta(id: cid, name: node.name)).toJson(),
        'labels': labels.map((l) => l.toJson()).toList(),
      });
      // 统一入口：清理可见集合 + 刷新 + 通知同步器（服务端软删除）。
      await st.deleteCollection(cid);
      _items.add(TrashItem(
          trashId: trashId,
          kind: 'project',
          name: node.name,
          payloadJson: payload,
          deletedAt: DateTime.now()));
    } else if (node.isFolder) {
      final fid = node.id;
      final allFolders = await _store.loadFolders();
      final doomed = <String>{fid};
      var grew = true;
      while (grew) {
        grew = false;
        for (final f in allFolders) {
          if (f.id.isNotEmpty &&
              doomed.contains(f.parentId) &&
              doomed.add(f.id)) {
            grew = true;
          }
        }
      }
      final folderJsons = [
        for (final f in allFolders)
          if (doomed.contains(f.id))
            {'id': f.id, 'name': f.name, 'parentId': f.parentId},
      ];
      final projs = <Map<String, dynamic>>[];
      for (final m in st.collections.where((m) => doomed.contains(m.folder))) {
        final labels = await c.labelsOf(m.id);
        projs.add({
          'meta': m.toJson(),
          'labels': labels.map((l) => l.toJson()).toList(),
        });
      }
      final payload = jsonEncode({
        'folders': folderJsons,
        'projects': projs,
      });
      for (final p in projs) {
        await st.deleteCollection(
            (p['meta'] as Map<String, dynamic>)['id'] as String);
      }
      // 子树工程已删完，这里只删文件夹条目（不再上移工程）。
      await _store.deleteFolder(fid);
      _items.add(TrashItem(
          trashId: trashId,
          kind: 'folder',
          name: node.name,
          payloadJson: payload,
          deletedAt: DateTime.now()));
    } else {
      throw ArgumentError('trashNode 仅支持 folder/project，got ${node.kind}');
    }
    await _persist();
    notifyListeners();
    await onChanged?.call();
    return trashId;
  }

  /// 还原（可撤销）。原 parentId / folder 不存在则回根（''）。
  ///
  /// undo = 删除还原的内容（project：deleteCollection；folder：按 payload
  /// 删工程 + 文件夹条目——先删工程再删文件夹条目，避免 deleteFolder 把
  /// 其它工程上移）并把 TrashItem 写回 trash.json；redo = 再次 restore。
  Future<void> restore(String trashId) async {
    await load();
    final i = _items.indexWhere((e) => e.trashId == trashId);
    if (i < 0) return;
    final item = _items[i];
    final st = appState;
    if (st == null) {
      await _restoreItem(item);
      return;
    }
    await st.undoStack.execute(
      '还原「${item.name}」',
      () async {
        await _restoreItem(item);
        return true;
      },
      () async {
        await _unrestoreItem(st, item);
        return true;
      },
    );
  }

  /// 还原本体（raw：自身不记录撤销，由 [restore] 包裹）。
  Future<void> _restoreItem(TrashItem item) async {
    final payload =
        Map<String, dynamic>.from(jsonDecode(item.payloadJson) as Map);
    if (item.kind == 'project') {
      // 原 folder 不存在则回根。
      final meta = Map<String, dynamic>.from(payload['meta'] as Map);
      if (!await _folderExists(meta['folder'] as String? ?? '')) {
        meta['folder'] = '';
        meta['folderId'] = '';
      }
      await _restoreProject({'meta': meta, 'labels': payload['labels']});
    } else if (item.kind == 'folder') {
      final folders = ((payload['folders'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      await _restoreFolders(folders);
      final existingFolderIds = {
        for (final f in await _store.loadFolders()) f.id
      };
      for (final p in ((payload['projects'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))) {
        final meta = Map<String, dynamic>.from(p['meta'] as Map);
        if (!existingFolderIds.contains(meta['folder'])) {
          meta['folder'] = '';
          meta['folderId'] = '';
        }
        await _restoreProject({'meta': meta, 'labels': p['labels']});
      }
    }
    _items.removeWhere((e) => e.trashId == item.trashId);
    await _persist();
    notifyListeners();
    await onChanged?.call();
  }

  /// 还原的逆操作（raw）：删除还原的内容，并把 TrashItem 写回 trash.json。
  Future<void> _unrestoreItem(AppState st, TrashItem item) async {
    final payload =
        Map<String, dynamic>.from(jsonDecode(item.payloadJson) as Map);
    if (item.kind == 'project') {
      final meta = Map<String, dynamic>.from(payload['meta'] as Map);
      final cid = meta['id'] as String? ?? '';
      if (cid.isNotEmpty) await st.deleteCollection(cid);
    } else if (item.kind == 'folder') {
      // 先删工程：避免 deleteFolder 把残留工程上移到父级。
      for (final p in ((payload['projects'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))) {
        final meta = Map<String, dynamic>.from(p['meta'] as Map);
        final cid = meta['id'] as String? ?? '';
        if (cid.isNotEmpty) await st.deleteCollection(cid);
      }
      for (final f in ((payload['folders'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))) {
        final fid = f['id'] as String? ?? '';
        if (fid.isNotEmpty) await _store.deleteFolder(fid);
      }
    }
    // 把 TrashItem 写回 trash.json（幂等：已存在则跳过）。
    await load();
    if (_items.any((e) => e.trashId == item.trashId)) return;
    _items.add(item);
    _items.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    await _persist();
    notifyListeners();
    await onChanged?.call();
  }

  /// 彻底删除（可撤销）：捕获被删的 TrashItem，undo = 写回 trash.json。
  Future<void> deleteForever(String trashId) async {
    await load();
    final removed =
        _items.where((e) => e.trashId == trashId).toList();
    if (removed.isEmpty) return;
    final st = appState;
    Future<void> raw() async {
      await load();
      _items.removeWhere((e) => e.trashId == trashId);
      await _persist();
      notifyListeners();
      await onChanged?.call();
    }

    Future<void> writeBack(List<TrashItem> items) async {
      await load();
      for (final r in items) {
        if (_items.any((e) => e.trashId == r.trashId)) continue;
        _items.add(r);
      }
      _items.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
      await _persist();
      notifyListeners();
      await onChanged?.call();
    }

    if (st == null) {
      await raw();
      return;
    }
    await st.undoStack.execute(
      '彻底删除「${removed.first.name}」',
      () async {
        await raw();
        return true;
      },
      () async {
        await writeBack(removed);
        return true;
      },
    );
  }

  /// 清空回收站（可撤销）：捕获全部 TrashItem，undo = 写回。
  Future<void> emptyTrash() async {
    await load();
    if (_items.isEmpty) return;
    final removed = List<TrashItem>.of(_items);
    final st = appState;
    Future<void> raw() async {
      await load();
      _items.clear();
      await _persist();
      notifyListeners();
      await onChanged?.call();
    }

    Future<void> writeBack(List<TrashItem> items) async {
      await load();
      for (final r in items) {
        if (_items.any((e) => e.trashId == r.trashId)) continue;
        _items.add(r);
      }
      _items.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
      await _persist();
      notifyListeners();
      await onChanged?.call();
    }

    if (st == null) {
      await raw();
      return;
    }
    await st.undoStack.execute(
      '清空回收站（${removed.length} 项）',
      () async {
        await raw();
        return true;
      },
      () async {
        await writeBack(removed);
        return true;
      },
    );
  }

  // ---------- 还原的文件读写（镜像 store.dart 格式，不动 store.dart） ----------

  Future<void> _restoreProject(Map<String, dynamic> p) async {
    final meta =
        CollectionMeta.fromJson(Map<String, dynamic>.from(p['meta'] as Map));
    final labels = ((p['labels'] as List?) ?? [])
        .map((e) => MapLabel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final dir = await _store.labelsDir();
    // collection_<cid>.json（镜像 finishCollection 的文件体）。
    final body = <String, dynamic>{
      'id': meta.id,
      'name': meta.name,
      'kind': meta.kind,
      'createdAt': meta.createdAt == 0
          ? DateTime.now().millisecondsSinceEpoch
          : meta.createdAt,
      'finished': true,
      'folderId': meta.folder,
      'editMode': meta.editMode,
      'labels': labels.map((l) => l.toJson()).toList(),
    };
    await robustWriteAsString(
        File('${dir.path}/collection_${meta.id}.json'), jsonEncode(body));
    // index.json 条目：按 id 替换，保留 color/width/desc 等可选字段。
    final items = await _loadIndexItemsRaw();
    final entry = meta.toJson();
    entry['count'] = labels.length;
    final out = [
      for (final e in items)
        if (e['id'] != meta.id) e,
      entry,
    ];
    await robustWriteAsString(
        File('${dir.path}/index.json'), jsonEncode({'items': out}));
  }

  /// 还原文件夹：按原 id 写回；parentId 不存在则回根。
  Future<void> _restoreFolders(
      List<Map<String, dynamic>> folders) async {
    final dir = await _store.labelsDir();
    final f = File('${dir.path}/folders.json');
    List<Map<String, dynamic>> cur = [];
    try {
      if (f.existsSync()) {
        final d = jsonDecode(await f.readAsString());
        if (d is List) {
          cur = d
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
      }
    } catch (_) {}
    final ids = {for (final e in cur) e['id'] as String};
    // 多轮：子文件夹排在父前面时，等父写回后再挂（最多 10 轮防环）。
    var pending = folders
        .where((fo) => !ids.contains(fo['id'] as String))
        .toList();
    for (var round = 0; round < 10 && pending.isNotEmpty; round++) {
      final next = <Map<String, dynamic>>[];
      for (final fo in pending) {
        var parent = (fo['parentId'] as String?) ?? '';
        if (parent.isNotEmpty && !ids.contains(parent)) {
          // 父还没写回：下一轮再试；10 轮后仍无则回根。
          if (round < 9) {
            next.add(fo);
            continue;
          }
          parent = '';
        }
        cur.add({
          'id': fo['id'],
          'name': fo['name'],
          'parentId': parent,
        });
        ids.add(fo['id'] as String);
      }
      pending = next;
    }
    await robustWriteAsString(f, jsonEncode(cur));
  }

  /// 文件夹 id 是否存在（'' = 根，恒存在）。
  Future<bool> _folderExists(String fid) async {
    if (fid.isEmpty) return true;
    return (await _store.loadFolders()).any((f) => f.id == fid);
  }

  /// 镜像 store._loadIndexItems（读 index.json 原文条目）。
  Future<List<Map<String, dynamic>>> _loadIndexItemsRaw() async {
    try {
      final dir = await _store.labelsDir();
      final f = File('${dir.path}/index.json');
      if (!f.existsSync()) return [];
      final decoded = jsonDecode((await f.readAsString()).trim());
      if (decoded is List) {
        return decoded
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }
      final items = (decoded as Map)['items'];
      if (items is! List) return [];
      return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }
}

extension on Iterable<CollectionMeta> {
  CollectionMeta? firstOrNullSafe() {
    for (final e in this) {
      return e;
    }
    return null;
  }
}

/// 回收站页面：列表 + 还原 / 彻底删除 / 清空，显示删除时间。
class TrashPage extends StatelessWidget {
  const TrashPage(
      {super.key, required this.trash, required this.controller});

  final TrashStore trash;
  final FavTreeController controller;

  static final _fmt = DateFormat('yyyy-MM-dd HH:mm');

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: trash,
      builder: (ctx, _) => Scaffold(
        backgroundColor: TokC.panelSolid,
        appBar: AppBar(
          title: const Text('回收站'),
          actions: [
            if (trash.items.isNotEmpty)
              TextButton(
                onPressed: () => _confirmEmpty(ctx),
                child:
                    const Text('清空', style: TextStyle(color: kDanger)),
              ),
          ],
        ),
        body: trash.items.isEmpty
            ? const Center(
                child: Text('回收站是空的',
                    style: TextStyle(
                        color: kTextSub, fontSize: TokFs.body)),
              )
            : ListView.separated(
                itemCount: trash.items.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: TokC.divider),
                itemBuilder: (c2, i) {
                  final it = trash.items[i];
                  return ListTile(
                    leading: Icon(
                        it.kind == 'folder'
                            ? Icons.folder
                            : Icons.description,
                        color: it.kind == 'folder'
                            ? const Color(0xFFE6A23C)
                            : kAccent),
                    title: Text(it.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: kTextMain)),
                    subtitle: Text(
                        '${it.kind == 'folder' ? '文件夹' : '工程'}'
                        ' · ${_summary(it)}'
                        ' · ${_fmt.format(it.deletedAt)} 删除',
                        style: const TextStyle(
                            color: kTextHint, fontSize: TokFs.micro)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () => trash.restore(it.trashId),
                          child: const Text('还原',
                              style: TextStyle(color: kGreen)),
                        ),
                        TextButton(
                          onPressed: () =>
                              _confirmDeleteForever(ctx, it),
                          child: const Text('彻底删除',
                              style: TextStyle(color: kDanger)),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }

  String _summary(TrashItem it) {
    try {
      final p = Map<String, dynamic>.from(jsonDecode(it.payloadJson) as Map);
      if (it.kind == 'folder') {
        final nF = ((p['folders'] as List?) ?? []).length;
        final nP = ((p['projects'] as List?) ?? []).length;
        return '$nF 个文件夹、$nP 个工程';
      }
      final n = ((p['labels'] as List?) ?? []).length;
      return '$n 点';
    } catch (_) {
      return '';
    }
  }

  Future<void> _confirmEmpty(BuildContext context) async {
    final ok = await askConfirm(context,
        title: '清空回收站',
        content:
            '将彻底删除回收站中的 ${trash.items.length} 项，无法恢复。确定？',
        okText: '清空');
    if (ok && context.mounted) {
      await trash.emptyTrash();
      if (context.mounted) toast(context, '回收站已清空');
    }
  }

  Future<void> _confirmDeleteForever(
      BuildContext context, TrashItem it) async {
    final ok = await askConfirm(context,
        title: '彻底删除',
        content: '将彻底删除「${it.name}」，无法恢复。确定？',
        okText: '彻底删除');
    if (ok && context.mounted) {
      await trash.deleteForever(it.trashId);
      if (context.mounted) toast(context, '已彻底删除「${it.name}」');
    }
  }
}
