/// 改造三态：原有 / 新增 / 拆除。
///
/// 用于杆路段（MapLabel.reno：本点入段，即上一杆→本杆）和
/// 人工光缆拓扑连线（FiberLink.reno）。
/// 0=原有（默认），1=新增，2=拆除。
abstract class RenoState {
  static const int existing = 0;
  static const int added = 1;
  static const int removed = 2;

  static String label(int v) {
    switch (v) {
      case added:
        return '新增';
      case removed:
        return '拆除';
      default:
        return '原有';
    }
  }

  static bool valid(int v) => v == existing || v == added || v == removed;
}
