/// 工程向导：按模板一键生成收藏夹目录结构（Phase 5）。
///
/// 与 [ProjectTemplate]（`models/project_template.dart`）的区别：
/// 那个模板只提供"新建工程时的默认值"（符号/敷设方式等）；这里的
/// [WizardTemplate] 是**目录结构模板**——一次生成整棵"文件夹 + 空工程"
/// 树。两者正交，不冲突。
///
/// 结构定义为数据（[WizardTemplate]：items[] 含 parent 引用），不要
/// hardcode 在 UI 里；UI（`project_wizard_page.dart`）只做选择/预览/编辑。
library;

import 'dart:convert';
import 'dart:io';

import '../services/store.dart';
import '../state/fav_tree_controller.dart';

// 为避免与 models/project_template.dart 的 ProjectTemplate 混淆，本文件
// 不复用那个类名；向导模板统一叫 WizardTemplate。

/// 模板条目类型。
class WizardItemKind {
  WizardItemKind._();
  static const folder = 'folder';
  static const project = 'project';
}

/// 模板中的一个条目：文件夹或（空）工程。
///
/// [parentId] 为模板内条目的 id（'' = 模板根）；必须指向同模板内的
/// 一个 folder 条目（校验见 [validateWizardTemplate]）。
class WizardItem {
  final String id;
  final String kind;
  final String name;
  final String parentId;

  /// 工程的 collection kind（'label' 等），默认 'label'。
  final String projectKind;

  const WizardItem({
    required this.id,
    required this.kind,
    required this.name,
    this.parentId = '',
    this.projectKind = 'label',
  });

  const WizardItem.folder(String id, String name, [String parentId = ''])
      : this(id: id, kind: WizardItemKind.folder, name: name, parentId: parentId);

  const WizardItem.project(String id, String name, String parentId,
      {String projectKind = 'label'})
      : this(
            id: id,
            kind: WizardItemKind.project,
            name: name,
            parentId: parentId,
            projectKind: projectKind);

  bool get isFolder => kind == WizardItemKind.folder;
  bool get isProject => kind == WizardItemKind.project;

  WizardItem copyWith({String? name, String? parentId, String? projectKind}) =>
      WizardItem(
        id: id,
        kind: kind,
        name: name ?? this.name,
        parentId: parentId ?? this.parentId,
        projectKind: projectKind ?? this.projectKind,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'name': name,
        'parentId': parentId,
        if (projectKind != 'label') 'projectKind': projectKind,
      };

  factory WizardItem.fromJson(Map<String, dynamic> m) => WizardItem(
        id: (m['id'] as String?) ?? '',
        kind: (m['kind'] as String?) ?? WizardItemKind.folder,
        name: (m['name'] as String?) ?? '',
        parentId: (m['parentId'] as String?) ?? '',
        projectKind: (m['projectKind'] as String?) ?? 'label',
      );
}

/// 目录结构模板：文件夹 + 工程的集合，parent 引用模板内条目 id。
class WizardTemplate {
  final String id;
  final String name;
  final List<WizardItem> items;

  /// true = 内置预设（只读，UI 不提供编辑/删除；见 [presets]）。
  final bool builtIn;

  const WizardTemplate({
    required this.id,
    required this.name,
    this.items = const [],
    this.builtIn = false,
  });

  WizardTemplate copyWith({String? name, List<WizardItem>? items}) =>
      WizardTemplate(
        id: id,
        name: name ?? this.name,
        items: items ?? this.items,
        builtIn: builtIn,
      );

