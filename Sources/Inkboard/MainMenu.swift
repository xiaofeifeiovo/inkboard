import AppKit

/// Builds the menu bar in code (no nib). Actions travel the responder chain:
/// CanvasView → NSWindow (undo/redo) → MainWindowController.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        main.addSubmenu("Inkboard") { menu in
            menu.addItem(withTitle: "关于 Inkboard", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "设置…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
            menu.addItem(.separator())
            menu.addItem(withTitle: "隐藏 Inkboard", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            menu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
                .keyEquivalentModifierMask = [.command, .option]
            menu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 Inkboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }

        // Document commands go to NSDocumentController / the front BoardDocument via the responder chain.
        main.addSubmenu("文件") { menu in
            menu.addItem(withTitle: "新建", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
            menu.addItem(withTitle: "打开…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
            let recent = menu.addItem(withTitle: "打开最近使用", action: nil, keyEquivalent: "")
            // NSDocumentController fills in a submenu that contains a clearRecentDocuments: item.
            recent.submenu = NSMenu(title: "打开最近使用")
            recent.submenu?.addItem(withTitle: "清除菜单", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            menu.addItem(withTitle: "存储…", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
            menu.addItem(withTitle: "复制", action: #selector(NSDocument.duplicate(_:)), keyEquivalent: "s")
                .keyEquivalentModifierMask = [.command, .shift]
            let saveAs = menu.addItem(withTitle: "存储为…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
            saveAs.keyEquivalentModifierMask = [.command, .shift, .option]
            saveAs.isAlternate = true   // shown in place of 复制 while ⌥ is held
            menu.addItem(withTitle: "重新命名…", action: #selector(NSDocument.rename(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "移到…", action: #selector(NSDocument.move(_:)), keyEquivalent: "")
            menu.addSubmenu("复原到") { revert in
                revert.addItem(withTitle: "上次存储的版本", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
                revert.addItem(withTitle: "浏览所有版本…", action: #selector(NSDocument.browseVersions(_:)), keyEquivalent: "")
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "导出 PNG…", action: #selector(MainWindowController.exportPNG(_:)), keyEquivalent: "e")
                .keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(withTitle: "导出 PDF…", action: #selector(MainWindowController.exportPDF(_:)), keyEquivalent: "e")
                .keyEquivalentModifierMask = [.command, .shift, .option]
            menu.addItem(.separator())
            menu.addItem(withTitle: "清空画布", action: #selector(MainWindowController.clearBoard(_:)), keyEquivalent: "")
        }

        main.addSubmenu("编辑") { menu in
            menu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
            menu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
                .keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(.separator())
            // Standard items (text fields in 设置 need them too). The canvas only pastes pictures.
            menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            menu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            menu.addItem(withTitle: "插入图片…", action: #selector(MainWindowController.insertImage(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "全选", action: #selector(CanvasView.selectAll(_:)), keyEquivalent: "a")
            menu.addItem(withTitle: "删除所选（⌫）", action: #selector(CanvasView.delete(_:)), keyEquivalent: "")
        }

        main.addSubmenu("工具") { menu in
            for tool in Tool.allCases {
                // Shortcuts are single keys handled by the canvas; shown in the title only, because
                // bare-key menu equivalents would also swallow typing in text fields.
                let item = menu.addItem(withTitle: "\(tool.title)（\(tool.shortcut.uppercased())）",
                                        action: #selector(MainWindowController.selectTool(_:)), keyEquivalent: "")
                item.tag = tool.rawValue
            }
            menu.addItem(.separator())
            for width in PenWidth.allCases {
                let item = menu.addItem(withTitle: "笔宽：\(width.title)",
                                        action: #selector(MainWindowController.selectPenWidth(_:)), keyEquivalent: "")
                item.tag = width.rawValue
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "按住空格拖动可平移画布", action: nil, keyEquivalent: "").isEnabled = false
        }

        main.addSubmenu("转换") { menu in
            menu.addItem(withTitle: "局部转换：公式 → LaTeX", action: #selector(MainWindowController.toggleFormulaCapture(_:)), keyEquivalent: "l")
                .keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(withTitle: "全局转换：画板 → Markdown", action: #selector(MainWindowController.convertDocument(_:)), keyEquivalent: "m")
                .keyEquivalentModifierMask = [.command, .shift]
            // 识别分块类型 (本地计算) or AI 识别分块 (AI 辅助): see LayoutSettings.
            menu.addItem(withTitle: LayoutSettings.recognizeTitle, action: #selector(MainWindowController.recognizeBlocks(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "自动检查", action: #selector(MainWindowController.toggleAutoCheck(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "检查最新的块", action: #selector(MainWindowController.checkLatestBlock(_:)), keyEquivalent: "k")
                .keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(.separator())
            menu.addItem(withTitle: "AI 设置…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: "")
        }

        main.addSubmenu("显示") { menu in
            menu.addItem(withTitle: "放大", action: #selector(MainWindowController.zoomIn(_:)), keyEquivalent: "=")
            menu.addItem(withTitle: "缩小", action: #selector(MainWindowController.zoomOut(_:)), keyEquivalent: "-")
            menu.addItem(withTitle: "实际大小", action: #selector(MainWindowController.actualSize(_:)), keyEquivalent: "0")
            menu.addItem(.separator())
            menu.addItem(withTitle: "显示点格", action: #selector(AppDelegate.toggleDotGrid(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "显示分块", action: #selector(AppDelegate.toggleBlocks(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
                .keyEquivalentModifierMask = [.command, .control]
        }

        let windowMenu = main.addSubmenu("窗口") { menu in
            menu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            menu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        }
        NSApp.windowsMenu = windowMenu

        return main
    }
}

extension MainMenu {
    /// Retitles 转换 → 识别分块类型 / AI 识别分块 for the current 分块方式.
    static func updateSegmentationItem() {
        guard let menu = NSApp?.mainMenu else { return }
        for item in menu.items {
            for sub in item.submenu?.items ?? [] where sub.action == #selector(MainWindowController.recognizeBlocks(_:)) {
                sub.title = LayoutSettings.recognizeTitle
            }
        }
    }
}

private extension NSMenu {
    @discardableResult
    func addSubmenu(_ title: String, build: (NSMenu) -> Void) -> NSMenu {
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = true
        build(submenu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
        return submenu
    }
}
