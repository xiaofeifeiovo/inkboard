# AGENTS.md

给在本仓库工作的 AI 编码代理（Claude Code、Codex 等）的说明。本文件是唯一维护的项目说明；`CLAUDE.md` 只是引用它，项目说明的改动都写在这里。

Inkboard：轻量的 macOS 手写白板原型（类似 Freeform），纯 AppKit + Core Graphics，没有第三方依赖。界面文字（菜单、提示）是中文，代码和注释用英文。

## 命令

```bash
scripts/build.sh            # release 编译 + 打包 build/Inkboard.app（复制 Support/Info.plist、ad-hoc 签名、注册到 Launch Services）
scripts/build.sh debug      # debug 编译 + 打包
scripts/build.sh check      # 编译 + 运行自检，输出 build/sample.png 和 build/sample.pdf（渲染样例，可以直接看图检查）
open build/Inkboard.app

swift build                 # SwiftPM 也能用
swift run Inkboard          # 不打包直接运行；Info.plist 通过链接参数嵌进可执行文件，文件存取同样可用
swift run InkboardCheck [out.png]
```

- 本机只有 Command Line Tools（Swift 6.0.3），没有 Xcode，因此也没有 XCTest。测试统一写在 `Sources/InkboardCheck/main.swift` 里，用 `check(条件, 描述)` 断言；运行时全部执行（很快），没有单项筛选；有失败时退出码非 0。
  - ACP 客户端的测试用 `/usr/bin/python3` 运行一个模拟 agent（脚本在 `Sources/InkboardCheck/MockAgent.swift`），不联网。
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

- 基于 NSDocument（`BoardDocument`），每个文件一个窗口（`MainWindowController`）。文件内容是 JSON：`{"version":2,"strokes":[{"id","width","points":[x,y,压力,…]}],"images":[{"id","frame":[x,y,宽,高],"data":"<PNG/JPEG 的 base64>"}],"labels":[{"strokes":[id,…],"kind":"formula"}]}`，读写代码在 `BoardStore`。version 1（没有 `images`）的旧文件照常打开，存储时写成 version 2。`labels` 可选（见「分块与装页」），笔画已不存在的标签存储时丢弃。
- 文件类型声明在 `Support/Info.plist`：UTI `local.inkboard.board`，`NSDocumentClass` 为 `BoardDocument`（类上有 `@objc(BoardDocument)`，改名时两边要一起改）。这个 plist 是唯一来源：`build.sh` 把它复制进 .app，`Package.swift` 用 `-sectcreate __TEXT __info_plist` 把它嵌进 `swift run` 的可执行文件。
- 数据流：画布每次提交修改，都通过 `onContentChange` 把 `canvas.board` 同步到 `document.board`；`data(ofType:)` 写的是 `document.board`。`read(from:)` 也会重新加载画布，「复原」和「浏览版本」都走这里。
- **「已编辑」状态完全来自撤销注册**：窗口的 undoManager 就是文稿的 undoManager。新增的修改操作如果不注册撤销，文稿就不会被标记为已编辑，也不会自动存储。
- `AppDelegate.applicationShouldOpenUntitledFile` 里的 `LegacyBoard`：把旧版唯一的画板 `~/Library/Application Support/Inkboard/board.json` 作为未命名文稿导入一次，然后把它改名为 `board.imported.json`。

### 应用外壳

- 菜单在 `MainMenu.swift` 里用代码创建，必须在 `applicationWillFinishLaunching` 里设置，否则 NSDocumentController 认不出「打开最近使用」菜单。动作沿响应链传递：CanvasView → NSWindow（撤销/重做）→ MainWindowController → BoardDocument → NSDocumentController。
- 单键快捷键（P/E/L/S 切换工具、空格平移、⌫ 删除、Esc 取消选择）在 `CanvasView.keyDown` 里处理，不要做成不带修饰键的菜单快捷键，否则会吞掉文本框里的输入。
- 「编辑」菜单有标准的剪切 / 拷贝 / 粘贴（设置窗口的文本框也靠它们才能用 ⌘X/⌘C/⌘V）；画布只实现 `paste:`（粘贴图片）。
- 光标是全局的：只有指针在画布可见区域内时才设置工具光标，离开时还原成箭头。不要设置 `window.acceptsMouseMovedEvents`，这曾导致黑点光标在整个系统里残留；悬停事件来自画布自己的 tracking area。
- 画布尺寸只增不减：最小 3000×4000，在内容右侧和下方保留 1500 的余量。
- 点格背景是全局偏好（`CanvasView.showsDotGrid`，UserDefaults 键 `canvas.showsDotGrid`，默认开），开关在「显示」菜单，动作在 `AppDelegate`，这样没有窗口时也能切换。「显示分块」同理。它只影响屏幕绘制：导出的 PNG / PDF 和 AI 图片都由 `InkRenderer` 渲染成纯白底，从不带点格。

