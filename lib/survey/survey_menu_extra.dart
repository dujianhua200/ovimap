import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../ui/design_tokens.dart';
import '../ui/favorites/tree_menus.dart';
import 'survey_page.dart';

/// 标记右键/长按菜单值。
const String kSurveyMenuValue = 'extra:survey';

bool isSurveyMenuValue(String value) => value == kSurveyMenuValue;

/// 勘察表单菜单扩展点（仅暴露，不接线——接线由协调者统一做）。
///
/// 用法：把 [buildSurveyMenuExtra] 的返回值拼入
/// `showFavNodeMenu(..., extra: ...)`（桌面 left_panel / 移动端
/// fav_mobile_actions 均可；tree_menus 的共享菜单本身不动）。
/// 对 `isMark` 的节点追加菜单项「勘察表单」，选中后打开表单页，
/// 保存走 AppState 现有 `updateLabel` / `updateOverlayLabel` 路径。
FavMenuExtra buildSurveyMenuExtra() => FavMenuExtra(
      entries: (node) {
        if (!node.isMark || node.label == null) {
          return const <PopupMenuEntry<String>>[];
        }
        return const <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: kSurveyMenuValue,
            height: 34,
            child: Text('勘察表单',
                style:
                    TextStyle(color: TokC.textMain, fontSize: TokFs.body)),
          ),
        ];
      },
      onSelected: (context, c, node, value) async {
        if (value != kSurveyMenuValue ||
            !node.isMark ||
            node.label == null) {
          return;
        }
        final st = Provider.of<AppState>(context, listen: false);
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SurveyPage(
              st: st,
              label: node.label!,
              cid: node.labelCid ?? '',
            ),
          ),
        );
      },
    );
