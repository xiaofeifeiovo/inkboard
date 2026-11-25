import Foundation

// MARK: - 自动检查: prompts
//
// Fixed (not settings): the answer formats are part of the contract with `AutoCheckReply`.
// How the pieces are put together is described on each one; `AutoChecker` assembles the requests.

public enum AutoCheckPrompts {
    // MARK: Private helpers

    private static let jsonOnlyOutputRule =
        "只输出上面的 JSON 对象，不要用代码块包起来，不要输出任何额外说明，不要调用任何工具。"

    private static let pageTranscriptionFormat = """
        页转写的 Markdown 要求：
        - 必须照原样转写这一页的全部内容，不要改正笔迹中的任何错误（公式写错、符号遗漏、推导错误等都要如实保留，后续检查会以这份转写为依据）。
        - 图中的红框和块号（如 B1、B2）只是位置标记，不要把它们转写成正文。
        - 按阅读顺序输出；每个标有块号的块，在其内容前单独加一行块号注释，例如：
        \(AutoCheckReply.blockComment("B12"))
        - 忠实保留原文语言和内容，按结构使用标题、列表、表格；数学公式写成 LaTeX，行内用 $…$，独立成行用 $$…$$。
        - 看不清的字写成 [?]；图形、草图或贴图（连同上面的手写批注要点）用一句话概括，写成「> 图：…」，不要逐字抄录截图里的文字。
        """

    private static func tagList(_ tags: [String]) -> String {
        tags.joined(separator: "、")
    }

    // MARK: Shared

    /// The rules every check follows.
    public static let rules = """
        你的任务是检查手写笔记中的错误。请遵守以下规则：
        - 只判断本次明确指定的块；其他块、前面各页的内容以及贴图中的印刷文字都只作为上下文，不要输出在结果里。
        - 严重程度（severity）只有两种：
          - "error"：严重错误，会影响后续推导或结论（例如公式写错、定义错误、计算或逻辑错误）。
          - "warning"：描述或写法不准确但不算严重（例如漏写下标、轻微笔误但意思清楚）。
        - 如果一个块没有问题，它的 issues 为空数组 []。
        - 前面已经标出的错误，由它直接推出的后续结果不要重复报错；若后续块本身引入了新错误，仍需指出。
        - 如果问题和前面某个块有关（例如与前面的定义、前提或结论矛盾），在 related 里写出那个块的块号（如 ["B5"]）；无关则写 []。
        - 笔迹模糊、看不清写的是什么时，不要判为错误。
        - reading 填写你实际读到的该块内容，数学公式用 LaTeX 表示，方便用户核对是否认错字。
        - 不要调用任何工具。
        """

    /// The JSON answer of a check.
    public static let checkAnswerFormat = #"""
        检查结果的 JSON 格式如下：
        {"blocks": [{"id": "B12", "reading": "读到的内容（公式用 LaTeX）", "issues": [{"severity": "error", "summary": "一句话说明问题", "detail": "说明哪一行、哪里错了、为什么以及应该怎样", "related": ["B5"]}]}]}
        要求：
        - 本次指定要判断的每一个块都必须出现在 blocks 里，id 必须与给出的块号一致（如 "B12"）。
        - 没有问题时 issues 写 []；没有相关块时 related 写 []。
        - JSON 必须合法：字符串里的反斜杠要写成两个（例如 LaTeX 的 \frac 要写成 \\frac）。
        """#

    // MARK: Page conversation (one multi-turn conversation per open page)

    /// First text of a page conversation.
    public static let conversationIntro = """
        这是一个多轮对话，用来逐步检查同一页手写笔记里的各个块。每一轮我会发给你一个新写完的块、一个修改后的块，或标有红框与块号（如 B1、B2）的整页图片；红框和块号只是位置标记，不是笔记内容。前面各页的内容会以 Markdown 给出（块号写在各块前的 \(AutoCheckReply.blockComment("B1")) 注释里），当前页此前已检查的块也会附在上下文中。

        \(rules)

        \(checkAnswerFormat)

