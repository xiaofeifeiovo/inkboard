# AGENTS.md

给在本仓库工作的 AI 编码代理（Claude Code、Codex 等）的说明。本文件是唯一维护的项目说明；`CLAUDE.md` 只是引用它，项目说明的改动都写在这里。

Inkboard：轻量的 macOS 手写白板原型（类似 Freeform），纯 AppKit + Core Graphics，没有第三方依赖。界面文字（菜单、提示）是中文，代码和注释用英文。

## 命令

```bash
scripts/build.sh            # release 编译 + 打包 build/Inkboard.app（复制 Support/Info.plist、ad-hoc 签名、注册到 Launch Services）
scripts/build.sh debug      # debug 编译 + 打包
scripts/build.sh check      # 编译 + 运行自检，输出 build/sample.png 和 build/sample.pdf（渲染样例，可以直接看图检查）
INKBOARD_BUILD_DIR=/tmp/x scripts/build.sh check  # 在指定目录编译并跳过 Launch Services 注册，可与默认 build/ 并行
open build/Inkboard.app

swift build                 # SwiftPM 也能用
swift run Inkboard          # 不打包直接运行；Info.plist 通过链接参数嵌进可执行文件，文件存取同样可用
swift run InkboardCheck [out.png]
```

- 本机只有 Command Line Tools（Swift 6.0.3），没有 Xcode，因此也没有 XCTest。测试入口在 `Sources/InkboardCheck/main.swift`（分块与 AI 分组测试在 `LayoutChecks.swift`，自动检查的核心与调度测试分在 `AutoCheckCoreChecks.swift` 和 `AutoCheckerChecks.swift`），用 `check(条件, 描述)` 断言；运行时全部执行（很快），没有单项筛选；有失败时退出码非 0。
  - ACP 客户端的测试用 `/usr/bin/python3` 运行一个模拟 agent（脚本在 `Sources/InkboardCheck/MockAgent.swift`，为每个会话维护独立 id 和轮数），不联网。
  - 测试会用到的全局常量不要定义在 `main.swift` 里：那里的全局变量按语句顺序初始化，定义在使用之后会在运行时崩溃（段错误）。
- 没有配置 linter 或 formatter。
- 包用 Swift 5 语言模式（tools-version 5.9），AppKit 代码没有按 Swift 6 严格并发标注。
- 应用直接从 `build/Inkboard.app` 运行，`scripts/build.sh` 会整个替换这个目录。要退出正在运行的应用，用 `osascript -e 'tell application id "local.inkboard.prototype" to quit'`，不要 `pkill`：直接杀进程会丢掉未存储的「未命名」文稿。
- 编译报 `redefinition of module 'SwiftBridging'`，或者 `swift build` 链接 manifest 失败时：原因是 Command Line Tools 升级残留的旧文件。之前已经把 5 个这样的文件移到 `/Library/Developer/CommandLineTools-stale-backup-2026-11-21/`，如果报错再次出现，先查是不是又有残留。

## 架构

三个 target：`InkboardCore`（纯逻辑，不 import AppKit）、`Inkboard`（AppKit 应用）、`InkboardCheck`（自检）。画布坐标系 y 轴向下，所有地方都一样，只有导出位图时在 `InkRenderer` 里翻转。

### 笔迹管线

`NSEvent` 采样（位置 + 压力）
→ `StrokeSmoother`：增量的向心 Catmull-Rom 样条。最后一段要等下一个采样到了才能定形，之前作为直线 `tail` 临时绘制。
→ 约每 1 屏幕像素一个点的稠密点列，存进 `Stroke.points`，同时缓存 `CGPath` 和 `bounds`
→ `StrokeGeometry.Stamper`：把每个点画成圆，相邻两点之间补外切梯形，最后用 non-zero 规则一次填充。

- 所有子路径必须保持逆时针绕向。绕向不一致，重叠处会变成空洞。
- `Stamper` 是值类型：画实时笔画时，复制一份去追加临时 tail，不会影响已定形的部分。
- 压力来源：`event.subtype == .tabletPoint` 时用数位板或随航（Sidecar）Apple Pencil 的压力；Force Touch 触控板走 `pressureChange(with:)`；鼠标固定 0.6。压力到半径的换算只在 `StrokeGeometry.radius`。

### 编辑与撤销

- 画板内容是值类型 `Board`（`InkboardCore/Board.swift`）：`strokes` 加 `images`。笔画和图片共用一个 id 空间，选区是两者 id 的 `Set<UUID>`。
- `InkOps` 里是纯函数（擦除并切分、套索、点选、平移、插入空间、图片缩放）。擦除只作用于 `[Stroke]`；其余有 `Board` 版本，同时处理笔画和图片。
- `CanvasView` 持有 `board`（`strokes` 是它的只读快捷属性），交互由 `Gesture` 枚举表示的状态机驱动，通过 `apply(_:actionName:)` 提交修改。撤销是整个 `Board` 的快照交换（图片的数据和解码后的 `CGImage` 在快照间共享，不会复制）。
- 移动、缩放和插入空间在拖动过程中只做平移绘制，松开鼠标时才提交；橡皮擦边擦边改，松开时注册一次撤销。

### 图片

