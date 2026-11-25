import Foundation

// The fixed prompt of AI segmentation (分块方式「AI 辅助」). The answer format is part of the
// contract with `BlockSegmentation.parse`.

extension BlockSegmentation {
    /// Fixed (not a setting): the answer format is part of the contract with `parse`.
    public static let prompt = """
        这些图片是同一份手写笔记，按阅读顺序分成了几页。图中用红色方框和编号标出了各个单元（L 开头如 L3 是一行书写，G 开头如 G2 是一块图形）；红框和编号只是位置标记，不是笔记内容。

        请把这些编号单元分组成块，并给出每个块的类型：
        - 什么算一个块：一个文字段落（可能有多行）、一个独立公式或一段多行推导（例如以「=」开头接着上一行写的行，与上一行属于同一个推导）、一张图（连同贴在它旁边的标注）。同一个段落、公式或图被拆成多个编号时，合并成一个块。
        - 不要把意思上无关的内容合在一起；左右分栏的内容属于不同的块，不要跨栏合并。
        - 每个编号恰好属于一个块，所有编号都要给出；单元只能合并，不能拆开。
        - 块按阅读顺序列出。

        每个块的 kind 只能是以下四个值之一：
        - text：文字段落（可以夹带行内公式，包括被标成 G 的文字）。
        - formula：单独成行的数学公式或多行推导（包括被标成 G 的大公式、矩阵等）。
        - drawing：手绘图、草图。
        - diagram：示意图、流程图、坐标图、表格等由线条和标注组成的图。

        只输出一个 JSON 对象，格式严格如下：
        {"blocks": [{"units": ["L1"], "kind": "text"}, {"units": ["L2", "L3"], "kind": "formula"}, {"units": ["G1"], "kind": "diagram"}]}
        不要用代码块包起来，不要输出其他内容，不要调用任何工具。
        """
}