        每轮都\(jsonOnlyOutputRule)
        """

    /// Followed by the Markdown of the fixed pages before this one.
    public static let previousPagesHeading = "以下是已整理各页的笔记内容（按页顺序排列，各块前以注释标出块号）："

    /// Followed by blocks of this page checked earlier, each as `blockLabel`, its image and `previousVerdict`.
    public static let checkedBlocksHeading = "以下是当前页之前已经检查过的块及其当时的检查结果（仅作上下文，除非后面明确要求重新检查，否则不要输出在结果里）："

    /// Text right before a block image ("B3：").
    public static func blockLabel(_ tag: String) -> String { "\(tag)：" }

    /// After a re-sent block image: the earlier verdict; `json` is that block's object in the answer format.
    public static func previousVerdict(_ json: String) -> String { "此块之前的检查结果：\(json)" }

    /// Asks to check one newly finished block; its image follows.
    public static func checkBlock(_ tag: String) -> String {
        "下面图片是新写完的块 \(tag)。请只判断 \(tag)，按上述 JSON 格式输出结果："
    }

    /// The block was edited or extended: its earlier version is void. Check it again (new image follows),
    /// and re-judge `later` (already sent in this conversation) in the light of the change.
    public static func recheckBlock(_ tag: String, later: [String]) -> String {
        let other = later.filter { $0 != tag }
        if other.isEmpty {
            return "块 \(tag) 已经修改或补充了内容，它之前的版本和检查结果全部作废。下面图片是 \(tag) 的最新内容。请只重新判断 \(tag)，按上述 JSON 格式输出结果："
        }
        let laterList = tagList(other)
        let targets = tagList([tag] + other)
        return "块 \(tag) 已经修改或补充了内容，它之前的版本和检查结果全部作废。下面图片是 \(tag) 的最新内容。请根据新图片重新判断 \(tag)，并结合这一改动重新判断本对话中之前发过图片的后续块 \(laterList)（它们之前的检查结果也作废）。将 \(targets) 全部写入 JSON 的 blocks 数组并按上述格式输出："
    }

    /// Checks every tagged block on the page image that follows; the page stays open.
    public static func checkPage(_ tags: [String]) -> String {
        if tags.isEmpty {
            return "下面图片是当前页，本页没有需要判断的块。请只输出 {\"blocks\": []}。"
        }
        let list = tagList(tags)
        return "下面图片是当前页，图中用红框和块号标出了各个块。请只判断以下块：\(list)（图上若还有其他块号，仅作上下文，不要输出在结果里）。将 \(list) 全部写入 JSON 的 blocks 数组并按上述格式输出："
    }

    // MARK: Independent requests

    /// Start of a page request: check the tagged blocks on a page AND transcribe it.
    public static let pageRequestIntro = """
        下面会给你一页手写笔记的图片（如有前面各页，会附带它们的转写作为上下文）。图中用红框和块号（如 B1、B2）标出了各个块。你需要同时完成两件事：检查指定的块，并把这一页完整转写成 Markdown。

        \(rules)

        \(checkAnswerFormat)

        \(pageTranscriptionFormat)

        回答格式（严格按顺序输出以下三部分，不要用代码块包起来，不要附加任何说明，不要调用任何工具）：
        1. 先输出检查结果的 JSON 对象。
        2. 接着单独一行输出：
        \(AutoCheckReply.pageMarker)
        3. 然后输出这一页完整的 Markdown 转写。
        """

    /// Which blocks to judge on the page image that follows; `modified` were edited since last checked.
    public static func checkAndTranscribePage(_ tags: [String], modified: [String]) -> String {
        var lines: [String] = []
        if tags.isEmpty {
            lines.append("下面图片是这一页的完整内容，图中用红框和块号标出了各个块。本页没有需要判断的块，JSON 部分输出 {\"blocks\": []} 即可。")
        } else {
            let list = tagList(tags)
            lines.append("下面图片是这一页的完整内容，图中用红框和块号标出了各个块。请只判断以下块：\(list)（图上若还有其他块号，只转写、不要放进 JSON 的 blocks 里）。")
        }
        if !modified.isEmpty {
            lines.append("其中 \(tagList(modified)) 已经修改过，之前对它们的检查结果全部作废，请按最新图片重新判断。")
        }
        lines.append("请按上述格式先输出 JSON，再单独一行输出 \(AutoCheckReply.pageMarker)，最后输出这一页完整的 Markdown 转写（包含图上所有块，每个标有块号的块前加如 \(AutoCheckReply.blockComment("B12")) 的注释）：")
        return lines.joined(separator: "\n")
    }

    /// Appended to the 全局转换 prompt (from 设置) to transcribe a page that is being fixed; the page image follows.
    public static let transcriptionRequirements = """
        补充要求（本次只转写下面这一页图片）：
        - 图中用红框和块号（如 B1、B2）标出了各个块；红框和块号只是位置标记，不要把它们转写成正文。
        - 按阅读顺序输出；每个标有块号的块，在其内容前单独加一行块号注释，例如：
        \(AutoCheckReply.blockComment("B12"))
        - 必须照原样转写，不要改正笔迹中的任何错误（公式写错、符号遗漏、推导错误等都要如实保留，后续检查会以这份转写为依据）。
        - 仍然只输出 Markdown（包含上述块号注释），不要用代码块包起来，不要附加说明，不要调用任何工具。
        """

    /// Start of a text-only request re-judging later blocks after an earlier page changed.
    public static let recheckLaterIntro = """
        前面某页的手写笔记刚刚被修改过。下面按顺序列出已整理各页的最新 Markdown 转写（以及当前页已检查块的识别内容，如有），不附带图片。请你仅根据这些文字内容，重新判断指定的后续块。

        \(rules)

        \(checkAnswerFormat)
        - 本次没有图片，reading 可直接依据上面对应块的转写或识别内容填写（公式用 LaTeX）。

        \(jsonOnlyOutputRule)
        """

    /// Followed by "Bn：reading" lines: blocks of the open page, which have no transcription yet.
    public static let readingsHeading = "以下是当前页已检查块的识别内容（尚未整理成页转写，每行开头为块号）："

    /// Which blocks to re-judge; the blocks in `changed` are the ones that were edited.
    public static func recheckLater(_ tags: [String], changed: [String]) -> String {
        if tags.isEmpty {
            return "没有需要重新判断的块。请只输出 {\"blocks\": []}。"
        }
        let list = tagList(tags)
        if changed.isEmpty {
            return "请根据上面的最新文字内容，重新判断以下块：\(list)（这些块之前的检查结果作废）。只判断这些块，将它们全部写入 JSON 的 blocks 数组并按上述格式输出。"
        }
        return "前面的块 \(tagList(changed)) 已经修改，请结合这一改动与上面的最新文字内容，重新判断以下块：\(list)（这些块之前的检查结果作废）。只判断这些块，将它们全部写入 JSON 的 blocks 数组并按上述格式输出。"
    }
}
