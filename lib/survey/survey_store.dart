import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../services/app_paths.dart';
import '../services/platform_caps.dart';

/// 勘察表单照片存储：`photos/survey/<cid>/<labelId>/` 下，文件名 =
/// `<labelId>_<时间戳>.<ext>`；[SurveyForm.photos] 只存相对路径
/// `survey/<cid>/<labelId>/<文件名>`。
///
/// 与 [PhotoService]（竣工取证 photos/）同链路、同口径：删除标记不删文件
/// （撤销恢复后照片仍可用），拍照/相册复用 pubspec 已有的 image_picker；
/// 桌面无相机时降级为 file_picker 选文件。
class SurveyStore {
  /// 相对路径拼接（纯字符串，便于测试/落盘）：
  /// `survey/<cid>/<labelId>/<fileName>`。
  static String relPath(String cid, String labelId, String fileName) =>
      'survey/$cid/$labelId/$fileName';

  /// 本标记的勘察照片目录（不存在则创建）。
  static Future<Directory> dir(String cid, String labelId) async {
    final base = await AppPaths.photosDir();
    final d = Directory('${base.path}/${relPath(cid, labelId, '')}');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 相对路径 → 绝对路径（文件不存在也返回路径，由展示层处理）。
  static Future<String> absPath(String rel) async =>
      '${(await AppPaths.photosDir()).path}/$rel';

  /// 把拍摄/选择的图片拷贝进 `photos/survey/<cid>/<labelId>/`，
  /// 返回相对路径；失败返回 null。
  static Future<String?> importFile(
      String cid, String labelId, String srcPath) async {
    try {
      final src = File(srcPath);
      if (!src.existsSync()) return null;
      final ext = srcPath.contains('.')
          ? srcPath.substring(srcPath.lastIndexOf('.')).toLowerCase()
          : '.jpg';
      final name =
          '${labelId}_${DateTime.now().millisecondsSinceEpoch}$ext';
      final d = await dir(cid, labelId);
      await src.copy('${d.path}/$name');
      return relPath(cid, labelId, name);
    } catch (_) {
      return null;
    }
  }

  /// 拍照/从相册选择 → 直接导入并返回相对路径；用户取消返回 null。
  static Future<String?> pickAndImport(
      String cid, String labelId, ImageSource src) async {
    try {
      String? path;
      if (src == ImageSource.camera && !PlatformCaps.hasCamera) {
        // 桌面无相机：降级为「选择图片文件」（file_picker），同拷贝链路。
        final picked =
            await FilePicker.platform.pickFiles(type: FileType.image);
        if (picked == null || picked.files.isEmpty) return null;
        final f = picked.files.first;
        path = f.path;
        if ((path == null || path.isEmpty) && f.bytes != null) {
          final tmp = File('${Directory.systemTemp.path}/${f.name}');
          await tmp.writeAsBytes(f.bytes!, flush: true);
          path = tmp.path;
        }
      } else {
        final f = await ImagePicker()
            .pickImage(source: src, maxWidth: 2560, imageQuality: 85);
        path = f?.path;
      }
      if (path == null || path.isEmpty) return null;
      return await importFile(cid, labelId, path);
    } catch (_) {
      return null;
    }
  }

  static Future<void> deleteFile(String rel) async {
    try {
      final f = File(await absPath(rel));
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }
}
