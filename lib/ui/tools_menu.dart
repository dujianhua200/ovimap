import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../export/asbuilt_reports.dart';
import 'dialogs.dart';
import 'export_center.dart';
import 'new_project_dialog.dart';
import 'route_tools.dart';
import 'topo_editor.dart';
import 'workflow_guide.dart';

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
  // 出图体检与「重试失败瓦片」需要地图相机 / 瓦片 provider，由移动端壳注入。
  // 不传时对应入口不显示，避免点了没反应。
  Future<void> Function()? onInspect,
  VoidCallback? onRetryTiles,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: kPanelBg,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          // 移动端此前没有"新建工程"入口，只能清空草稿后直接画；
          // 统一走与桌面同一个引导（名称/模板/编号一次设完）。
          sheetGroupTitle('工程'),
          // 与桌面「作业流程」同一套引导：移动端也有入口，不再只能靠记忆找菜单。
          sheetTile(context, '作业流程（新建→打点→布杆→体检→导出）', () {
            showWorkflowGuide(
              context,
              st,
              onNewProject: () => showNewProjectDialog(context, st),
              onInspect: () {
                if (onInspect != null) {
                  onInspect();
                } else {
                  toast(context, '当前端不支持出图体检');
                }
              },
              onExport: () => openExportCenter(context, st),
            );
          }),
          sheetTile(context, '新建工程（名称 / 模板 / 编号）',
              () => showNewProjectDialog(context, st)),
          sheetGroupTitle('成果与资料'),
          if (onInspect != null)
            sheetTile(context, '出图体检（出图前查错）', () => onInspect()),
          sheetTile(context, '导出成果（当前草稿 / 配线）',
              () => openExportCenter(context, st)),
          sheetTile(context, '导入对象文件（KML/KMZ/奥维）',
              () => showImportDialog(context, st)),
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
          if (onRetryTiles != null) ...[
            sheetGroupTitle('地图'),
            sheetTile(context, '重试失败瓦片（白块 / 加载失败）', onRetryTiles),
          ],
          sheetGroupTitle('专业工具'),
          // P1-2：人工拓扑提到专业工具组顶部，并改名与 ODN 拓扑连线区分。
          sheetTile(context, '人工光缆拓扑（逐条连线）', () {
            final devices = topoLinkableDevices(st.labels);
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => TopoEditorPage(
                devices: devices,
                initialLinks: st.fiberLinks,
                onChanged: (links) => st.updateFiberLinks(links),
                routeLabels: st.labels,
                onRouteChanged: () => st.persistLabels(),
              ),
            ));
          }),
          sheetTile(context, '采集设置（杆路自动编号）',
              () => showCollectionSettings(context, st)),
          sheetTile(context, '工程模板（架空/管道/箱体配线）',
              () => showTemplateDialog(context, st)),
          sheetTile(context, '杆路轨迹核查（查漏杆/错位）', onTrackCheck),
          sheetTile(context, '拓扑连线指引', () => showTopoGuide(context)),
          sheetTile(context, 'ODN 拓扑连线（地图点选）', onOdnTopo),
        ],
      ),
    ),
  );
}