### AI 转换（ACP 或 OpenAI 兼容 API）

- 三个功能：局部转换（框选公式 → LaTeX → 剪贴板）、全局转换（整个画板 → Markdown，存为文稿同目录下的同名 `.md`）、识别分块类型（见下一节）。接口是 `InkboardCore/Transcription.swift` 里的 `HandwritingTranscriber`，实现是 `AITranscriber`，实例在 `AppDelegate.transcriber`。
- 两种后端，都实现 `ModelBackend`（`send(parts, model, thoughtLevel)`、`modelCatalog()`、`prepare()`、`shutdown()`，提示由 `PromptPart` 的文字和 PNG 组成）：`ACPAgent`（`ACP.swift`）和 `OpenAICompatibleBackend`（`OpenAICompatible.swift`）。`AITranscriber` 按设置里的 `AIBackendConfiguration` 创建并缓存后端，配置变了就换（ACP 会重启 agent 进程）。
- OpenAI 兼容后端：`POST {Base URL}/chat/completions`，一条 user 消息里放文字和 `data:image/png;base64,…` 图片；思考档位作为 `reasoning_effort` 发送（为空则不发，很多模型不认这个参数）；模型列表来自 `GET {Base URL}/models`，没有默认模型，必须选或填写。Base URL 会去掉多余的 `/` 和粘贴进来的 `/chat/completions`。测试用 `URLProtocol` 桩（自检里的 `StubHTTP`），不联网。
- API Key 存在登录钥匙串里（`APIKeychain`，service `local.inkboard.api-key`，每个 Base URL 一条），只在发请求和打开 API 设置时读取，不进 UserDefaults。应用是 ad-hoc 签名，重新编译后第一次读取时系统可能会询问是否允许。
- 设置窗口顶部选择「方式」，只显示所选后端的字段；两种后端各存一套模型和思考档位（`ai.formula.*` / `ai.api.formula.*` 等，`AISettings.activeFormulaModel` 这类属性取当前后端的值）。模型列表的缓存以 `catalogSource` 区分（agent 命令行或 `api <Base URL>`）。模型菜单末尾的「其他模型…」可以手动填写模型名。
- `InkboardCore/ACP.swift` 是 ACP 客户端：用 `Process` 启动 agent（默认 `agy acp`，即 Antigravity），在 stdin/stdout 上逐行收发 JSON-RPC。agent 进程第一次用到时启动并一直保留（`prepare()` 还会预先建一个会话），每个请求开新会话、用完关闭。
- 客户端在 `initialize` 里不声明文件和终端能力，`session/request_permission` 一律选拒绝，会话 cwd 是临时目录 `$TMPDIR/Inkboard-ACP`。agent 只负责返回文字，文件由 Inkboard 自己写。
- 模型和思考档位通过会话的 config options（`session/set_config_option`，按 category `model` / `thought_level` 查找）设置。模型不存在时报错，思考档位当前模型不支持时静默忽略（各模型的档位不同，比如只有部分模型有 xhigh）。模型列表从 agent 动态读取，缓存在 UserDefaults，不要在代码里写死模型清单（默认值除外）。
- 设置存在 UserDefaults 的 `ai.*` 键（`AISettings`），每次请求都会重新读取；命令行变了会重启 agent。从 Finder 启动的应用 PATH 很短，所以 `ACPAgentConfiguration.searchPath()` 会补上 `~/.local/bin`、`/opt/homebrew/bin` 等目录，并传给子进程。
- `session/new` 返回 -32000（需要认证）时，会用 agent 提供的第一个认证方式调用一次 `authenticate` 再重试；仍失败则提示用户在终端登录。
- 局部转换是 `CanvasView.isCapturingFormula` 模式：拖动画框，松开即转换；方框只是覆盖层，不改笔迹、不注册撤销。选择任何工具（包括当前工具）或按 Esc 退出。
- 全局转换的页面来自「分块 → 装页」（见下一节）：`MainWindowController.pageImages` 先用 `InkLayout` 分块，再用 `PageAssembler` 装页，每页只渲染本页各块的笔画和图片（`board.subset(page.ids)`），所以落进页面范围的其他块不会出现。页面参数来自 `AISettings.pageOptions`（最长边 = 设置里的像素上限）。

### 分块与装页（`InkLayout`、`PageAssembler`）