  /// 生成唯一 id（模板 / 条目共用口径）。
  static String newId(String prefix) =>
      '${prefix}_${DateTime.now().microsecondsSinceEpoch}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'items': [for (final i in items) i.toJson()],
      };

  factory WizardTemplate.fromJson(Map<String, dynamic> m) => WizardTemplate(
        id: (m['id'] as String?) ?? '',
        name: (m['name'] as String?) ?? '',
        items: [
          for (final e in (m['items'] as List? ?? []))
            WizardItem.fromJson(Map<String, dynamic>.from(e as Map)),
        ],
      );

  // ---------- 内置预设（只读） ----------

  /// 预设 1：通信线路工程。
  /// 设计/（杆路、光缆、设备）、勘察/（现场标记）、竣工/（竣工杆路、竣工光缆）。
  static WizardTemplate get lineProject {
    const d = 'p_line_d';
    const s = 'p_line_s';
    const c = 'p_line_c';
    return const WizardTemplate(
      id: 'preset_line',
      name: '通信线路工程',
      builtIn: true,
      items: [
        WizardItem.folder('f_line_design', '设计'),
        WizardItem.folder('f_line_survey', '勘察'),
        WizardItem.folder('f_line_complete', '竣工'),
        WizardItem.project('p_line_pole', '杆路', 'f_line_design'),
        WizardItem.project(d, '光缆', 'f_line_design'),
        WizardItem.project('p_line_dev', '设备', 'f_line_design'),
        WizardItem.project(s, '现场标记', 'f_line_survey'),
        WizardItem.project('p_line_cp', '竣工杆路', 'f_line_complete'),
        WizardItem.project(c, '竣工光缆', 'f_line_complete'),
      ],
    );
  }

  /// 预设 2：小区 FTTH 工程。
  static WizardTemplate get ftthProject {
    return const WizardTemplate(
      id: 'preset_ftth',
      name: '小区 FTTH 工程',
      builtIn: true,
      items: [
        WizardItem.folder('f_ftth_design', '设计'),
        WizardItem.folder('f_ftth_survey', '勘察'),
        WizardItem.folder('f_ftth_complete', '竣工'),
        WizardItem.project('p_ftth_cov', '覆盖设计', 'f_ftth_design'),
        WizardItem.project('p_ftth_dist', '配线光缆', 'f_ftth_design'),
        WizardItem.project('p_ftth_drop', '入户光缆', 'f_ftth_design'),
        WizardItem.project('p_ftth_mark', '现场标记', 'f_ftth_survey'),
        WizardItem.project('p_ftth_cdist', '竣工配线', 'f_ftth_complete'),
        WizardItem.project('p_ftth_cdrop', '竣工入户', 'f_ftth_complete'),
      ],
    );
  }

  /// 预设 3：管线普查工程。
  static WizardTemplate get ductSurveyProject {
    return const WizardTemplate(
      id: 'preset_duct',
      name: '管线普查工程',
      builtIn: true,
      items: [
        WizardItem.folder('f_duct_work', '普查'),
        WizardItem.folder('f_duct_check', '核查'),
        WizardItem.folder('f_duct_result', '成果'),
        WizardItem.project('p_duct_route', '管道路由', 'f_duct_work'),
        WizardItem.project('p_duct_mh', '人手井', 'f_duct_work'),
        WizardItem.project('p_duct_issue', '问题标记', 'f_duct_check'),
        WizardItem.project('p_duct_final', '普查成果', 'f_duct_result'),
      ],
    );
  }

  /// 全部内置预设（顺序即 UI 展示顺序）。
  static List<WizardTemplate> get presets =>
      [lineProject, ftthProject, ductSurveyProject];
}

/// 校验模板。返回错误列表（空 = 合法）——UI 与持久层共用。
///
/// 规则：模板名非空；条目名非空；条目 id 唯一；parentId 为 ''
/// 或指向同模板内某个 folder；文件夹父链无环。
List<String> validateWizardTemplate(WizardTemplate t) {
  final errs = <String>[];
  if (t.name.trim().isEmpty) errs.add('模板名不能为空');
  final ids = <String>{};
  for (final it in t.items) {
    if (!ids.add(it.id)) errs.add('条目 id 重复：${it.id}');
    if (it.name.trim().isEmpty) {
      errs.add('存在未命名的${it.isFolder ? '文件夹' : '工程'}');
    }
    if (!it.isFolder && !it.isProject) errs.add('未知条目类型：${it.kind}');
  }
  final byId = {for (final it in t.items) it.id: it};
  for (final it in t.items) {
    if (it.parentId.isEmpty) continue;
    final p = byId[it.parentId];
    if (p == null) {
      errs.add('「${it.name}」的父级不存在');
    } else if (!p.isFolder) {
      errs.add('「${it.name}」的父级不是文件夹');
    }
  }
  for (final it in t.items.where((e) => e.isFolder)) {
    final seen = <String>{it.id};
    var p = it.parentId;
    while (p.isNotEmpty) {
      if (!seen.add(p)) {
        errs.add('文件夹「${it.name}」存在循环引用');
        break;
      }
      p = byId[p]?.parentId ?? '';
    }
  }
  return errs;
}

/// 生成计划中的一步。
class WizardPlanStep {
  final WizardItem item;

  /// 在预览中的缩进深度（模板根为 0）。
  final int depth;