- `BoardImage`：`frame`（画布坐标）+ 编码后的数据（PNG 或 JPEG）+ 解码后的 `CGImage`。图片始终画在所有笔迹下面，同类之间按数组顺序。
- 来源都走 `CanvasView.insertImages`：⌘V（`paste:`）、拖放到画布、「编辑 → 插入图片…」。读剪贴板的逻辑在 `ImagePasteboard`：有文件 URL 时只取图片文件（访达拷贝文件时剪贴板上还有文件图标，不能当图片贴进来），否则按 PNG → JPEG → HEIC → GIF → TIFF 取每个剪贴板项，最后才用 `NSImage(pasteboard:)` 兜底（比如只有 PDF）。
- 入库前由 `ImageImport.prepare` 规范化：PNG/JPEG 原样保存；其他格式（剪贴板上的 TIFF、HEIC 等）、带 EXIF 旋转的照片、长边超过 4096 像素的图会重新编码（照片转 JPEG，其余转 PNG）。多分辨率 TIFF 取最大的那张。自然尺寸按 DPI 换算（Retina 截图 144 DPI → 屏幕上看到的大小），插入时再缩小到可见区域的 80% 以内，并自动选中、切到套索工具。
- 只选中一张图片时显示四角手柄，拖动按比例缩放（`InkOps.resize`，对角固定、不翻转）。橡皮擦不影响图片。局部转换只发送方框里的笔迹；全局转换的页面图片包含该页各块里的图片（见下面「分块与装页」）。

### 导出

- PNG：`InkRenderer.renderImage(board)`，有选区时只导出选区。
- PDF：`PDFExport`（InkboardCore），A4 纵向，笔迹保持矢量、图片嵌入。和全局转换一样先分块再装页（`PageAssembler`，`maxSide` 设为无穷大，只有一列），块不会被切开；所有页同一比例、左对齐，内容宽度（至少 `minWidth` = 720 画布单位）占满版心，超过一页高的块单独一页并缩小（每页有自己的 `scale`）。每页只画本页各块（`board.subset(page.ids)`）。
- 所有绘制都在 y 向下的坐标系里进行；`CGContext.draw(image)` 直接用会上下颠倒，画图片统一走 `InkRenderer.draw(_:in:ctx:)`（内部局部翻转）。

### 文稿（`.inkboard`）

- 基于 NSDocument（`BoardDocument`），每个文件一个窗口（`MainWindowController`）。文件内容是 JSON：`{"version":2,"strokes":[{"id","width","points":[x,y,压力,…]}],"images":[{"id","frame":[x,y,宽,高],"data":"<PNG/JPEG 的 base64>"}],"labels":[{"strokes":[id,…],"kind":"formula"}],"groups":[{"strokes":[id,…],"kind":"formula"}],"autoCheck":{…}}`，读写代码在 `BoardStore`。version 1（没有 `images`）的旧文件照常打开，存储时写成 version 2。`labels` 可选（见「分块与装页」），只要有一笔已不存在就会丢弃；`groups` 可选（见「分块与装页」），存储和读取时笔画 id 排序、剔除已不存在的笔画（`restricted(to:)`），不再剩笔画的组丢弃，为空时省略；`autoCheck` 可选（见「自动检查」），为空时省略。
- 文件类型声明在 `Support/Info.plist`：UTI `local.inkboard.board`，`NSDocumentClass` 为 `BoardDocument`（类上有 `@objc(BoardDocument)`，改名时两边要一起改）。这个 plist 是唯一来源：`build.sh` 把它复制进 .app，`Package.swift` 用 `-sectcreate __TEXT __info_plist` 把它嵌进 `swift run` 的可执行文件。
- 数据流：画布每次提交修改，都通过 `onContentChange` 把 `canvas.board` 同步到 `document.board`；`data(ofType:)` 写的是 `document.board` 和 `document.autoCheck`。`read(from:)` 也会重新加载画布和自动检查状态，「复原」和「浏览版本」都走这里。
- **「已编辑」状态主要来自撤销注册**：窗口的 undoManager 就是文稿的 undoManager。画板的新增修改操作如果不注册撤销，文稿就不会被标记为已编辑，也不会自动存储。例外是异步的自动检查状态（`BoardDocument.autoCheck`），它不进撤销栈，改动时由 `BoardDocument` 直接调用 `updateChangeCount(.changeDone)`。
- `AppDelegate.applicationShouldOpenUntitledFile` 里的 `LegacyBoard`：把旧版唯一的画板 `~/Library/Application Support/Inkboard/board.json` 作为未命名文稿导入一次，然后把它改名为 `board.imported.json`。

### 应用外壳

- 菜单在 `MainMenu.swift` 里用代码创建，必须在 `applicationWillFinishLaunching` 里设置，否则 NSDocumentController 认不出「打开最近使用」菜单。动作沿响应链传递：CanvasView → NSWindow（撤销/重做）→ MainWindowController → BoardDocument → NSDocumentController。
- 单键快捷键（P/E/L/S 切换工具、空格平移、⌫ 删除、Esc 取消选择）在 `CanvasView.keyDown` 里处理，不要做成不带修饰键的菜单快捷键，否则会吞掉文本框里的输入。
- 「编辑」菜单有标准的剪切 / 拷贝 / 粘贴（设置窗口的文本框也靠它们才能用 ⌘X/⌘C/⌘V）；画布只实现 `paste:`（粘贴图片）。
- 光标是全局的：只有指针在画布可见区域内时才设置工具光标，离开时还原成箭头。不要设置 `window.acceptsMouseMovedEvents`，这曾导致黑点光标在整个系统里残留；悬停事件来自画布自己的 tracking area。
- 画布尺寸只增不减：最小 3000×4000，在内容右侧和下方保留 1500 的余量。
- 点格背景是全局偏好（`CanvasView.showsDotGrid`，UserDefaults 键 `canvas.showsDotGrid`，默认开），开关在「显示」菜单，动作在 `AppDelegate`，这样没有窗口时也能切换。「显示分块」同理。它只影响屏幕绘制：导出的 PNG / PDF 和 AI 图片都由 `InkRenderer` 渲染成纯白底，从不带点格。

