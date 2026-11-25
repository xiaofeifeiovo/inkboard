import Foundation

// MARK: - 分块方式 and AI segmentation

/// 分块方式 (设置): how the board is split into blocks.
public enum SegmentationMode: String, CaseIterable {
    /// Geometry only (`InkLayout`), on this Mac, as you write.
    case geometric
    /// Geometry while writing, corrected by the AI on request (「AI 识别分块」, stored in `Board.groups`).
    case aiAssisted
    /// A dedicated ink segmentation model. Not available yet: shown disabled in 设置.
    case model
}

/// AI segmentation: the same tagged pages as `BlockLabeling` (L1… lines, G1… drawings), but the
/// model groups the units into blocks — a paragraph, a formula or derivation over several lines, a
/// drawing with its labels — and names each block's kind. The answer becomes `Board.groups`.
/// Units are the smallest pieces: the AI can join them, not split them.
public enum BlockSegmentation {
    /// The prompt (`BlockSegmentation.prompt`, in BlockSegmentationPrompt.swift), then each page.
    public static func parts(_ request: BlockLabeling.Request) -> [PromptPart] {
        var parts: [PromptPart] = [.text(prompt)]
        for (i, page) in request.pages.enumerated() {
            parts.append(.text("第 \(i + 1)/\(request.pages.count) 页："))
            parts.append(.png(page.pngData))
        }
        return parts
    }

    /// Reads `{"blocks": [{"units": ["L1", "L2"], "kind": "formula"}, …]}` into groups (each the
    /// union of its units' strokes). Lenient like `BlockLabeling.parse`: fences, prose around the
    /// JSON, tag case. Unknown tags and kinds are skipped; a unit claimed twice stays with its
    /// first group; units not mentioned get no group (geometry decides for them). Throws
    /// `BlockLabeling.LabelingError.unreadableReply` when no JSON object can be read.
    public static func parse(_ reply: String, units: [BlockLabeling.Unit]) throws -> [BlockGroup] {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8))) as? [String: Any] else {
            throw BlockLabeling.LabelingError.unreadableReply(reply)
        }
        let byTag = Dictionary(units.map { ($0.tag, $0.ids) }, uniquingKeysWith: { first, _ in first })
        var claimed = Set<String>()
        var groups: [BlockGroup] = []
        for case let block as [String: Any] in object["blocks"] as? [Any] ?? [] {
            guard let name = block["kind"] as? String,
                  let kind = InkBlock.Kind(rawValue: name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
                  [.text, .formula, .diagram, .drawing].contains(kind),
                  let tags = block["units"] as? [Any] else { continue }
            var ids = Set<UUID>()
            for case let raw as String in tags {
                let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if let strokes = byTag[tag], claimed.insert(tag).inserted { ids.formUnion(strokes) }
            }
            if !ids.isEmpty { groups.append(BlockGroup(ids: ids, kind: kind)) }
        }
        return groups
    }
}