  const WizardPlanStep(this.item, this.depth);
}

/// 生成计划：文件夹按"父先子后"拓扑排序，工程随后。
///
/// 纯函数（可单测）；要求模板已通过 [validateWizardTemplate]
/// （非法 parent 兜底按模板根处理，不抛错）。
WizardPlan buildWizardPlan(WizardTemplate t) {
  final folders = t.items.where((e) => e.isFolder).toList();
  final byId = {for (final it in t.items) it.id: it};
  final ordered = <WizardItem>[];
  final depth = <String, int>{};

  void visit(WizardItem f, int d) {
    if (depth.containsKey(f.id)) return;
    depth[f.id] = d;
    ordered.add(f);
    for (final c in folders.where((e) => e.parentId == f.id)) {
      visit(c, d + 1);
    }
  }

  for (final f in folders) {
    final p = byId[f.parentId];
    if (f.parentId.isEmpty || p == null || !p.isFolder) visit(f, 0);
  }
  // 兜底：上面没走到的孤儿（验证通过时不会发生）。
  for (final f in folders) {
    if (!depth.containsKey(f.id)) visit(f, 0);
  }

  final projects = t.items.where((e) => e.isProject).toList();
  int projDepth(WizardItem p) =>
      p.parentId.isEmpty ? 0 : (depth[p.parentId] ?? 0) + 1;

  return WizardPlan(
    folderSteps: [for (final f in ordered) WizardPlanStep(f, depth[f.id]!)],
    projectSteps: [for (final p in projects) WizardPlanStep(p, projDepth(p))],
  );
}

/// 生成计划。
class WizardPlan {
  final List<WizardPlanStep> folderSteps;
  final List<WizardPlanStep> projectSteps;

  const WizardPlan({required this.folderSteps, required this.projectSteps});

  int get folderCount => folderSteps.length;
  int get projectCount => projectSteps.length;
  int get totalCount => folderSteps.length + projectSteps.length;
  bool get isEmpty => totalCount == 0;
}

// ---------- 自定义模板持久化 ----------

/// 自定义模板的本地持久化。
///
/// 落盘位置：`<labelsDir>/wizard_templates.json`（**纯新增文件**）。
///
/// 选文件而不用 prefs 的原因：
/// 1. 模板是嵌套结构（文件夹/工程/parent 引用），JSON 文件表达更直接，
///    不用把结构拍扁塞进字符串 prefs；
/// 2. 落在权威数据根目录 labels/ 下（与 folders.json、index.json、
///    trash.json 同目录），Windows/Android 目录结构同构，随整目录拷贝
///    即跨端同步；
/// 3. 磁盘格式零改动：只新增这一个文件，不动任何现有文件。
class WizardTemplateStore {
  WizardTemplateStore._(this._store, this._templates);

  final LabelStore _store;
  final List<WizardTemplate> _templates; // 仅自定义模板；预设不落盘

  static Future<File> _file(LabelStore store) async =>
      File('${(await store.labelsDir()).path}/wizard_templates.json');

  /// 加载自定义模板。文件不存在/损坏 → 返回空 store（不抛错）。
  static Future<WizardTemplateStore> load(LabelStore store) async {
    try {
      final f = await _file(store);
      if (!f.existsSync()) return WizardTemplateStore._(store, []);
      final decoded = jsonDecode(await f.readAsString());
      final List list = decoded is List
          ? decoded
          : ((decoded as Map)['templates'] as List? ?? []);
      final ts = <WizardTemplate>[];
      for (final e in list) {
        try {
          final t = WizardTemplate.fromJson(
              Map<String, dynamic>.from(e as Map));
          // 脏条目（空名/无 id/校验不过）直接跳过，保证文件坏了也不炸。
          if (t.id.isNotEmpty && validateWizardTemplate(t).isEmpty) {
            ts.add(t);
          }
        } catch (_) {}
      }
      return WizardTemplateStore._(store, ts);
    } catch (_) {
      return WizardTemplateStore._(store, []);
    }
  }

  /// 自定义模板（只读拷贝）。
  List<WizardTemplate> get customTemplates =>
      List<WizardTemplate>.unmodifiable(_templates);

  /// UI 直接用的全量列表：预设 + 自定义。
  List<WizardTemplate> allTemplates() => [
        ...WizardTemplate.presets,
        ..._templates,
      ];