### AI 转换（ACP 或 OpenAI 兼容 API）

- 五个功能：局部转换（框选公式 → LaTeX → 剪贴板）、全局转换（整个画板 → Markdown，存为文稿同目录下的同名 `.md`）、识别分块类型 / AI 识别分块（见「分块与装页」，共占「转换」菜单同一位置，分别对应本地计算与 AI 辅助分块方式）、自动检查（见「自动检查」）。接口是 `InkboardCore/Transcription.swift` 里的 `HandwritingTranscriber`（含 `labelBlocks`、`segmentBlocks`）和 `AutoCheck.swift` 里的 `AutoCheckService`，都由 `AITranscriber` 实现，实例在 `AppDelegate.transcriber`。
- 两种后端，都实现 `ModelBackend`（`send(parts, model, thoughtLevel)`、`openConversation(model, thoughtLevel)`、`modelCatalog()`、`prepare()`、`shutdown()`，提示由 `PromptPart` 的文字和 PNG 组成）：`ACPAgent`（`ACP.swift`）和 `OpenAICompatibleBackend`（`OpenAICompatible.swift`）。`AITranscriber` 按设置里的 `AIBackendConfiguration` 创建并缓存后端，配置变了就换（ACP 会重启 agent 进程）。
- OpenAI 兼容后端：`POST {Base URL}/chat/completions`，一条 user 消息里放文字和 `data:image/png;base64,…` 图片；思考档位作为 `reasoning_effort` 发送（为空则不发，很多模型不认这个参数）；模型列表来自 `GET {Base URL}/models`，没有默认模型，必须选或填写。Base URL 会去掉多余的 `/` 和粘贴进来的 `/chat/completions`。测试用 `URLProtocol` 桩（自检里的 `StubHTTP`），不联网。
- API Key 存在登录钥匙串里（`APIKeychain`，service `local.inkboard.api-key`，每个 Base URL 一条），只在发请求和打开 API 设置时读取，不进 UserDefaults。应用是 ad-hoc 签名，重新编译后第一次读取时系统可能会询问是否允许。
- 设置窗口顶部选择「方式」，只显示所选后端的字段；两种后端各存一套模型和思考档位（`ai.formula.*` / `ai.api.formula.*` 等，`AISettings.activeFormulaModel` 这类属性取当前后端的值）。模型列表的缓存以 `catalogSource` 区分（agent 命令行或 `api <Base URL>`）。模型菜单末尾的「其他模型…」可以手动填写模型名。
- `InkboardCore/ACP.swift` 是 ACP 客户端：用 `Process` 启动 agent（默认 `agy acp`，即 Antigravity），在 stdin/stdout 上逐行收发 JSON-RPC。agent 进程第一次用到时启动并一直保留（`prepare()` 还会预先建一个会话），每个请求开新会话、用完关闭。
- 客户端在 `initialize` 里不声明文件和终端能力，`session/request_permission` 一律选拒绝，会话 cwd 是临时目录 `$TMPDIR/Inkboard-ACP`。agent 只负责返回文字，文件由 Inkboard 自己写。
- 模型和思考档位通过会话的 config options（`session/set_config_option`，按 category `model` / `thought_level` 查找）设置。模型不存在时报错，思考档位当前模型不支持时静默忽略（各模型的档位不同，比如只有部分模型有 xhigh）。模型列表从 agent 动态读取，缓存在 UserDefaults，不要在代码里写死模型清单（默认值除外）。
- 设置存在 UserDefaults 的 `ai.*` 键（`AISettings`），每次请求都会重新读取；命令行变了会重启 agent。从 Finder 启动的应用 PATH 很短，所以 `ACPAgentConfiguration.searchPath()` 会补上 `~/.local/bin`、`/opt/homebrew/bin` 等目录，并传给子进程。
- `session/new` 返回 -32000（需要认证）时，会用 agent 提供的第一个认证方式调用一次 `authenticate` 再重试；仍失败则提示用户在终端登录。
- 局部转换是 `CanvasView.isCapturingFormula` 模式：拖动画框，松开即转换；方框只是覆盖层，不改笔迹、不注册撤销。选择任何工具（包括当前工具）或按 Esc 退出。
- 全局转换的页面来自「分块 → 装页」（见下一节）：`MainWindowController.conversionPlan` 先在主线程取好 `LayoutSettings.layoutOptions`，在后台线程用 `InkLayout` 分块、复用未改动的固定页转写，再用 `AutoCheckPages.openPages` / `PageAssembler` 装页，每页只渲染本页各块的笔画和图片（`board.subset(page.ids)`），所以落进页面范围的其他块不会出现。页面参数来自 `AISettings.pageOptions`（最长边 = 设置里的像素上限）。

### 分块与装页（`InkLayout`、`PageAssembler`）

