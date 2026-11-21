# AGENTS.md

给在本仓库工作的 AI 编码代理（Claude Code、Codex 等）的说明。本文件是唯一维护的项目说明；`CLAUDE.md` 只是引用它，项目说明的改动都写在这里。

Inkboard：轻量的 macOS 手写白板原型（类似 Freeform），纯 AppKit + Core Graphics，没有第三方依赖。界面文字（菜单、提示）是中文，代码和注释用英文。

## 命令

```bash
scripts/build.sh            # release 编译 + 打包 build/Inkboard.app（复制 Support/Info.plist、ad-hoc 签名、注册到 Launch Services）
scripts/build.sh debug      # debug 编译 + 打包
scripts/build.sh check      # 编译 + 运行自检，输出 build/sample.png（笔迹渲染样例，可以直接看图检查）
open build/Inkboard.app

swift build                 # SwiftPM 也能用
swift run Inkboard          # 不打包直接运行；Info.plist 通过链接参数嵌进可执行文件，文件存取同样可用
swift run InkboardCheck [out.png]
```

- 本机只有 Command Line Tools（Swift 6.0.3），没有 Xcode，因此也没有 XCTest。测试统一写在 `Sources/InkboardCheck/main.swift` 里，用 `check(条件, 描述)` 断言；运行时全部执行（很快），没有单项筛选；有失败时退出码非 0。
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

- `InkOps` 里是纯函数（擦除并切分、套索、点选、平移、插入空间），输入和输出都是 `[Stroke]`。
- `CanvasView` 持有 `strokes`，交互由 `Gesture` 枚举表示的状态机驱动，通过 `apply(_:actionName:)` 提交修改。撤销是整个数组的快照交换。
- 移动和插入空间在拖动过程中只做平移绘制，松开鼠标时才提交；橡皮擦边擦边改，松开时注册一次撤销。

### 文稿（`.inkboard`）

- 基于 NSDocument（`BoardDocument`），每个文件一个窗口（`MainWindowController`）。文件内容是 JSON：`{"version":1,"strokes":[{"id","width","points":[x,y,压力,…]}]}`，读写代码在 `BoardStore`。
- 文件类型声明在 `Support/Info.plist`：UTI `local.inkboard.board`，`NSDocumentClass` 为 `BoardDocument`（类上有 `@objc(BoardDocument)`，改名时两边要一起改）。这个 plist 是唯一来源：`build.sh` 把它复制进 .app，`Package.swift` 用 `-sectcreate __TEXT __info_plist` 把它嵌进 `swift run` 的可执行文件。
- 数据流：画布每次提交修改，都通过 `onContentChange` 把 `canvas.strokes` 同步到 `document.strokes`；`data(ofType:)` 写的是 `document.strokes`。`read(from:)` 也会重新加载画布，「复原」和「浏览版本」都走这里。
- **「已编辑」状态完全来自撤销注册**：窗口的 undoManager 就是文稿的 undoManager。新增的修改操作如果不注册撤销，文稿就不会被标记为已编辑，也不会自动存储。
- `AppDelegate.applicationShouldOpenUntitledFile` 里的 `LegacyBoard`：把旧版唯一的画板 `~/Library/Application Support/Inkboard/board.json` 作为未命名文稿导入一次，然后把它改名为 `board.imported.json`。

### 应用外壳

- 菜单在 `MainMenu.swift` 里用代码创建，必须在 `applicationWillFinishLaunching` 里设置，否则 NSDocumentController 认不出「打开最近使用」菜单。动作沿响应链传递：CanvasView → NSWindow（撤销/重做）→ MainWindowController → BoardDocument → NSDocumentController。
- 单键快捷键（P/E/L/S 切换工具、空格平移、⌫ 删除、Esc 取消选择）在 `CanvasView.keyDown` 里处理，不要做成不带修饰键的菜单快捷键，否则会吞掉文本框里的输入。
- 光标是全局的：只有指针在画布可见区域内时才设置工具光标，离开时还原成箭头。不要设置 `window.acceptsMouseMovedEvents`，这曾导致黑点光标在整个系统里残留；悬停事件来自画布自己的 tracking area。
- 画布尺寸只增不减：最小 3000×4000，在内容右侧和下方保留 1500 的余量。
- AI 转写接口：`InkboardCore/Transcription.swift` 中的 `HandwritingTranscriber` 协议。目前的实现是 `AppDelegate.transcriber` 里的 `UnconfiguredTranscriber`，只会报错。请求里带选区（没有选区就是整个画布）渲染出的 PNG 和原始笔画数据。

## 界面验证方法

本环境没有截屏权限（`screencapture` 会失败）。要在真实窗口里验证交互，做法如下：把 `Sources/Inkboard/*.swift`（不含 `main.swift`）和一个测试用 `main.swift` 一起编译成测试程序，在里面发送合成鼠标事件，再用 `cacheDisplay` 把窗口内容存成 PNG 查看。

```bash
O=build/obj   # 先运行 scripts/build.sh 生成
swiftc -Onone -target arm64-apple-macos13.0 -swift-version 5 -module-name Inkboard -I $O -L $O -lInkboardCore \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker harness/Info.plist \
  $(ls Sources/Inkboard/*.swift | grep -v main.swift) harness/main.swift -o harness/harness
```

- 合成事件用 `NSApp.postEvent` 送进事件队列，不要直接调用 `window.sendEvent`：绕过事件循环时撤销分组不会关闭，文稿就不会被标记为已编辑，测试结果会失真。
- 每个步骤放在单独的 run loop 轮次里执行（例如用 `asyncAfter` 串起来），否则所有撤销会被合并成一组。
- 测试程序嵌入的 Info.plist 要换一个 `CFBundleIdentifier`，避免往正式应用的「最近使用」列表里写东西；用完删掉它的偏好设置文件。
- 不要把文件路径作为命令行参数传给测试程序：AppKit 会把它当成要打开的文稿，弹出模态错误框卡住。需要传路径就用环境变量。