- `InkLayout.analyze(board)`（纯函数）把画板分成块 `InkBlock`，按阅读顺序排列。块的类型：`text`（段落，行内公式留在段落里）、`formula`、`drawing`、`diagram`、`image`（没有墨迹的贴图）、`figure`（贴图 + 上面的墨迹，墨迹在 `children` 里照常分块）。文字和公式块带 `lines`（每行的范围和笔画），装页时超高的段落按行拆分，以后按行标注类型也会用到。
- 在矢量笔画上做，不做图像分割。所有阈值都是文字高度 h 的倍数；h 由 `estimateTextHeight` 从「连续书写、彼此靠近的一串笔画」的高度中位数估计（笔画很少时上限 32，免得纯画图的画板把 h 估得很大）。
- 步骤：笔画分为文字 / 横线 / 图形（比字大得多）→ 横线上下紧贴墨迹且都不超出横线两端的是分数线（三者粘成一个单元），只有上方有墨迹的是下划线 → 文字笔画按书写顺序和距离合成字，再按竖直重叠和词距连成行 → 图形笔画按距离合成图，图吸收落在它里面的行和贴着它的短标注；只是一个框或圈围着文字的算「加框的文字」→ 贴图吸收大部分落在它上面的行和伸到它上面的图（被同一笔墨迹连起来或互相重叠的贴图合成一个 figure）→ 剩下的行按行距合成段落（阈值根据本画板的典型行距自适应，限制在 0.8h–1.8h）→ 阅读顺序用递归 XY-cut，先上下后左右，图注（图下方紧挨着的 1–2 行文字）排在它的图后面。
- 两个公式线索：分数线，和「=」（按书写顺序连续的两条短横、互相平行重叠、间距适中，并且两横之间以及上下各一个间距内没有别的墨迹，这样「三」「言」之类不会被当成等号；单独的「二」仍会误判）。含分数线或「=」的行猜作公式行。上标（偏高）和下标（偏低）与所在行的竖直重叠不够，作为「小碎片」（不超过约 1.5h）并入 0.5h 以内最近的行。
- 每行有类型 `InkLine.kind`（text / formula）：`Board.labels` 里有标签就用标签，否则用上面的猜测。段落在行的类型变化处拆开，所以「文字行 + 公式行」会变成文字块和公式块。图形块同样可以用标签改类型（包括改成 formula / text）。`drawing` / `diagram` 的猜测：有标注或直线多就算示意图。
- `Board.labels`：键是一个单元（一行，或一个没有行的块）的笔画 id 集合，值是类型。来源是「转换 → 识别分块类型」（`BlockLabeling`）：按全局转换的页面渲染，每行用红框和 L1、L2… 标出，每个图形用 G1… 标出（阅读顺序），连同固定提示词（`BlockLabeling.prompt`，不可在设置里改，因为它规定了回答格式）发给全局转换的模型，回答是 `{"L1":"text","G1":"diagram"}` 这样的 JSON，由 `BlockLabeling.parse` 读取（容忍代码块、大小写，跳过未知编号和不合适的类型）。结果整体替换 `labels`，经 `CanvasView.setLabels` 提交，可撤销、随文稿存储。墨迹改动后对不上的标签自动失效；全局转换和导出 PDF 直接使用已有标签，不会自动发起识别。
- `PageAssembler.pages` 按阅读顺序贪心装页，块不拆开；超过一页的文字块按行拆，其他超大的块单独一页（渲染时缩小）。内容宽度不超过页面上限时，所有页共用同一个水平范围。
- 调参时打开「显示 → 显示分块」（`CanvasView.showsBlocks`，UserDefaults 键 `canvas.showsBlocks`，默认关）：画出每个块（按类型着色、按阅读顺序编号、figure 的子块编号为 3.1 这样）、每行的范围，以及全局转换的页面（虚线）。结果缓存在画布里，画板一变就重算。
- 自检里有合成笔迹的生成函数（`glyph`、`textLine`、`paragraph`、`fractionFormula`、`equalsSign`、`hanLine`、`circle`、`rectangle`），新增分块规则时用它们写用例；`describe(blocks)` 输出块的简要结构，方便看失败原因。
- 真实笔迹样本放在 `test/` 下（目前是 `test/未命名.inkboard`：三行公式、坐标图、一行中文、一行公式，含上标 ᵀ 和下标 j），自检按 `#filePath` 找到它并检查分块结果（缺文件时跳过）。改分块规则后先确认它仍然通过。

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
- 测试 AI 转换时：局部转换会改写系统剪贴板，测试前保存、结束后恢复；真实请求会消耗用户 agent 账号的额度，能用 InkboardCheck 里的模拟 agent 验证的就不要发真实请求。