- `InkLayout.analyze(board, options:)`（纯函数）把画板分成块 `InkBlock`，按阅读顺序排列。`Options` 包含 `textHeight` 和 `useGroups`（默认 `false`），不传 `options` 时使用全局 `InkLayout.defaultOptions`。块的类型：`text`（段落，行内公式留在段落里）、`formula`、`drawing`、`diagram`、`image`（没有墨迹的贴图）、`figure`（贴图 + 上面的墨迹，墨迹在 `children` 里照常分块）。文字和公式块带 `lines`（每行的范围和笔画），装页时超高的段落按行拆分，按行标注类型与 AI 识别分块也以行为单元。
- 在矢量笔画上做，不做图像分割。所有阈值都是文字高度 h 的倍数；h 由 `estimateTextHeight` 从「连续书写、彼此靠近的一串笔画」的高度中位数估计（笔画很少时上限 32，免得纯画图的画板把 h 估得很大）。
- 步骤：笔画分为文字 / 横线 / 图形（比字大得多）；横线包括笔直的横笔和「扁长」的笔画（水平跨度 ≥ 0.9 倍笔迹长度、高 ≤ 0.2 倍宽），所以末端带钩的分数线也算 → 横线上下紧贴墨迹且都不超出横线两端的是分数线（三者粘成一个单元；分子分母可以超出两端 0.3h；超出部分与横线之间如果有落在横线高度上的墨迹，如 `t² =` 的「=」或字母 t，算公式的其余部分，不算超出），只有上方有墨迹的是下划线 → **高而不闭合的运算符笔画**（`resolveTallOperators`：高 > 2.4h、宽 ≤ 1.2 高、两端相距 > 0.6h、不接触图形、旁边有同高度带文字且不跨超过 2h 的多行基线，如 ∫、|、Σ、括号、根号）转回文字并记入 `operators`，作为所在行的成员和公式线索 → 文字笔画按书写顺序和距离合成字，再按竖直重叠和水平空隙（≤ 5h，中心高度差 ≤ 0.75 倍较高者；一行里可以先写字、隔一段再写公式。贴着图形的墨迹，如单独一笔的箭头、标注，只按 ≤ 3h 连，留给图形吸收）连成行；但中间有图形线段穿过（`graphicIntersects`）或有对齐的**栏缝**（`blocked`：空隙 ≥ h，且中心相距 h–2.5h 的相邻行在同位置左右两侧都有字、无字跨过该空白；离得更远的行是另一段内容，不作为栏缝证据）时不连（已知取舍：几行恰好对齐的宽词间空白可能被当成栏缝；只有一行、空隙 3h–5h 的两栏会连成一行）→ 图形笔画按距离合成图，图吸收落在它里面的行和贴着它的短标注；只有图形笔画闭合（允许角上提笔，容差 0.45h）且把内部所有行的中心点都包住时（`isEnclosure`）才算「加框的文字」→ 贴图吸收大部分落在它上面的行和伸到它上面的图（被同一笔墨迹连起来或互相重叠的贴图合成一个 figure）→ 剩下的行按行距合成段落：左边缘对齐（相差 ≤ h）的行，阈值根据本画板的典型行距自适应，限制在 `0.8h–1.5h`；左边缘不齐（缩进或突出，通常是另起一条）的行只在紧挨着（≤ 0.8h）时才连 → 阅读顺序用递归 XY-cut，先上下后左右，图注（图下方紧挨着的 1–2 行文字）排在它的图后面。
- 三个公式线索：分数线、「=」（按书写顺序连续的两条短横、互相平行重叠、间距适中，并且两横之间以及上下各一个间距内没有别的墨迹，这样「三」「言」之类不会被当成等号；单独的「二」仍会误判）、高而不闭合的运算符笔画（`operators`）。含任一线索的行猜作公式行。上标（偏高）和下标（偏低）与所在行的竖直重叠不够，作为「小碎片」（不超过约 1.5h）并入 0.5h 以内最近的行。
- 每行有类型 `InkLine.kind`（text / formula）：`Board.labels` 里有标签就用标签，否则用上面的猜测。段落在行的类型变化处拆开，所以「文字行 + 公式行」会变成文字块和公式块。图形块同样可以用标签改类型（包括改成 formula / text）。`drawing` / `diagram` 的猜测：有标注或直线多就算示意图。
- `Board.labels`：键是一个单元（一行，或一个没有行的块）的笔画 id 集合，值是类型。来源是本地计算模式下的「转换 → 识别分块类型」（`BlockLabeling`）：按全局转换的页面渲染，每行用红框和 L1、L2… 标出，每个图形用 G1… 标出（阅读顺序），连同固定提示词（`BlockLabeling.prompt`，不可在设置里改，因为它规定了回答格式）发给全局转换的模型，回答是 `{"L1":"text","G1":"diagram"}` 这样的 JSON，由 `BlockLabeling.parse` 读取（容忍代码块、大小写，跳过未知编号和不合适的类型）。结果整体替换 `labels`，经 `CanvasView.setLabels` 提交，可撤销、随文稿存储。墨迹改动后对不上的标签自动失效；全局转换和导出 PDF 直接使用已有标签，不会自动发起识别。
- **分块方式与 AI 分组**（`BlockSegmentation.swift`、`BlockSegmentationPrompt.swift`、`LayoutSettings.swift`）：
  - **模式与全局选项**：`SegmentationMode` 有三个值：`geometric`（本地计算，默认）、`aiAssisted`（AI 辅助）、`model`（专用墨迹分块模型，设置里显示为灰色不可选「即将支持」）。存在 UserDefaults 键 `layout.segmentationMode`。应用启动（`AppDelegate.applicationWillFinishLaunching`）和切换模式时由 `LayoutSettings.apply()` 设置 `InkLayout.defaultOptions.useGroups = (mode == .aiAssisted)` 并调用 `MainMenu.updateSegmentationItem()` 更新菜单标题；切换时发 `LayoutSettings.didChange` 通知（画布清空覆盖层缓存并重绘，`MainWindowController` 通知 `checker.layoutDidChange()`）。后台线程调用 `InkLayout.analyze` / `BlockLabeling.request` 前，必须在主线程读取 `LayoutSettings.layoutOptions` 再传入。
  - **`Board.groups` 与分组规则**：`Board.groups: [BlockGroup]`（每项含 `ids: Set<UUID>` 和 `kind`，只接受 `text` / `formula` / `drawing` / `diagram`）。`Options.useGroups` 为假时 `InkLayout` 完全忽略 `groups`；为真时 `groupedBlocks` 在顶层和每个 `figure` 的 `children` 内部各自应用分组（不跨贴图边界）：每个组生成一个块并采用组的 `kind`，已不存在的笔画忽略；组外新写的笔画照常几何分块，落在含组内笔画的几何块时按该块内组笔画数最多（平局按存储顺序靠前）并入那个组，不含任何组笔画的几何块照常保留；含多个组笔画的几何块和行按组拆开，文字/公式块保留行边界（原图形单元改标为写字时视为单行）并按阅读顺序排好；最终所有块重新做 XY-cut 阅读顺序（含图注）。
  - **AI 识别分块流程与提示词约定**：AI 辅助模式下，「转换」菜单同一项（`recognizeBlocks:`）标题变为「AI 识别分块」（本地计算下是「识别分块类型（文字 / 公式 / 图）」），通过 `MainWindowController.segmentBlocks` / `runSegmentation` 发送与「识别分块类型」相同的带 `L`/`G` 红框编号页面（`BlockLabeling.request`），调用 `transcriber.segmentBlocks`（使用全局转换的模型和思考档位）。固定提示词 `BlockSegmentation.prompt`（在 `BlockSegmentationPrompt.swift`，不可在设置里改）要求返回 `{"blocks":[{"units":["L1","L2"],"kind":"formula"},…]}`，与 `BlockSegmentation.parse` 是一对约定；`parse` 容忍代码块、前后文字和大小写，跳过未知编号和无效类型，重复分配的单元保留在第一个组，未提及的单元不进组（交由本地几何分块），读不到 JSON 对象抛 `BlockLabeling.LabelingError.unreadableReply`。因为最小单元是 `L`/`G`，AI 分组只能合并单元、不能把一个单元拆开。结果经 `CanvasView.setGroups` 整体替换 `Board.groups`（可撤销，动作名「AI 识别分块」），随文稿存为可选字段 `groups`。
