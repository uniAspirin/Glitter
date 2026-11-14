import SwiftUI

/// 用户选定的 8 阶色卡，截图取色后转为 sRGB，从暗到亮。
enum Theme {
    static let paletteHex: [UInt32] = [0x352B01, 0x4F4000, 0x6A5504, 0x866A03,
                                      0x9F7F00, 0xBA9602, 0xD3AA04, 0xEEBF05]
    static let palette: [Color] = paletteHex.map { hex in
        Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255,
              green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: 1)
    }
    static let gold = palette[7]
    static let idle = Color(.sRGB, red: 20 / 255, green: 20 / 255, blue: 20 / 255, opacity: 1)
    static let blockStroke = Color.white.opacity(0.06)
    static let primary = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.50)
    static let tertiary = Color.white.opacity(0.30)

    /// Positive partial completion spans seven bands; only 100% receives level 7.
    /// Zero completion is rendered separately as neutral gray.
    static func level(for ratio: Double) -> Int {
        guard ratio.isFinite, ratio > 0 else { return 0 }
        guard ratio < 1 else { return 7 }
        return min(6, Int(ratio * 7))
    }

    static func ramp(_ ratio: Double) -> Color {
        guard ratio.isFinite, ratio > 0 else { return idle }
        return palette[level(for: ratio)]
    }
}

enum DayState: Equatable {
    case progress(Double)
    case idle
    case future

    init(stat: DayStat, isFuture: Bool = false) {
        self = isFuture ? .future : stat.done <= 0 || stat.due <= 0 ? .idle : .progress(stat.ratio)
    }
}

struct DayBlock: View {
    let state: DayState
    let size: CGFloat
    let radius: CGFloat
    var celebratesGold = true
    var isToday = false
    var celebrationToken = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isGolden: Bool {
        if case .progress(let ratio) = state { return ratio.isFinite && ratio >= 1 }
        return false
    }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.blockStroke, lineWidth: 0.5)
            )
            .overlay {
                if celebratesGold && isGolden {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Theme.gold.opacity(0.8), lineWidth: 0.8)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: celebratesGold && isGolden ? Theme.gold.opacity(0.75) : .clear, radius: 3)
            .shadow(color: celebratesGold && isGolden ? Theme.gold.opacity(0.6) : .clear, radius: 7)
            .phaseAnimator([0.0, 1.0, 0.0], trigger: celebrationToken) { content, phase in
                content.shadow(color: celebratesGold && isGolden && celebrationToken > 0 && !reduceMotion
                               ? Theme.gold.opacity(phase * 0.35) : .clear,
                               radius: phase * 5)
            } animation: { phase in
                reduceMotion ? .linear(duration: 0) : .easeInOut(duration: phase > 0 ? 0.16 : 0.42)
            }
            .overlay {
                if isToday {
                    Circle()
                        .fill(Color.white)
                        .frame(width: max(3, size * 0.20), height: max(3, size * 0.20))
                        .shadow(color: .black.opacity(0.3), radius: 0.8)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state)
    }

    private var fill: Color {
        switch state {
        case .progress(let ratio): return Theme.ramp(ratio)
        case .idle: return Theme.idle
        case .future: return Theme.idle
        }
    }
}

struct ScoreText: View {
    let numerator: String
    let denominator: String
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Text(numerator).foregroundStyle(Theme.primary)
                .contentTransition(.numericText(value: Double(numerator) ?? 0))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: numerator)
            Text("/").foregroundStyle(Theme.tertiary)
            Text(denominator).foregroundStyle(Theme.tertiary)
                .contentTransition(.numericText(value: Double(denominator) ?? 0))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: denominator)
        }
        .font(.system(size: size, weight: weight, design: .rounded))
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: true)
    }
}
