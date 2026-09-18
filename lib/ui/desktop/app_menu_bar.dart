import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../batch_edit.dart';
import '../dialogs.dart';
import '../export_center.dart';
import '../route_tools.dart';

/// 桌面顶部菜单栏（架构文档 §3.2 / T11，高度 34）。
///
/// 用 Flutter 原生 `PopupMenuButton`（零依赖）实现下拉；菜单项直接复用既有
/// 对话框函数（如 `showSourceDialog` / `showCollectionSettings`），不重复业务逻辑。
class AppMenuBar extends StatelessWidget {
  const AppMenuBar({
    super.key,
    required this.st,
    required this.onNewProject,
    required this.onSave,
    required this.onUndo,
    required this.onRedo,
    required this.onDeleteSelection,
    required this.onExport,
    required this.onOffline,
    required this.onStorageCleanup,
    required this.onPoleTable,
    required this.onTrackCheck,
    required this.onSync,
    required this.onOpenProject,
    required this.onExportProject,
  });

  final AppState st;
  final VoidCallback onNewProject;
  final VoidCallback onSave;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onDeleteSelection;
  final VoidCallback onExport;
  final VoidCallback onOffline;
  final VoidCallback onStorageCleanup;
  final VoidCallback onPoleTable;
  final VoidCallback onTrackCheck;

  /// 打开云同步面板（T17）。
  final VoidCallback onSync;

  /// 打开工程文件 `.ovimap`（T22）。
  final VoidCallback onOpenProject;

  /// 导出工程文件 `.ovimap`（T22）。
  final VoidCallback onExportProject;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      decoration: const BoxDecoration(
        color: Color(0xFF161B20),
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text('滑洲云图',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold)),
          ),
          _menu(context, '文件', {
            'new_project': '新建工程',
            'open_project': '打开工程文件(.ovimap)  Ctrl+O',
            'save': '保存收藏  Ctrl+S',
            'export_project': '导出工程文件(.ovimap)',
            'export': '导出成果  Ctrl+E',
            'archive': '竣工资料一键成册',
            'import_kml': '导入 KML 到当前项目',
          }),
          _menu(context, '编辑', {
            'undo': '撤销  Ctrl+Z',
            'redo': '重做  Ctrl+Y',
            'delete_sel': '删除选中  Delete',
            'batch_edit': '批量编辑…',
            'clear_draft': '清空草稿',
          }),
          _menu(context, '工程', {
            'collection_settings': '采集设置（自动编号）',
            'template': '工程模板',
            'pole_table': '杆路点表',
            'track_check': '杆路轨迹核查',
            'topo_guide': '拓扑连线指引',
          }),
          _menu(context, '底图', {
            'source': '图源 / 图层',
            'coord_fmt': '坐标格式',
            'offline': '离线地图（预下载）',
            'tianditu_key': '天地图 Key 设置',
            'amap_key': '高德 Key 设置',
            'overpass': 'Overpass 端点',
            'storage_cleanup': '存储清理',
          }),
          _menu(context, '同步', {
            'sync_panel': '云同步面板（立即同步 / 设置）',
          }),
          _menu(context, '帮助', {
            'datum_help': '坐标系说明',
            'about': '关于 滑洲云图',
          }),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _menu(BuildContext context, String label, Map<String, String> items) {
    return PopupMenuButton<String>(
      tooltip: label,
      color: kPanelBg,
      position: PopupMenuPosition.under,
      onSelected: (v) => _onSelected(context, v),
      itemBuilder: (ctx) => [
        for (final e in items.entries)
          PopupMenuItem<String>(
            value: e.key,
            child: Text(e.value,
                style: const TextStyle(color: kTextMain, fontSize: 13)),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(label,
            style: const TextStyle(color: kTextMain, fontSize: 12.5)),
      ),
    );
  }

  Future<void> _onSelected(BuildContext context, String v) async {
    switch (v) {
      case 'new_project':
        onNewProject();
        break;
      case 'open_project':
        onOpenProject();
        break;
      case 'export_project':
        onExportProject();
        break;
      case 'save':
        onSave();
        break;
      case 'export':
        onExport();
        break;
      case 'archive':
        await showArchiveBookDialog(context, st);
        break;
      case 'import_kml':
        await showKmlImportDialog(context, st);
        break;
      case 'undo':
        onUndo();
        break;
      case 'redo':
        onRedo();
        break;
      case 'delete_sel':
        onDeleteSelection();
        break;
      case 'batch_edit':
        if (st.selectedIds.isEmpty) {
          toast(context, '请先框选或在线组里选中点');
        } else {
          await showBatchEditDialog(context, st);
        }
        break;
      case 'clear_draft':
        await _confirmClear(context);
        break;
      case 'collection_settings':
        await showCollectionSettings(context, st);
        break;
      case 'template':
        await showTemplateDialog(context, st);
        break;
      case 'pole_table':
        onPoleTable();
        break;
      case 'track_check':
        onTrackCheck();
        break;
      case 'topo_guide':
        await showTopoGuide(context);
        break;
      case 'source':
        await showSourceDialog(context, st);
        break;
      case 'coord_fmt':
        st.setCoordFmt(st.coordFmt + 1);
        if (context.mounted) {
          toast(context, '坐标格式已切换（下次重开沿用）');
        }
        break;
      case 'offline':
        onOffline();
        break;
      case 'tianditu_key':
        await showTiandituKeyDialog(context, st);
        break;
      case 'amap_key':
        await showAmapKeyDialog(context, st);
        break;
      case 'overpass':
        await showOverpassEndpointsDialog(context, st);
        break;
      case 'storage_cleanup':
        onStorageCleanup();
        break;
      case 'sync_panel':
        onSync();
        break;
      case 'datum_help':
        await showDatumHelp(context, st);
        break;
      case 'about':
        await showAbout(context);
        break;
    }
  }

  Future<void> _confirmClear(BuildContext context) async {
    if (st.labels.isEmpty) {
      toast(context, '草稿为空');
      return;
    }
    await showDarkDialog(context,
        title: '清空草稿',
        content: Text('确定删除当前 ${st.labels.length} 个未保存的点？',
            style: const TextStyle(color: kTextMain, fontSize: 13)),
        actions: [
          darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
          darkTextBtn('清空', () {
            st.clearDraft();
            Navigator.pop(context);
          }, color: const Color(0xFFFF5252)),
        ]);
  }
}
