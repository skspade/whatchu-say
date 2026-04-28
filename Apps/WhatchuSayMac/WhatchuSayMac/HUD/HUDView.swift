import SwiftUI

/// SwiftUI content of the HUD panel. Material backdrop, pulsing recording
/// indicator, segmented RMS-driven level meter, and animated state
/// transitions.
struct HUDView: View {
    let state: HUDState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            indicator
                .padding(.top, 4)
            Text(primaryText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textColor)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            levelMeter
                .padding(.top, 2)
                .opacity(showsLevelMeter ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: showsLevelMeter)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                if isErrorState {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.red.opacity(0.15))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(width: 440)
        .animation(.easeInOut(duration: 0.18), value: indicatorColor)
        .animation(.easeInOut(duration: 0.18), value: textColor)
    }

    // MARK: - Indicator (pulsing dot during active capture, steady otherwise)

    private var indicator: some View {
        PulsingDot(
            color: indicatorColor,
            isPulsing: indicatorPulsing
        )
        .frame(width: 10, height: 10)
    }

    // MARK: - Segmented level meter

    private var levelMeter: some View {
        let level = currentLevel
        let activeBars = Int(round(Double(max(0, min(1, level))) * Double(LevelMeter.barCount)))
        return LevelMeter(activeBars: activeBars)
    }

    // MARK: - Derived display values

    private var primaryText: String {
        switch state.status {
        case .hidden: return ""
        case .listening: return "Listening…"
        case .active(let partial, _): return partial.isEmpty ? "Listening…" : partial
        case .finalizing(let last): return last.isEmpty ? "Finalizing…" : last
        case .error(let text): return text
        }
    }

    private var indicatorColor: Color {
        switch state.status {
        case .finalizing: return .orange
        case .error: return .red
        default: return .red
        }
    }

    private var indicatorPulsing: Bool {
        switch state.status {
        case .listening, .active: return true
        case .finalizing, .error, .hidden: return false
        }
    }

    private var textColor: Color {
        switch state.status {
        case .finalizing: return .secondary
        case .error: return .red
        default: return .primary
        }
    }

    private var borderColor: Color {
        if isErrorState { return Color.red.opacity(0.4) }
        return Color.white.opacity(0.08)
    }

    private var isErrorState: Bool {
        if case .error = state.status { return true }
        return false
    }

    private var showsLevelMeter: Bool {
        switch state.status {
        case .active, .listening: return true
        default: return false
        }
    }

    private var currentLevel: Float {
        if case .active(_, let level) = state.status { return level }
        return 0
    }
}

// MARK: - PulsingDot

private struct PulsingDot: View {
    let color: Color
    let isPulsing: Bool
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 1.0

    var body: some View {
        Circle()
            .fill(color)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                if isPulsing { startPulse() } else { resetPulse() }
            }
            .onChange(of: isPulsing) { _, nowPulsing in
                if nowPulsing { startPulse() } else { resetPulse() }
            }
    }

    private func startPulse() {
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            scale = 1.3
            opacity = 0.55
        }
    }

    private func resetPulse() {
        withAnimation(.easeInOut(duration: 0.2)) {
            scale = 1.0
            opacity = 1.0
        }
    }
}

// MARK: - LevelMeter

private struct LevelMeter: View {
    static let barCount = 7

    let activeBars: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index < activeBars ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: barHeight(at: index))
                    .animation(.easeOut(duration: 0.08), value: activeBars)
            }
        }
        .frame(width: 60, height: 16, alignment: .center)
    }

    /// Slight upward arc — middle bars taller than edges. Cosmetic.
    private func barHeight(at index: Int) -> CGFloat {
        let mid = Double(Self.barCount - 1) / 2
        let distance = abs(Double(index) - mid)
        let factor = 1 - (distance / mid) * 0.3
        return 16 * CGFloat(factor)
    }
}