- `PageAssembler.pages` 按阅读顺序贪心装页，块不拆开；超过一页的文字块按行拆，其他超大的块单独一页（渲染时缩小）。内容宽度不超过页面上限时，所有页共用同一个水平范围。
- 调参时打开「显示 → 显示分块」（`CanvasView.showsBlocks`，UserDefaults 键 `canvas.showsBlocks`，默认关）：画出每个块（按类型着色、按阅读顺序编号、figure 的子块编号为 3.1 这样）、每行的范围，以及全局转换的页面（虚线）。AI 辅助模式下，如果块内超过一半笔画属于同一个 `Board.groups` 条目（`CanvasView.isAIGrouped`），标签末尾带上 ` · AI`（如 `3 公式 · AI`）。结果缓存在画布里，画板、设置或分块方式一变就重算。
- 自检里有合成笔迹的生成函数（`glyph`、`textLine`、`paragraph`、`fractionFormula`、`equalsSign`、`hanLine`、`circle`、`rectangle`），新增分块规则时用它们写用例；`describe(blocks)` 输出块的简要结构，方便看失败原因。数学版式几何规则、AI 分组、`groups` 存取和 `BlockSegmentation.parse` 的测试都在 `Sources/InkboardCheck/LayoutChecks.swift`。
- 真实笔迹样本放在 `test/` 下，自检按 `#filePath` 查找并检查分块结果（缺文件时跳过），改分块规则后先确认三者都通过：
  - `test/未命名.inkboard`（`main.swift` 检查）：三行公式、坐标图、一行中文、一行公式（含上标 ᵀ 和下标 j），期望 `[formula(3行), diagram, text, formula]`。
  - `test/test.inkboard`（`LayoutChecks.swift` 检查）：一行中文标题 + 两行积分算式（含高积分号 ∫、高竖线 | 和较远的 `=`），期望 `[text, formula, formula]`，行数 `[1, 1, 1]`，笔画范围 `1...21`、`22...35`、`36...52`。
  - `test/多元统计分析.inkboard`（`LayoutChecks.swift` 检查）：10 行笔记，每行一条，行距大、各行缩进不同，行内文字和公式混排（如「一元情境就是 t 检验」右边隔约 3.8h 写 `t² = …`）；含末端带钩的分数线、分子超出横线一点的分数。期望每行一个块（行数都是 1）：`[text, text, formula, formula, formula, text, text, text, formula, formula]`，笔画范围见测试；第 3、5、9、10 块的行有分数线。文件里还存着当时的自动检查状态，可以用来复现画布标记。

