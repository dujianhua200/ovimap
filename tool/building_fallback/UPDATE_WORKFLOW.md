# 建筑矢量数据更新流程

## 数据来源
- 中山大学《东亚 2.8 亿建筑》数据集（Zenodo 8174931）
- AI 从高分卫星影像提取，论文报告精度约 89.6%

## 当前版本
- **v8（内置）**：733,255 栋，原精度 6 位小数，22MB
  - 打包在 `assets/buildings/xinyang.geojson.gz`
  - App 首次启动自动安装，无需下载
- **Release**：`buildings-xinyang-v4-full`（数据说明与下载地址）

## 中山大学团队发布新数据时的更新步骤

1. **下载新数据**：从 Zenodo 获取新版 `East_Asian_buildings.zip`
2. **提取信阳市**：用 HTTP range 只取 `China/Henan/Xinyang.*`
   ```bash
   # 参考 tool/building_fallback/ 中的脚本
   ```
3. **坐标转换**：UTM 49N → WGS84
4. **过滤**：去掉 <10㎡ 的明显误检
5. **差分对比**（可选，用于评估变化量）：
   ```python
   # 对比新旧两版的建筑数量、新增/删除/变化
   # 15m 网格质心匹配，输出 diff 报告
   ```
6. **打包**：
   - 全量包：`xinyang_buildings_v9.geojson.gz`（版本号递增）
   - 上传到数据分支 `data/buildings-xinyang-v1`
   - 更新 `manifest.json`（version+1，指向新文件）
   - 如文件 >20MB，jsDelivr 不可用，仅用 raw.githubusercontent.com
7. **App 内置更新**（可选，如需预装新版）：
   - 替换 `assets/buildings/xinyang.geojson.gz`
   - `kBundledBuildingVersion` +1
   - 提交发版

## 版本号规则
- v1-v7：历史版本（下载式）
- v8：首个内置版本（原精度）
- v9+：后续更新（内置或下载，由 manifest 决定）

## 注意事项
- 已公开的 Release tag 不得移动
- manifest 版本号只增不减
- App 后台自动更新机制不变：内置版本 >= manifest 版本时不下载