  /// 新增或更新一条自定义模板。校验不过/试图改预设 → 抛 ArgumentError。
  Future<void> saveTemplate(WizardTemplate t) async {
    if (t.builtIn) {
      throw ArgumentError('预设模板不可修改，请先复制为自定义模板');
    }
    if (t.id.isEmpty) throw ArgumentError('模板 id 不能为空');
    final errs = validateWizardTemplate(t);
    if (errs.isNotEmpty) throw ArgumentError(errs.join('；'));
    final i = _templates.indexWhere((e) => e.id == t.id);
    if (i >= 0) {
      _templates[i] = t;
    } else {
      _templates.add(t);
    }
    await _persist();
  }

  /// 删除一条自定义模板（id 不存在时静默成功）。
  Future<void> deleteTemplate(String id) async {
    _templates.removeWhere((e) => e.id == id);
    await _persist();
  }

  Future<void> _persist() async {
    final f = await _file(_store);
    await robustWriteAsString(
        f,
        jsonEncode({
          'version': 1,
          'templates': [for (final t in _templates) t.toJson()],
        }));
  }
}

// ---------- 应用模板：生成目录结构 ----------

/// 应用模板的生成结果。
class WizardApplyResult {
  final bool ok;
  final List<String> folderIds;
  final List<String> projectIds;

  const WizardApplyResult({
    required this.ok,
    this.folderIds = const [],
    this.projectIds = const [],
  });
}

/// 按模板生成目录结构。
///
/// - 文件夹走 [FavTreeController.addFolderUndoable]（正规创建接口）；
/// - 空工程走 `store.finishCollection(labels: [], clearDraftNow: false)`
///   （不碰草稿，只建收藏条目——controller 没有"建空工程"接口，
///   这是 store 层正规的工程创建入口）；
/// - 整个生成包成**一条** UndoStack 命令（外层 execute 期间内部重入的
///   execute 只执行本体不再记录——UndoStack 的 suspend 机制），
///   undo = 删掉本次创建的工程与文件夹；redo = 重新生成；
/// - 生成位置 [parentId]：调用方传 `controller.treeSelectedFolderId`
///  （'' = 根目录），与"新建文件夹"的口径一致。
Future<WizardApplyResult> applyTemplate(
  FavTreeController controller,
  WizardTemplate template, {
  String parentId = '',
}) async {
  final errs = validateWizardTemplate(template);
  if (errs.isNotEmpty) throw ArgumentError(errs.join('；'));
  final plan = buildWizardPlan(template);
  if (plan.isEmpty) throw ArgumentError('模板是空的，请先添加文件夹或工程');

  final store = controller.store;
  final st = controller.appState;
  final itemToFolderId = <String, String>{};
  final createdFolderIds = <String>[];
  final createdProjectIds = <String>[];

  String resolveParent(String itemParentId) => itemParentId.isEmpty
      ? parentId
      : itemToFolderId[itemParentId] ?? parentId;

  Future<bool> doIt() async {
    for (final step in plan.folderSteps) {
      final id = await controller.addFolderUndoable(
          step.item.name, resolveParent(step.item.parentId));
      if (id == null) return false;
      itemToFolderId[step.item.id] = id;
      createdFolderIds.add(id);
    }
    for (final step in plan.projectSteps) {
      final cid = await store.finishCollection(
        name: step.item.name,
        kind: step.item.projectKind,
        folderId: resolveParent(step.item.parentId),
        editMode: 'design',
        labels: const [],
        clearDraftNow: false,
      );
      createdProjectIds.add(cid);
    }
    await st.refreshCollections();
    return true;
  }

  Future<bool> undoIt() async {
    // 先删工程，再删文件夹（逆序：子文件夹先于父文件夹；
    // deleteFolder 会级联子树，逐个删保证只动本次创建的节点）。
    for (final cid in createdProjectIds.reversed) {
      try {
        await store.deleteCollection(cid);
      } catch (_) {}
    }
    for (final fid in createdFolderIds.reversed) {
      try {
        await store.deleteFolder(fid);
      } catch (_) {}
    }
    itemToFolderId.clear();
    createdFolderIds.clear();
    createdProjectIds.clear();
    await st.refreshCollections();
    return true;
  }

  final ok = await st.undoStack
      .execute('从模板「${template.name}」新建', doIt, undoIt);
  return WizardApplyResult(
    ok: ok,
    folderIds: List<String>.unmodifiable(createdFolderIds),
    projectIds: List<String>.unmodifiable(createdProjectIds),
  );
}
