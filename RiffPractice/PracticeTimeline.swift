import SwiftUI

struct PracticeTimeline: View {
    let duration: Double
    let playhead: Double
    let sections: [LoopRange]
    let activeSection: LoopRange?
    let sectionName: String?
    let canSeek: Bool
    let seek: (Double) -> Void
    let editRange: LoopRange?
    let changeRange: (LoopRange, Double, Bool) -> Void

    @GestureState private var preview: Double?
    @State private var draggedRange: LoopRange?

    private let inset = 10.0
    private var displayedTime: Double { preview ?? playhead }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let width = proxy.size.width
                Canvas { context, _ in
                    let trackY = 15.0
                    let playheadX = position(displayedTime, width: width)
                    let track = CGRect(x: inset, y: trackY, width: max(1, width - 2 * inset), height: 4)
                    context.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(.secondary.opacity(0.22)))
                    let progress = CGRect(x: inset, y: trackY, width: max(0, playheadX - inset), height: 4)
                    context.fill(Path(roundedRect: progress, cornerRadius: 2), with: .color(.accentColor))

                    for section in sections {
                        let first = position(section.start, width: width)
                        let last = position(section.end, width: width)
                        let isActive = section == activeSection
                        let color = Color.accentColor.opacity(isActive ? 1 : 0.56)
                        let span = CGRect(x: first, y: 27, width: max(1, last - first), height: 7)
                        context.fill(Path(roundedRect: span, cornerRadius: 3), with: .color(color.opacity(isActive ? 0.52 : 0.28)))
                        var stem = Path()
                        stem.move(to: CGPoint(x: first, y: 21))
                        stem.addLine(to: CGPoint(x: first, y: 28))
                        context.stroke(stem, with: .color(color), lineWidth: 1.5)
                        let marker = CGRect(x: first - 3, y: 28, width: 6, height: 6)
                        context.fill(Path(ellipseIn: marker), with: .color(color))
                    }

                    let thumb = CGRect(x: playheadX - 5, y: trackY - 3, width: 10, height: 10)
                    context.fill(Path(ellipseIn: thumb), with: .color(.accentColor))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($preview) { value, preview, _ in
                            if canSeek { preview = time(at: value.location.x, width: width) }
                        }
                        .onEnded { value in
                            guard canSeek else { return }
                            let target = time(at: value.location.x, width: width)
                            let isMarkerTap = abs(value.translation.width) < 4 && value.location.y >= 21
                            let nearest = sections.map(\.start).min { abs($0 - target) < abs($1 - target) }
                            if isMarkerTap, let nearest, abs(position(nearest, width: width) - value.location.x) <= 8 {
                                seek(nearest)
                            } else {
                                seek(target)
                            }
                        }
                )
                if let range = draggedRange ?? editRange {
                    let first = position(range.start, width: width)
                    let last = position(range.end, width: width)
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: max(1, last - first), height: 8)
                        .position(x: (first + last) / 2, y: 77)
                        .allowsHitTesting(false)
                    endpointHandle(isStart: true, range: range, width: width)
                        .position(x: first, y: 55)
                    endpointHandle(isStart: false, range: range, width: width)
                        .position(x: last, y: 100)
                }
            }
            .frame(height: editRange == nil ? 44 : 124)
            .coordinateSpace(name: "practiceTimeline")
            .focusable(canSeek)
            .onKeyPress(.leftArrow) { adjust(by: -5) }
            .onKeyPress(.rightArrow) { adjust(by: 5) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Practice timeline")
            .accessibilityValue(label(for: displayedTime))
            .accessibilityHint("Adjusts playback position by five seconds.")
            .accessibilityAdjustableAction { direction in
                if direction == .increment { _ = adjust(by: 5) }
                if direction == .decrement { _ = adjust(by: -5) }
            }

            HStack(spacing: 8) {
                Text(label(for: displayedTime)).monospacedDigit()
                Spacer(minLength: 0)
                if let sectionName, preview == nil {
                    Label(sectionName, systemImage: "bookmark.fill")
                        .lineLimit(1)
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
                Text(label(for: duration)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, inset)
        }
        .onChange(of: editRange) { if editRange == nil { draggedRange = nil } }
    }

    private func endpointHandle(isStart: Bool, range: LoopRange, width: Double) -> some View {
        Text(isStart ? "A" : "B")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 24, height: 28)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5))
            .frame(width: 34, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("practiceTimeline"))
                    .onChanged { value in
                        guard canSeek, let original = editRange else { return }
                        let target = time(at: value.location.x, width: width)
                        let updated = isStart ? original.movingStart(to: target, duration: duration) :
                            original.movingEnd(to: target, duration: duration)
                        if let updated {
                            draggedRange = updated
                            changeRange(updated, isStart ? updated.start : updated.end, false)
                        }
                    }
                    .onEnded { _ in
                        if let draggedRange { changeRange(draggedRange, isStart ? draggedRange.start : draggedRange.end, true) }
                        draggedRange = nil
                    }
            )
            .accessibilityLabel(isStart ? "Section start A" : "Section end B")
            .accessibilityValue(label(for: isStart ? range.start : range.end))
            .accessibilityAdjustableAction { direction in
                guard canSeek else { return }
                let delta = direction == .increment ? 0.1 : -0.1
                let updated = isStart ? range.movingStart(to: range.start + delta, duration: duration) :
                    range.movingEnd(to: range.end + delta, duration: duration)
                if let updated { changeRange(updated, isStart ? updated.start : updated.end, true) }
            }
    }

    private func position(_ time: Double, width: Double) -> Double {
        inset + min(max(time / duration, 0), 1) * max(1, width - inset * 2)
    }

    private func time(at x: Double, width: Double) -> Double {
        min(max((x - inset) / max(1, width - inset * 2), 0), 1) * duration
    }

    private func adjust(by seconds: Double) -> KeyPress.Result {
        guard canSeek else { return .ignored }
        seek(min(max(playhead + seconds, 0), duration))
        return .handled
    }

    private func label(for time: Double) -> String {
        let wholeSeconds = Int(max(0, time.rounded(.down)))
        let seconds = wholeSeconds % 60
        return "\(wholeSeconds / 60):\(seconds < 10 ? "0" : "")\(seconds)"
    }
}