### 自动检查

书写时把写完的块发给 AI，结合前面的内容判断错误并在画布上标出；按页分段进行多轮对话，换页时转写并固定当前页，供后续检查和全局转换复用。设计记录见 `docs/auto-check.md`。

- **数据与存储**（`InkboardCore/AutoCheck.swift`、`BoardStore.swift`、`BoardDocument.swift`）：`AutoCheckState`（`enabled`、`checks: [BlockCheck]`、`pages: [FixedPage]`、`nextTag`）存在 `BoardDocument.autoCheck`，**不在 `Board` 里**。文件格式仍是 version 2，新增可选顶层字段 `autoCheck`（`isEmpty` 时省略）；笔画 id 排序后写入，读写时丢弃和当前画板不再有交集的检查和固定页。检查结果、开关状态、「忽视」都**不进撤销栈**（避免 ⌘Z 撤销检查结果），改动通过 `onAutoCheckStateChange` 同步到 `BoardDocument` 并调用 `updateChangeCount(.changeDone)` 标记已编辑。
- **检查单元与身份**（`AutoCheckTracker`）：`CheckUnit` 是顶层块中除纯 `image` 外的块，以及 `figure` 的每个子块（带底图 id，渲染时一起画）；身份按笔画 id 集合识别（同 `Board.labels`）。`status(of:in:)` 判 `unchecked` / `checked(tag)` / `modified(tag)`（多块重叠时选重合笔画最多、平局取较小块号）。块号（`B1`、`B2`…）在首次发送时由 `allocateTag()` 分配，**绝不重新编号**。
- **书写跟踪与触发**（`WritingTracker`、`AutoChecker`）：只有新增笔迹（`CanvasView.onBoardCommit` 带 `addedStroke`）才推进 `WritingTracker.didWriteUnits`；擦除、移动、撤销不触发。新笔画所在单元不再包含上一个书写块的全部笔画时，留下的部分（拆分时可能有多个）按阅读顺序算写完。未检查的开放页块自动入队；「接着写」（`AutoCheckTracker.grownFrom` 确认单元包含所碰到的所有旧检查且一笔没少，并包含最近一次自动/手动接着写发送的 `continuationTag`，覆盖块变大和多块合并）自动重新检查，合并后沿用 `status(of:)` 选出的块号并移除其余被合并块号的旧结果；其他修改（擦除、移动、回到前面的块添加内容）等用户点「重新检查」，或在打开「自动重新检查改过的块」时于**修改完成**后自动重新检查：擦除 / 撤销 / 移动改到的块记在 `editedIDs`，下一笔落在别的块时算完成（`editsFinished`）；回到旧块补写的，由 `WritingTracker` 在写到别处时算完成（`blockFinished`）。
- **固定页与开放页**（`AutoCheckPages`）：`FixedPage` 记录固定时的 id 集合、`rect`、块号列表和带 `<!-- Bn -->` 注释的 Markdown。`fixedPageIndex` 先按共享 id 最多、再按新内容覆盖面积 ≥ 50% 归属固定页；其余块用 `PageAssembler`（参数同全局转换 `AISettings.pageOptions`）组成开放页，第 0 页是当前页。属于固定页的块从不自动发送；`isModified` 比较当前归属该页的 id 集合是否仍等于固定时。
- **调度**（`InkboardCore/AutoChecker.swift`）：`@MainActor` 调度器，串行执行队列中的任务（每次只发一个请求），发送时按笔画交集重新解析出该块当前状态，已不存在则跳过。
  - 打开开关：`setEnabled(true)` 排队全量检查开放页（非最后一页走页请求同时检查并固定，全已检查的页直接 `fixPage`；最后一页作为当前页对话首轮）；已固定页不自动检查。关闭开关取消进行中的请求、清空队列、关闭对话，保留结果并隐藏覆盖层。**打开一个开关已开的文稿（`load`）不自动全量检查**，仅照常响应后续书写。
  - 换页：待检查块落在开放页第 k 页（k > 0）时，先转写并固定当前页（`fixPage`；页上还有没检查过的块时改发页请求，检查它们并同时转写），关闭旧对话，再开新对话检查。当前页上还有正在书写的块时不固定它，待检查块直接在当前对话里检查。开放页按整块装页（`AutoChecker.openPages` 去掉 `lines`，超高的段落不按行拆开），一个检查单元不会只被判断或固定一部分。
  - 重新检查（`recheckPage`，docs/auto-check.md §4.4）：开放页上的「重新检查」/「检查」（块已有检查结果、且不是「接着写」）以及自动重新检查任务（`Job.recheck`）一律关闭当前对话、开新对话：首轮带固定页 Markdown、本页第一个需要重新判断的块（改过的、未检查的或被点的块中最靠前的）之前的已检查块（图片 + `verdictJSON`），再按阅读顺序附上从该块到本页末尾每块的图片（`blockLabel` + PNG，不含正在书写的块，除非点的就是它），用 `AutoCheckPrompts.recheckFrom` 一次判断；回答缺块抛 `unreadableReply`。没改过的块用 `updateVerdict`（问题不变时保留「忽视」），其余用 `setVerdict`。阶段为 `Stage.recheck(tags)`。新写完的块（`unchecked`）和「接着写」仍走 `sendBlock`：对话在则直接追加（改过的旧块不重发）。
  - 固定页重查（`recheckFixedPage`）：用户对固定页里的块点「检查」/「重新检查」时，从该页第一个变动块起发页请求重新判断并替换该页转写（回答缺转写时补发一次独立转写请求），随后发一次纯文字请求重判后续固定页和开放页上已检查的块，并关闭当前页对话。
  - 对话丢失重建：出错、取消、`isUsable` 为假、设置变化或重开文稿时关闭对话；下次在首轮带上所有固定页 Markdown 以及当前页已检查块的块图片和旧结果（`verdictJSON`）重建（`contextParts`）；改过、尚未重新检查的块附当前图片和 `noVerdictNote`，不附结果；未检查的块和正在书写的块不放。出错时不弹窗，暂停队列并在横幅显示错误与「重试」，直到 `retry()` 或手动触发检查。
  - 分组变化自动重查（`boardDidChange` / `layoutDidChange`）：`boardDidChange` 在 `addedStroke == nil`、笔画 id 集合未变而 `groups` 或 `labels` 变化时（AI 识别分块、其撤销/重做、识别分块类型）转调 `layoutDidChange`；切换分块方式（`LayoutSettings.didChange`）同样调 `checker.layoutDidChange()`。如果某个开放页单元在变化前碰到的旧检查全部完整未改（`intact`），现在仅因分组变化被合并或拆开而不再是 `.checked`，就自动入队重查（拆开的各部分分别重查，合并的整块查一次；并入当前正在书写块且带进未检查新笔画时，更新 `continuationTag` 等写完再查）。碰到了用户改过笔迹的旧检查，或位于固定页，则不自动重查，继续等「重新检查」。
