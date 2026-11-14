import AppKit

enum PanelAction: Equatable {
    case settings, refresh, openList, retryCompletion
}

/// The same explanation is used by Day, Month, Demo fixtures and accessibility.
struct PanelMessage: Equatable {
    let title: String
    let detail: String
    var action: PanelAction? = nil
    var actionTitle: String? = nil

    func height(width: CGFloat, compact: Bool = false) -> CGFloat {
        let titleSize: CGFloat = compact ? 12 : 13
        let detailSize: CGFloat = compact ? 11 : 12
        func textHeight(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
            ceil((text as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).height) + 2
        }
        return textHeight(title, size: titleSize, weight: .semibold) + 5
            + textHeight(detail, size: detailSize, weight: .regular)
            + (action == nil ? 0 : 8 + 28)
    }
}

/// Deliberate completion has three beats: acknowledge, move, settle.
enum CompletionTiming {
    static let acknowledge: UInt64 = 100_000_000
    static let fadeOut: UInt64 = 60_000_000
    static let movement: Double = 0.18
    static let protection: UInt64 = 120_000_000
    static let spinnerDelay: UInt64 = 180_000_000
}
