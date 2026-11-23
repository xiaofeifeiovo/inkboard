# Inkboard（原型）

轻量的 macOS 手写白板：纯 AppKit + Core Graphics，没有第三方依赖。

## 运行

```bash
scripts/build.sh            # 编译并打包 build/Inkboard.app
open build/Inkboard.app
scripts/build.sh check      # 编译 + 跑核心逻辑自检，并输出 build/sample.png 和 build/sample.pdf
```

开发时也可以直接 `swift run Inkboard`（不打包 .app），自检可以用 `swift run InkboardCheck`。

## 功能

| 工具 | 快捷键 | 说明 |
|---|---|---|
| 钢笔 | P | 黑色，支持压感，三档笔宽 |
| 橡皮擦 | E | 按笔迹局部擦除，会把笔画切成两段；数位笔翻过来用橡皮头时自动切换 |
| 套索选择 | L | 圈选（笔画或图片有一半以上在圈内就算选中），点一下选中单条笔画或一张图片；拖动框内可移动，⌫ 删除，Esc 取消 |
| 插入空间 | S | 在某一高度按下后向下拖，会把这条线以下的内容整体下移；往上拖则删除空白（不会越过这条线） |

- 撤销 / 重做：⌘Z / ⇧⌘Z
- 缩放：触控板双指捏合，或 ⌘= / ⌘- / ⌘0
- 平移：双指滚动，或按住空格拖动
- 画布向右、向下自动扩展
- 显示 → 显示点格：开关点格背景（所有窗口共用，会记住）。导出的 PNG / PDF 和发给 AI 的图片始终是纯白底，不带点格
- 显示 → 显示分块：显示自动分块的结果（段落、公式、图、贴图，按阅读顺序编号）和全局转换会发送的页面，用来检查分块效果
- 文件 → 导出 PNG…（⇧⌘E）/ 导出 PDF…（⌥⇧⌘E），有选区时只导出选区

### 图片

- 放入图片：⌘V 粘贴（截图、从浏览器或其他应用拷贝的图片、在访达里拷贝的图片文件），把图片或图片文件拖到画布上，或者「编辑 → 插入图片…」。可以一次放入多张。
- 图片按原始大小放入（Retina 截图就是屏幕上看到的大小），太大时缩小到窗口可见区域以内；放入后自动选中并切换到套索工具，可以马上拖动。
- 图片在所有笔迹下面，可以直接在图片上书写批注。
- 选中单张图片时四角有手柄，拖动手柄按比例缩放；⌫ 删除；橡皮擦不会擦掉图片。插入空间会把下方的图片一起推开。
- 图片保存在 `.inkboard` 文件里。PNG、JPEG 原样保存；其他格式（如剪贴板上的 TIFF、HEIC）会转成 PNG 或 JPEG，长边超过 4096 像素的会缩小。
- 局部转换只识别方框里的笔迹；全局转换会把贴图连同上面的批注一起发给 AI，由 AI 用一句话概括。

### 导出 PDF

- A4 纵向，笔迹是矢量的（放大不会模糊），图片嵌入在内。
- 分页方式和全局转换相同：按块装页，一段文字、一个公式、一张图不会被切到两页（只有长过一页的段落会在两行之间拆开）；所有页使用同一比例并左对齐，特别高的图单独一页并缩小。

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
- 文件格式是 JSON（`{"version":2,"strokes":[{"id","width","points":[x,y,压力,…]}],"images":[{"id","frame":[x,y,宽,高],"data":"<base64>"}]}`），读写代码在 `InkboardCore/BoardStore.swift`。没有图片的旧文件（version 1）照常打开。损坏或格式不对的文件会提示无法打开。

**从旧版本迁移**：加入文件功能之前，应用只有一块画板，保存在 `~/Library/Application Support/Inkboard/board.json`。升级后第一次启动时，这块画板会作为一个未命名文件打开，按 ⌘S 存到想要的位置即可。旧文件会改名为 `board.imported.json` 保留下来，不会删除。

### 压感

- 数位板（Wacom 等）、随航（Sidecar）上的 Apple Pencil：直接读取 `NSEvent.pressure`
- Force Touch 触控板：按下拖动时读取按压力度
- 普通鼠标：固定中等粗细

笔迹处理：先用向心 Catmull-Rom 样条平滑，再按约 1 屏幕像素的间距重新采样。每个采样点按压力换算成半径，笔画由圆和相邻圆之间的外切梯形拼成，最后一次性填充，所以急转弯处也不会出现破洞。

## AI 转换

两种调用方式，在设置里选：