- **提示词与渲染**：`InkboardCore/AutoCheckPrompts.swift` 的提示词固定（不可在设置里修改），其输出要求（JSON 字段、反斜杠转义、页请求用 `<!-- PAGE -->` 分隔 JSON 与 Markdown、块前加 `<!-- Bn -->` 注释）与 `AutoCheckReply` 解析逻辑是一对约定，改一边要同步改另一边。`parseChecks` 宽容处理代码块、大小写、重复块号和未转义的 LaTeX 反斜杠。`InkboardCore/AutoCheckRender.swift` 生成单块图片（`blockImage`，含底图和留白）和带红框与 `Bn` 块号的整页图片（`pageImage`）。
- **后端多轮对话**：`ModelBackend.openConversation(model:thoughtLevel:)` 返回 `ModelConversation`（`send`、`isUsable`、`close`）。`ACPAgent` 返回保持打开的 `ACPSession`，在同一会话里连续发 `session/prompt`，任何失败、取消、关闭或进程退出后 `isUsable` 变假；`OpenAICompatibleBackend` 返回 `ChatConversation`，本地保存 `user`/`assistant` 历史列表并在每次请求整段发送，失败后关闭。`AITranscriber` 实现 `AutoCheckService`。
- **应用层**：
  - 覆盖层与按钮（`CanvasView.swift`，内容来自 `AutoChecker.marks`）：绘制红框（error）、黄框（warning，偏橙）、灰色虚线框（原红/黄框块被改过）及屏幕固定尺寸的按钮（「详情」「忽视」「重新检查」/「检查」）。**排队、检查中和正在书写的块在画布上不显示任何标记**（它们列在工具栏菜单里），例外是红/黄框块被重新检查时保留框和按钮；其余未检查的块（如重开文稿后）显示小的「检查」。按钮命中优先于所有工具、悬停显示箭头。从菜单选中一个块时，`revealAutoCheckBlock` 滚动到它，由 `flashAutoCheckBlock` 用强调色框高亮并在约 2 秒内淡出（只是覆盖层，不碰笔迹和撤销栈）。
  - 详情弹窗（`AutoCheckDetails.swift`）：`NSPopover`，显示各问题严重程度、摘要、详情、`相关：Bn` 以及 `AI 读到的内容（Bn）`（可选中复制），打开时在画布高亮本块和相关块。
  - 开关、菜单、横幅与全局转换复用（`MainWindowController.swift`、`MainMenu.swift`）：工具栏是分体按钮 `NSComboButton`（`.split`）：主体切换开关，图标区分关 / 开 / 请求进行中 / 失败，提示文字说明当前状态；箭头打开 `autoCheckMenu`，状态每次变化和菜单打开时由 `rebuildAutoCheckMenu` 重建（菜单必须始终有内容：`NSComboButton` 的菜单为空时箭头变灰、点不开）：「正在检查」（`checkingUnits`，转写当前页、重判后面的块或全量检查剩余块时另有说明行）、「排队中（N）」（`queuedUnits`，排队的全量检查 `fullCheck` 为一行）、「正在书写」（`writingUnit` +「检查最新的块」⇧⌘K）、失败信息 +「重试」、「关闭自动检查」；块条目标题是阅读顺序位置和类型（「第 3 块 · 公式」）加 AI 读到的内容开头，不显示块号。菜单栏仍有「转换 → 自动检查」「转换 → 检查最新的块」（⇧⌘K）。「自动重新检查改过的块」是全局偏好（`AutoRecheckSetting`，在 `AISettings.swift`，UserDefaults 键 `ai.check.autoRecheck`，默认关），开关在「转换」菜单和自动检查下拉菜单（开着自动检查时，位于「关闭自动检查」上方），动作 `AppDelegate.toggleAutoRecheck`；各窗口收到 `AutoRecheckSetting.didChange` 后设置 `checker.autoRecheck`。分块方式为「AI 辅助」时，打开开关若当前有笔画不在任何 `Board.groups` 里（`hasUngroupedInk`）且没有其他文档任务进行中，会先跑一次「AI 识别分块」（`enablingAutoCheck = true`，进度与取消同时反映在 `documentBanner`、工具栏按钮和下拉菜单）；取消（点横幅「取消」、再点工具栏按钮或菜单「取消」）则不打开自动检查，失败时弹提示并改用本地分块继续打开。`checkBanner` 只在失败时显示错误 +「重试」，进度不再用横幅；全局转换的 `conversionPlan` 从第一页起复用连续且未改动的固定页转写（经 `stripBlockComments` 去块号注释），其余块照旧渲染发给 AI，全部可复用时不发请求。
  - 设置（`SettingsWindowController.swift`、`AISettings.swift`）：两种后端各存 `ai.check.model` / `ai.check.thoughtLevel` 与 `ai.api.check.model` / `ai.api.check.thoughtLevel`，留空表示「与全局转换相同」（思考档位随之跟随且不可用）。`AISettings.checkSignature`（方式 + 后端来源 + 实际模型与档位）变化时调用 `checker.settingsDidChange()` 丢弃当前页对话。
