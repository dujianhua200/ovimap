import 'package:flutter/material.dart';

import '../models/fiber_link.dart';
import '../models/map_label.dart';
import '../state/app_state.dart';
import '../export/asbuilt_reports.dart';
import 'dialogs.dart';
import 'export_center.dart';
import 'route_tools.dart';
import 'topo_editor.dart';

/// ⋯工具 面板：低频业务，分「成果与资料 / 专业工具」两组。
///
/// 杆路点表、杆路轨迹核查的实现在 `home_page`（其私有装配），
/// 通过回调注入，避免把大段 UI 逻辑外提。
Future<void> showToolsMenu(
  BuildContext context,
  AppState st, {
  required Future<void> Function() onPoleTable,
  required Future<void> Function() onTrackCheck,
  required VoidCallback onOdnTopo,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: kPanelBg,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          sheetGroupTitle('成果与资料'),
          sheetTile(context, '导出成果（当前草稿 / 配线）',
              () => openExportCenter(context, st)),
          sheetTile(context, '导入 KML 到当前项目',
              () => showKmlImportDialog(context, st)),
          sheetTile(context, '杆路点表（定位/属性/查长度）', onPoleTable),
          sheetTile(context, '竣工资料一键成册（ZIP 交结算）',
              () => showArchiveBookDialog(context, st)),
          sheetTile(context, '竣工报表（纤芯台账/设备/工程量/材料）', () async {
            final name = st.projectName.isEmpty ? '当前草稿' : st.projectName;
            final files = await AsbuiltReports.exportAll(
                name, st.labels, st.labels, st.fiberLinks);
            if (context.mounted) {
              toast(context, '已导出 ${files.length} 张表');
              // 分享第一张，其他在导出目录
              shareFile(context, files.first);
            }
          }),
          sheetGroupTitle('专业工具'),
          sheetTile(context, '采集设置（杆路自动编号）',
              () => showCollectionSettings(context, st)),
          sheetTile(context, '工程模板（架空/管道/箱体配线）',
              () => showTemplateDialog(context, st)),
          sheetTile(context, '杆路轨迹核查（查漏杆/错位）', onTrackCheck),
          sheetTile(context, '拓扑连线指引', () => showTopoGuide(context)),
          sheetTile(context, 'ODN 拓扑图', onOdnTopo),
          sheetTile(context, '光缆拓扑编辑器（人工）', () {
            final devices = topoLinkableDevices(st.labels);
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => TopoEditorPage(
                devices: devices,
                initialLinks: st.fiberLinks,
                onChanged: (links) => st.updateFiberLinks(links),
              ),
            ));
          }),
        ],
      ),
    ),
  );
}
