# DocScan

轻量级 Android 文档扫描应用 — Flutter 构建，100% 离线。

**管线**：拍照/相册 → 选页（删单页 / 调顺序）→ 点「下一步」才做透视校正 + 增强（彩色/灰度/黑白）→ 多页 A4 PDF。

- **实时取景框**：拍摄界面上叠加检测到的文档四边形，边拍边确认
- **单页/多页模式**：多页模式显示页数、连续拍摄
- **选中的页先放着**：从相册多选后只在列表里排队显示原图，废页可以直接删掉，不浪费一次处理
- **单页删除 / 换位**：长按任一页缩略图，出现 ◀ ▶ × 三个操作，导出页同样可用
- **手动裁剪**：自动检测不准时，四角拖拽框住文档重扫；未检出边缘的页在导出页有红色标记
- **文档库**：自动命名（日期+序号）、重命名、批量改名、分享/打印
- **纯离线**：无网络权限需求级的数据外传，扫描在设备端完成
- **轻快**：无 WebView / JS 引擎 / 嵌入式服务器，冷启动快

## 构建

APK 由 GitHub Actions 自动构建（本仓库无本地构建要求）：

1. Push 到 `main` 或打 `v*` 标签
2. Actions 页下载 `docscan-apk` artifact（标签推送会自动创建 Release）

本地构建（可选）：`flutter build apk --release`

## 测试

```bash
flutter test   # 扫描管线单元测试（检测/增强/A4/JPEG 往返）
```

## 结构

```
lib/
├── design/tokens.dart      # 设计系统：液态玻璃 tokens + Glass 组件
├── scan/pipeline.dart      # 扫描算法（web 项目 detect/warp/enhance 的 Dart 移植）
├── state/
│   ├── scan_state.dart     # 会话/文档库状态（Riverpod）+ 文件系统持久化
│   └── pdf_builder.dart    # 多页 A4 PDF（pdf 包，JPEG 嵌入）
└── pages/
    ├── home_page.dart      # 扫描入口：模式切换 + 会话缩略图
    ├── camera_page.dart    # 取景器 + 实时边缘检测 + 单/多页
    ├── adjust_page.dart    # 手动四角裁剪
    ├── result_page.dart    # 导出：命名 + 保存 + 分享
    └── docs_page.dart      # 文档库：重命名/批量/打印/删除
```

## 设计

液态玻璃（Liquid Glass）：相机取景是深色真实世界（Ink），一切浮在内容上的控件
是磨砂玻璃（Frost @72% + blur）；扫描结果躺在纸面（Paper）上；唯一的强调色
Clover 绿标记「扫描仪的决定」——检测框、进度、主按钮。动效语法：快响应、
缓落定（140ms 交互 / 420ms 转场），扫描时一道光带扫过缩略图。

算法参数与 `document-scan-mcp`（Web 版）共享同一套调优结果。
