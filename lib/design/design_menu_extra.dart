import '../ui/favorites/tree_menus.dart';
import 'drum_menu.dart';
import 'material_menu.dart';
import 'pole_menu.dart';

/// Phase 4 提效三件套的组合菜单扩展点：智能布杆 / 生成配盘表 / 汇总材料表。
///
/// 桌面（left_panel）与移动端（fav_mobile_actions）各自把本函数返回值
/// 拼入自己的 [FavMenuExtra] 即可；各子项的 value 均以 `extra:` 开头且
/// 全局唯一（pole-place / drumPlan / material），不会与既有菜单项冲突。
FavMenuExtra buildDesignMenuExtra() {
  final extras = <FavMenuExtra>[
    buildPoleMenuExtra(),
    buildDrumMenuExtra(),
    buildMaterialMenuExtra(),
  ];
  return FavMenuExtra(
    entries: (node) => [
      for (final e in extras) ...e.entries(node),
    ],
    onSelected: (context, c, node, value) async {
      // 各子扩展点内部按自己的 value 守卫，直调全部即可。
      for (final e in extras) {
        await e.onSelected(context, c, node, value);
      }
    },
  );
}

/// 是否为提效三件套的菜单 value（接线处用于分流）。
bool isDesignMenuValue(String value) =>
    value == 'extra:pole-place' ||
    value == 'extra:drumPlan' ||
    value == 'extra:material';
