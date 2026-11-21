# Inkboard（原型）

轻量的 macOS 手写白板：纯 AppKit + Core Graphics，没有第三方依赖。

## 运行

```bash
scripts/build.sh            # 编译并打包 build/Inkboard.app
open build/Inkboard.app
scripts/build.sh check      # 编译 + 跑核心逻辑自检，并输出 build/sample.png
```

开发时也可以直接 `swift run Inkboard`（不打包 .app），自检可以用 `swift run InkboardCheck`。

## 功能

| 工具 | 快捷键 | 说明 |
|---|---|---|
| 钢笔 | P | 黑色，支持压感，三档笔宽 |
| 橡皮擦 | E | 按笔迹局部擦除，会把笔画切成两段；数位笔翻过来用橡皮头时自动切换 |
| 套索选择 | L | 圈选（笔画有一半以上在圈内就算选中），点一下选中单条笔画；拖动框内可移动，⌫ 删除，Esc 取消 |
| 插入空间 | S | 在某一高度按下后向下拖，会把这条线以下的内容整体下移；往上拖则删除空白（不会越过这条线） |

- 撤销 / 重做：⌘Z / ⇧⌘Z
- 缩放：触控板双指捏合，或 ⌘= / ⌘- / ⌘0
- 平移：双指滚动，或按住空格拖动
- 画布向右、向下自动扩展
- 文件 → 导出 PNG（有选区时只导出选区）

### 文件

每个手绘文件是一个 `.inkboard` 文件，一个文件一个窗口。基于 macOS 原生的文稿机制（NSDocument）：

| 操作 | 快捷键 |
|---|---|
| 新建 | ⌘N |
| 打开… | ⌘O |
| 存储… | ⌘S（第一次存储时选择位置和文件名） |
| 复制 / 存储为… | ⇧⌘S / ⌥⇧⌘S |
| 关闭 | ⌘W |

- **自动存储**：已存储过的文件，修改后会自动写回原文件；未命名的文件由系统暂存，下次启动时恢复。
- 文件菜单里还有「打开最近使用」「重新命名…」「移到…」「复原到 → 上次存储的版本 / 浏览所有版本…」；点窗口标题也可以重命名或移动文件。
- 关闭有未存储内容的未命名文件时，会询问是否存储。
- 运行过一次 `scripts/build.sh` 之后，在访达里双击 `.inkboard` 文件就会用 Inkboard 打开。
- 文件格式是 JSON（`{"version":1,"strokes":[{"id","width","points":[x,y,压力,…]}]}`），读写代码在 `InkboardCore/BoardStore.swift`。损坏或格式不对的文件会提示无法打开。

**从旧版本迁移**：加入文件功能之前，应用只有一块画板，保存在 `~/Library/Application Support/Inkboard/board.json`。升级后第一次启动时，这块画板会作为一个未命名文件打开，按 ⌘S 存到想要的位置即可。旧文件会改名为 `board.imported.json` 保留下来，不会删除。

### 压感

- 数位板（Wacom 等）、随航（Sidecar）上的 Apple Pencil：直接读取 `NSEvent.pressure`
- Force Touch 触控板：按下拖动时读取按压力度
- 普通鼠标：固定中等粗细

笔迹处理：先用向心 Catmull-Rom 样条平滑，再按约 1 屏幕像素的间距重新采样。每个采样点按压力换算成半径，笔画由圆和相邻圆之间的外切梯形拼成，最后一次性填充，所以急转弯处也不会出现破洞。

## AI 转写接口（已预留）

`Sources/InkboardCore/Transcription.swift`：

```swift
public protocol HandwritingTranscriber {
    func transcribeToMarkdown(_ request: TranscriptionRequest) async throws -> String
}
```

`TranscriptionRequest` 里带着白底黑字的 `pngData`，以及原始笔画（坐标和压力）。接入方法：实现这个协议（比如把 PNG 发给视觉模型），然后在 `AppDelegate.swift` 里把 `UnconfiguredTranscriber()` 换成你的实现。工具栏的 ✨ 按钮和「文件 → 转写为 Markdown」已经接好：转写当前选区，没有选区时转写整个画布，结果保存为 `.md`。

## 代码结构

```
Sources/InkboardCore/     纯逻辑，不依赖 AppKit
  Stroke.swift            笔画模型
  StrokeSmoother.swift    增量样条平滑与重采样
  StrokeGeometry.swift    压感 → 轮廓路径
  InkOps.swift            擦除、套索、平移、插入空间
  InkRenderer.swift       渲染与导出 PNG
  BoardStore.swift        JSON 存储
  Transcription.swift     AI 转写接口
Sources/Inkboard/         macOS 应用
  BoardDocument.swift     .inkboard 文稿：读写、自动存储、复原
  CanvasView.swift        画布：输入、手势、绘制、撤销
  MainWindowController.swift  文稿窗口、工具栏、导出
  AppDelegate.swift       启动；旧版画板迁移
  MainMenu.swift / Tool.swift / main.swift
Sources/InkboardCheck/    自检程序（Command Line Tools 不带 XCTest，用它代替单元测试）
Support/Info.plist        应用信息、.inkboard 文件类型声明（打包时复制进 .app；swift run 时嵌入可执行文件）
```
