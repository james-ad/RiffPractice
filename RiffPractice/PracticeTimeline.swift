import SwiftUI

struct TimelineSection: Identifiable, Equatable {
    let id: String
    let name: String
    let range: LoopRange
}

enum TimelineEndpoint: String, CaseIterable {
    case start = "A"
    case end = "B"
    var row: Double { self == .start ? 22 : 86 }
    func time(in range: LoopRange) -> Double { self == .start ? range.start : range.end }
}

struct TimelineMarkerGroup: Identifiable {
    let endpoint: TimelineEndpoint
    var sections: [TimelineSection]
    var id: String { endpoint.rawValue + sections[0].id }
    var time: Double { endpoint.time(in: sections[0].range) }

    static func arrange(_ sections: [TimelineSection], duration: Double, width: Double) -> [Self] {
        guard duration > 0, duration.isFinite else { return [] }
        let scale = max(1, width - 48) / duration
        var result: [Self] = []
        for endpoint in TimelineEndpoint.allCases {
            let ordered = sections.sorted {
                (endpoint.time(in: $0.range), $0.id) < (endpoint.time(in: $1.range), $1.id)
            }
            for section in ordered {
                if let previous = result.last, previous.endpoint == endpoint,
                   (endpoint.time(in: section.range) - previous.time) * scale < 44 {
                    result[result.count - 1].sections.append(section)
                } else {
                    result.append(Self(endpoint: endpoint, sections: [section]))
                }
            }
        }
        return result
    }
}

struct TimelineFlag: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corner = min(rect.width * 0.2, 5)
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.height * 0.55),
                          control: CGPoint(x: rect.minX, y: rect.height * 0.8))
        path.addLine(to: CGPoint(x: rect.minX, y: corner))
        path.addQuadCurve(to: CGPoint(x: corner, y: rect.minY), control: .zero)
        path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: corner), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.55))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.height * 0.8))
        path.closeSubpath()
        return path
    }
}

struct PracticeTimeline: View {
    let duration: Double
    let playhead: Double
    let sections: [TimelineSection]
    let activeSection: LoopRange?
    let sectionName: String?
    let canSeek: Bool
    let seek: (Double) -> Void
    let editRange: LoopRange?
    let editingSectionID: String?
    let changeRange: (LoopRange, Double, Bool) -> Void
    let selectSection: (String, TimelineEndpoint) -> Void
    let availableWidth: Double

    @GestureState private var preview: Double?
    @State private var draggedRange: LoopRange?
    private let inset = 24.0
    private let trackY = 54.0