- **测试**：`Sources/InkboardCheck/AutoCheckCoreChecks.swift` 覆盖单元、身份、拆分/合并、固定页、回答解析、JSON 存取修剪、真实笔迹 `test/未命名.inkboard` 逐笔回放（第 11、38、61 笔结束不断变大的公式块并沿用 B1，第 101 笔结束中文行 B2，第 120 笔结束最后一行公式 B3）、HTTP 和 ACP 多轮会话；`Sources/InkboardCheck/AutoCheckerChecks.swift` 用假服务 `FakeCheckService` 测调度、换页、固定页重查、重建对话、重试、四种发送情况（新块追加、对话重建时改过的块无结果、重新检查从第一个改过的块起批量判断、对话丢失后同样批量）、自动重新检查（只擦不算完成，在别处落笔后才重查；补写的块写到别处后重查）、分组与分块方式变化自动重查（`runLayoutChangeChecks`）、画布标记与菜单信息（`checkingUnits` / `queuedUnits` / `fullCheck` / `writingUnit`）、带块号页面渲染与回放性能。

## 界面验证方法

本环境没有截屏权限（`screencapture` 会失败）。要在真实窗口里验证交互，做法如下：把 `Sources/Inkboard/*.swift`（不含 `main.swift`）和一个测试用 `main.swift` 一起编译成测试程序，在里面发送合成鼠标事件，再用 `cacheDisplay` 把窗口内容存成 PNG 查看。

```bash
O=build/obj   # 先运行 scripts/build.sh 生成
swiftc -Onone -target arm64-apple-macos13.0 -swift-version 5 -module-name Inkboard -I $O -L $O -lInkboardCore \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker harness/Info.plist \
  $(ls Sources/Inkboard/*.swift | grep -v main.swift) harness/main.swift -o harness/harness
```

- 合成事件用 `NSApp.postEvent` 送进事件队列，不要直接调用 `window.sendEvent`：绕过事件循环时撤销分组不会关闭，文稿就不会被标记为已编辑，测试结果会失真。
- 同理，在 `asyncAfter` 的回调里直接调用会注册撤销的方法（比如 `canvas.insertImages`），撤销分组也不会关闭。要模拟菜单命令，就让测试程序用一个 `NSApplication` 子类，在 `sendEvent` 里拦截自己 post 的 `.applicationDefined` 事件并执行对应的代码，这样代码运行在事件处理之中。
- 每个步骤放在单独的 run loop 轮次里执行（例如用 `asyncAfter` 串起来），否则所有撤销会被合并成一组。
- 测试程序的窗口不一定能成为 key window（用户正在用电脑时，系统可能不让它激活）。post 的键盘事件只发给 key window，`NSApp.target(forAction:)` 也从 key window 查找，所以结果会时好时坏。键盘操作直接调用 `canvas.keyDown(with:)`，撤销 / 重做直接调用 `undoManager`，检查响应链时从 `window.firstResponder` 沿 `nextResponder` 自己找。另外，合成的 ⇧⌘Z 不会匹配到「重做」菜单项。
- 测试程序嵌入的 Info.plist 要换一个 `CFBundleIdentifier`，避免往正式应用的「最近使用」列表里写东西；用完删掉它的偏好设置文件。
- 不要把文件路径作为命令行参数传给测试程序：AppKit 会把它当成要打开的文稿，弹出模态错误框卡住。需要传路径就用环境变量。
- 测试程序不要用 `AppDelegate` 作为应用代理：它启动时会执行旧版画板的导入（`LegacyBoard`），会改名用户的文件。自己写一个代理，在里面设置菜单、创建文稿。
- 测试 AI 转换与自动检查时：局部转换会改写系统剪贴板，测试前保存、结束后恢复；自动检查可在测试程序里把 `BoardDocument.makeCheckService` 换成自定义的假 `AutoCheckService`，不发真实请求；真实请求会消耗用户账号额度，能用模拟 agent、`StubHTTP` 或假服务验证的就不要发真实请求。
