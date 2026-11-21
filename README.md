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
- 显示 → 显示点格：开关点格背景（所有窗口共用，会记住）。导出的 PNG 和发给 AI 的图片始终是纯白底，不带点格
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

## AI 转换

通过 [ACP（Agent Client Protocol）](https://agentclientprotocol.com) 调用本机的 AI agent，默认是 Antigravity 的 `agy acp`（需要先在终端用 `agy` 登录）。

| 功能 | 入口 | 说明 |
|---|---|---|
| 局部转换 | 工具栏「局部转换」，或「转换」菜单 ⇧⌘L | 在画布上拖出一个方框框住公式，松开后自动识别，LaTeX 代码复制到剪贴板。可以接着框下一个；Esc 或切换工具退出 |
| 全局转换 | 工具栏「全局转换」，或「转换」菜单 ⇧⌘M | 把整个画板切成若干页图片发给 AI，整理成 Markdown，存为与 `.inkboard` 同一文件夹下的同名 `.md`。未存储的文稿会先要求存储；同名文件已存在时询问是否替换 |

切页规则：按行把笔迹分组，从上往下装进接近 A4 比例的页面，切线落在两行之间，不会把一行字切开；大片空白会跳过。

**设置**（Inkboard → 设置…，⌘,）：

- agent 命令和参数。默认 `agy` + `acp`；也可以换成其他支持 ACP 的 agent，例如 `gemini` + `--experimental-acp`。命令可以写名字（会在 `~/.local/bin`、`/opt/homebrew/bin` 等位置查找）或完整路径。
- 局部转换和全局转换分别设置模型、思考档位和提示词。模型列表是从 agent 读取的，点「读取模型列表」刷新。
- 全局转换时单张图片的最长边（像素）。

说明：

- agent 进程在第一次用到时启动，之后一直保留，每次转换开一个新会话。冷启动后第一次请求比较慢（十几秒），之后公式识别一般在几秒内完成。
- Inkboard 不给 agent 文件读写和终端权限，它请求权限时一律拒绝；`.md` 文件由 Inkboard 自己写。
- agy 是编程 agent，每次请求都会附带它自己约 1 万 token 的系统提示，消耗的是你账号的额度。

## 代码结构

```
Sources/InkboardCore/     纯逻辑，不依赖 AppKit
  Stroke.swift            笔画模型
  StrokeSmoother.swift    增量样条平滑与重采样
  StrokeGeometry.swift    压感 → 轮廓路径
  InkOps.swift            擦除、套索、平移、插入空间
  InkRenderer.swift       渲染与导出 PNG
  BoardStore.swift        JSON 存储
  ACP.swift               ACP 客户端：启动 agent、JSON-RPC、会话与模型设置
  Transcription.swift     AI 转换接口与 ACP 实现、结果清理
  PageSlicer.swift        全局转换的切页与渲染
Sources/Inkboard/         macOS 应用
  BoardDocument.swift     .inkboard 文稿：读写、自动存储、复原
  CanvasView.swift        画布：输入、手势、绘制、撤销
  MainWindowController.swift  文稿窗口、工具栏、导出、局部 / 全局转换
  AISettings.swift        AI 设置（UserDefaults）
  SettingsWindowController.swift  设置窗口
  StatusBanner.swift      画布上方的状态提示条
  AppDelegate.swift       启动；旧版画板迁移
  MainMenu.swift / Tool.swift / main.swift
Sources/InkboardCheck/    自检程序（Command Line Tools 不带 XCTest，用它代替单元测试）
Support/Info.plist        应用信息、.inkboard 文件类型声明（打包时复制进 .app；swift run 时嵌入可执行文件）
```