- **ACP agent**：通过 [ACP（Agent Client Protocol）](https://agentclientprotocol.com) 调用本机的 AI agent，默认是 Antigravity 的 `agy acp`（需要先在终端用 `agy` 登录）。
- **OpenAI 兼容 API**：填写 Base URL、API Key 和模型，直接调用 API。OpenAI、Gemini（Google 提供的 OpenAI 兼容地址）、通义千问、DeepSeek、OpenRouter、本地 Ollama 等都支持这种格式。模型需要支持图片输入。

| 功能 | 入口 | 说明 |
|---|---|---|
| 局部转换 | 工具栏「局部转换」，或「转换」菜单 ⇧⌘L | 在画布上拖出一个方框框住公式，松开后自动识别，LaTeX 代码复制到剪贴板。可以接着框下一个；Esc 或切换工具退出 |
| 全局转换 | 工具栏「全局转换」，或「转换」菜单 ⇧⌘M | 把整个画板分块、装成若干页图片发给 AI，整理成 Markdown，存为与 `.inkboard` 同一文件夹下的同名 `.md`。未存储的文稿会先要求存储；同名文件已存在时询问是否替换 |
| 识别分块类型 | 「转换」菜单 | 让 AI 判断每一行是文字还是公式、每块图形是手绘图还是示意图，结果存进文稿，用来改进分块（打开「显示 → 显示分块」查看）。可以撤销 |

分页方式：

1. **分块**：先把画板分成一个个块：一段文字、一个单独的公式、一张手绘图或示意图、一张贴图（贴图上有墨迹时，图和墨迹是一个整体）。按从上往下、同一高度从左往右的顺序排列，图注紧跟在它的图后面。
2. **装页**：按顺序把块装进接近 A4 比例的页面，块不会被切开；一段文字长过一页时在两行之间拆开，特别大的图单独一页。每页只画属于这一页的块。

分块的边界完全在本地根据笔迹的几何形状确定。每一行是文字还是公式，本地只能根据分数线和等号来猜；用「识别分块类型」让 AI 判断后，以 AI 的结果为准（一段里夹着的公式行会单独成块）。改动笔迹后，对应位置的识别结果会自动失效，可以再识别一次。

**设置**（Inkboard → 设置…，⌘,）：

- 方式：ACP agent 或 OpenAI 兼容 API。
- ACP agent：命令和参数。默认 `agy` + `acp`；也可以换成其他支持 ACP 的 agent，例如 `gemini` + `--experimental-acp`。命令可以写名字（会在 `~/.local/bin`、`/opt/homebrew/bin` 等位置查找）或完整路径。
- OpenAI 兼容 API：Base URL（例如 `https://api.openai.com/v1`）和 API Key。API Key 存在系统钥匙串里；重新编译应用后，第一次读取时系统可能会询问是否允许。
- 局部转换和全局转换分别设置模型、思考档位和提示词（识别分块类型使用全局转换的模型）。两种方式各记一套模型选择。模型列表从 agent 或 API 读取，点「读取模型列表」刷新；列表里没有的模型可以用「其他模型…」填写。使用 API 时，思考档位会作为 `reasoning_effort` 发送，不支持这个参数的模型请保持「默认」。
- 全局转换时单张图片的最长边（像素）。

说明：

- agent 进程在第一次用到时启动，之后一直保留，每次转换开一个新会话。冷启动后第一次请求比较慢（十几秒），之后公式识别一般在几秒内完成。
- Inkboard 不给 agent 文件读写和终端权限，它请求权限时一律拒绝；`.md` 文件由 Inkboard 自己写。
- agy 是编程 agent，每次请求都会附带它自己约 1 万 token 的系统提示，消耗的是你账号的额度。

## 代码结构

```
Sources/InkboardCore/     纯逻辑，不依赖 AppKit
  Board.swift             画板模型（笔画 + 图片）、图片导入与规范化
  Stroke.swift            笔画模型
  StrokeSmoother.swift    增量样条平滑与重采样
  StrokeGeometry.swift    压感 → 轮廓路径
  InkOps.swift            擦除、套索、平移、插入空间、图片缩放
  InkLayout.swift         分块：段落、公式、手绘图、示意图、贴图，阅读顺序
  PageAssembler.swift     把块装成页（全局转换、导出 PDF）
  BlockLabeling.swift     识别分块类型：带编号的页面图片、解析 AI 的回答
  InkRenderer.swift       渲染与导出 PNG
  PDFExport.swift         导出 PDF（A4 分页）
  BoardStore.swift        JSON 存储
  ModelBackend.swift      AI 后端接口（ACP agent 与 API 共用）
  ACP.swift               ACP 客户端：启动 agent、JSON-RPC、会话与模型设置
  OpenAICompatible.swift  OpenAI 兼容 API 客户端
  Transcription.swift     AI 转换（公式、全文、识别分块类型）与结果清理
  InkImage.swift          页面图片的渲染
Sources/Inkboard/         macOS 应用
  BoardDocument.swift     .inkboard 文稿：读写、自动存储、复原
  CanvasView.swift        画布：输入、手势、绘制、撤销、粘贴 / 拖入图片
  ImagePasteboard.swift   从剪贴板 / 拖放中读取图片
  MainWindowController.swift  文稿窗口、工具栏、导出 PNG / PDF、插入图片、局部 / 全局转换
  AISettings.swift        AI 设置（UserDefaults）
  APIKeychain.swift       API Key 存取（钥匙串）
  SettingsWindowController.swift  设置窗口
  StatusBanner.swift      画布上方的状态提示条
  AppDelegate.swift       启动；旧版画板迁移
  MainMenu.swift / Tool.swift / main.swift
Sources/InkboardCheck/    自检程序（Command Line Tools 不带 XCTest，用它代替单元测试）
Support/Info.plist        应用信息、.inkboard 文件类型声明（打包时复制进 .app；swift run 时嵌入可执行文件）
```