    var body: some View {
        let visible = sections.filter { editRange == nil || $0.id != editingSectionID }
        let groups = TimelineMarkerGroup.arrange(visible, duration: duration, width: availableWidth)
        return VStack(spacing: 2) {
            GeometryReader { proxy in
                let width = proxy.size.width
                Canvas { context, _ in
                    let track = CGRect(x: inset, y: trackY - 2, width: max(1, width - 2 * inset), height: 4)
                    context.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(.secondary.opacity(0.25)))
                    let playheadX = position(preview ?? playhead, width: width)
                    let progress = CGRect(x: inset, y: trackY - 2, width: max(0, playheadX - inset), height: 4)
                    context.fill(Path(roundedRect: progress, cornerRadius: 2), with: .color(.accentColor))
                    for section in visible {
                        let span = CGRect(x: position(section.range.start, width: width), y: trackY - 3,
                                          width: max(1, position(section.range.end, width: width) - position(section.range.start, width: width)),
                                          height: 6)
                        context.fill(Path(roundedRect: span, cornerRadius: 3),
                                     with: .color(.accentColor.opacity(section.range == activeSection ? 0.7 : 0.2)))
                    }
                    for group in groups {
                        drawStem(&context, time: group.time, endpoint: group.endpoint, width: width, selected: false)
                    }
                    if let range = draggedRange ?? editRange {
                        for endpoint in TimelineEndpoint.allCases {
                            drawStem(&context, time: endpoint.time(in: range), endpoint: endpoint, width: width, selected: true)
                        }
                    }
                    let thumb = CGRect(x: playheadX - 5, y: trackY - 5, width: 10, height: 10)
                    context.fill(Path(ellipseIn: thumb), with: .color(.accentColor))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($preview) { value, preview, _ in
                            if canSeek { preview = time(at: value.location.x, width: width) }
                        }
                        .onEnded { value in
                            if canSeek { seek(time(at: value.location.x, width: width)) }
                        }
                )
                ForEach(groups) { group in
                    markerButton(group)
                        .position(x: position(group.time, width: width), y: group.endpoint.row)
                }
                if let range = draggedRange ?? editRange {
                    ForEach(TimelineEndpoint.allCases, id: \.self) { endpoint in
                        endpointHandle(endpoint, range: range, width: width)
                            .position(x: position(endpoint.time(in: range), width: width), y: endpoint.row)
                    }
                }
            }
            .frame(height: 108)
            .coordinateSpace(name: "practiceTimeline")
            .focusable(canSeek)
            .onKeyPress(.leftArrow) { adjust(by: -5) }
            .onKeyPress(.rightArrow) { adjust(by: 5) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Practice timeline")
            .accessibilityValue(label(for: preview ?? playhead))
            .accessibilityAdjustableAction { direction in
                _ = adjust(by: direction == .increment ? 5 : -5)
            }
            HStack {
                Text(label(for: preview ?? playhead)).monospacedDigit()
                Spacer(minLength: 0)
                if let sectionName, preview == nil {
                    Text(sectionName).lineLimit(1).foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
                Text(label(for: duration)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 22)
            .padding(.horizontal, inset)
        }
        .onChange(of: editRange) { if editRange == nil { draggedRange = nil } }
    }

    private func drawStem(_ context: inout GraphicsContext, time: Double, endpoint: TimelineEndpoint,
                          width: Double, selected: Bool) {
        let markerX = position(time, width: width)
        let tipY = endpoint.row + (endpoint == .start ? 12 : -12)
        var path = Path()
        path.move(to: CGPoint(x: markerX, y: tipY))
        path.addLine(to: CGPoint(x: markerX, y: trackY))
        context.stroke(path, with: .color(.accentColor.opacity(selected ? 1 : 0.45)), lineWidth: selected ? 2 : 1)
    }

    @ViewBuilder
    private func markerButton(_ group: TimelineMarkerGroup) -> some View {
        if group.sections.count == 1, let section = group.sections.first {
            Button { selectSection(section.id, group.endpoint) } label: {
                flag(group.endpoint, count: 1, selected: section.range == activeSection)
            }
            .buttonStyle(.plain)
            .help("\(section.name) · \(group.endpoint.rawValue)")
            .accessibilityLabel("Edit \(group.endpoint == .start ? "start" : "end") of \(section.name)")
            .disabled(!canSeek)
        } else {
            Menu {
                ForEach(group.sections) { section in
                    Button(section.name) { selectSection(section.id, group.endpoint) }
                }
            } label: {
                flag(group.endpoint, count: group.sections.count, selected: false)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .accessibilityLabel("Choose \(group.endpoint.rawValue) marker")
            .disabled(!canSeek)
        }
    }

    private func flag(_ endpoint: TimelineEndpoint, count: Int, selected: Bool) -> some View {
        TimelineFlag()
            .fill(Color.accentColor.opacity(selected ? 1 : 0.7))
            .rotationEffect(endpoint == .end ? .degrees(180) : .zero)
            .frame(width: selected || count > 1 ? 26 : 20, height: selected ? 30 : 24)
            .overlay {
                Text(count > 1 ? "\(endpoint.rawValue)\(count)" : endpoint.rawValue)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(y: endpoint == .end ? 2 : -2)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func endpointHandle(_ endpoint: TimelineEndpoint, range: LoopRange, width: Double) -> some View {
        flag(endpoint, count: 1, selected: true)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("practiceTimeline"))
                    .onChanged { value in
                        guard canSeek, let original = editRange else { return }
                        let target = time(at: value.location.x, width: width)
                        let updated = endpoint == .start ? original.movingStart(to: target, duration: duration) :
                            original.movingEnd(to: target, duration: duration)
                        if let updated {
                            draggedRange = updated
                            changeRange(updated, endpoint.time(in: updated), false)
                        }
                    }
                    .onEnded { _ in
                        if let draggedRange { changeRange(draggedRange, endpoint.time(in: draggedRange), true) }
                        draggedRange = nil
                    }
            )
            .accessibilityLabel(endpoint == .start ? "Section start A" : "Section end B")
            .accessibilityValue(label(for: endpoint.time(in: range)))
            .accessibilityAdjustableAction { direction in
                guard canSeek else { return }
                let delta = direction == .increment ? 0.1 : -0.1
                let updated = endpoint == .start ? range.movingStart(to: range.start + delta, duration: duration) :
                    range.movingEnd(to: range.end + delta, duration: duration)
                if let updated { changeRange(updated, endpoint.time(in: updated), true) }
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
