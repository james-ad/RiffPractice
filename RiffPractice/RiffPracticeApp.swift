import SwiftData
import SwiftUI
import WebKit

@main
struct RiffPracticeApp: App {
    var body: some Scene {
        #if os(macOS)
        Window("RiffPractice", id: "practice") {
            SpikeView().frame(minWidth: 560, minHeight: 550)
        }
        .defaultSize(width: 1040, height: 760)
        .windowResizability(.contentMinSize)
        .modelContainer(for: PracticeRecord.self)
        #else
        WindowGroup {
            SpikeView()
        }
        .modelContainer(for: PracticeRecord.self)
        #endif
    }
}

private struct SpikeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var records: [PracticeRecord]
    @State private var player = SpikePlayer()
    @State private var link = ""
    @State private var name = ""
    @State private var start = ""
    @State private var end = ""
    @State private var preferredRate = 1.0
    @State private var selectedSections: Set<PersistentIdentifier> = []
    @State private var editedSection: PersistentIdentifier?
    @State private var sectionToDelete: PracticeRecord?
    @State private var strategy = LoopStrategy.seek
    @State private var notice: String?
    @FocusState private var isEditing: Bool

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 690
            let fitsPlayer = proxy.size.width >= 240 && proxy.size.height >= 410
            let panelWidth = min(320, max(258, proxy.size.width * 0.31))
            let playerWidth = min(proxy.size.width, 1240) - 40 - (wide ? panelWidth + 33 : 0)
            let availableHeight = max(200, proxy.size.height - 136)
            let playerHeight = max(200, min(playerWidth * 9 / 16, availableHeight * (wide ? 0.75 : 0.52)))
            let workspace = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 16)) :
                AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            VStack(alignment: .leading, spacing: 12) {
                Text("RiffPractice").font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                linkControls
                workspace {
                    playbackPane(fitsPlayer: fitsPlayer, height: playerHeight)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: wide ? .infinity : playerHeight + 128, alignment: .top)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.23))
                        .frame(width: wide ? 1 : nil, height: wide ? nil : 1)
                    storageControls
                        .frame(width: wide ? panelWidth : nil)
                        .frame(maxWidth: wide ? nil : .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(20)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: fitsPlayer, initial: true) { updateActivity(fitsPlayer) }
            .onChange(of: scenePhase, initial: true) { updateActivity(fitsPlayer) }
            .onChange(of: videoID) { _, _ in resetSectionSelection() }
            .onDisappear { player.setActive(false) }
            .confirmationDialog(
                "Delete this section?",
                isPresented: Binding(get: { sectionToDelete != nil }, set: { if !$0 { sectionToDelete = nil } }),
                presenting: sectionToDelete
            ) { section in
                Button("Delete \(section.name)", role: .destructive) { delete(section) }
            }
        }
    }

    private func playbackPane(fitsPlayer: Bool, height: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if fitsPlayer {
                EmbedView(webView: player.webView)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(Color.black)
                if let duration = player.duration {
                    PracticeTimeline(
                        duration: duration,
                        playhead: player.mediaTime,
                        sections: timelineSections.compactMap(\.range),
                        activeSection: currentSection?.range,
                        sectionName: currentSection?.name,
                        canSeek: player.canJump,
                        seek: { player.jump(to: $0) }
                    )
                    .id(player.videoID)
                }
            } else {
                Text("Enlarge the window to view the YouTube player.")
                    .font(.callout)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    practiceControls
                    diagnostics
                    logControls
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var linkControls: some View {
        HStack {
            TextField("YouTube video link", text: $link)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($isEditing)
                .onSubmit(load)
            Button("Load Video", action: load)
                .buttonStyle(.borderedProminent)
            Menu("Saved Videos", systemImage: "bookmark") {
                ForEach(savedVideos, id: \.persistentModelID) { section in
                    Button("\(section.name) · \(section.videoID ?? "")") {
                        openSavedVideo(section)
                    }
                }
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Saved Videos")
            .help("Saved Videos")
            .disabled(savedVideos.isEmpty)
            if let id = player.videoID, let url = YouTubeLink.watchURL(for: id) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                }
                .accessibilityLabel("Open in YouTube")
                .help("Open in YouTube")
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(player.status).font(.callout)
            if let loopPosition = player.loopPosition {
                Text(loopPosition).font(.callout.weight(.semibold))
            }
            Text("\(format(player.mediaTime)) s / \(player.duration.map(format) ?? "—") s   ·   \(rateLabel(player.actualRate)) confirmed   ·   \(player.wrapCount) wraps")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private var practiceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { startControls; endControls }
                VStack(alignment: .leading) { startControls; endControls }
            }
            ViewThatFits(in: .horizontal) {
                HStack { rateControls; strategyControls }
                VStack(alignment: .leading) { rateControls; strategyControls }
            }
            ViewThatFits(in: .horizontal) {
                HStack { loopButtons }
                VStack(alignment: .leading) { loopButtons }
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var loopButtons: some View {
        Button(player.isLooping ? "Stop Looping" : "Loop A–B") {
            if player.isLooping {
                player.stopLoop()
            } else if let range = activeRange {
                player.beginLoop(strategy: strategy, ranges: [range])
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!player.isLooping && (!canLoop || activeRange == nil))
        Button("Loop Entire Video") {
            if let duration = player.duration, let full = LoopRange(start: 0, end: duration) {
                player.beginLoop(strategy: .seek, ranges: [full], wholeVideo: true)
            }
        }
        .disabled(!canLoop || player.isLooping)
        Button("Pause") { player.pause() }
            .disabled(!player.isReady)
    }

    private var startControls: some View {
        HStack {
            Button("Set A") { start = format(player.mediaTime) }
                .disabled(!player.canJump || videoID != player.videoID || player.isLooping)
            TextField("A in seconds", text: $start)
                .accessibilityLabel("A in seconds")
                .textFieldStyle(.roundedBorder)
                .frame(width: 105)
                .disabled(player.isLooping)
        }
    }

    private var endControls: some View {
        HStack {
            Button("Set B") { end = format(player.mediaTime) }
                .disabled(!player.canJump || videoID != player.videoID || player.isLooping)
            TextField("B in seconds", text: $end)
                .accessibilityLabel("B in seconds")
                .textFieldStyle(.roundedBorder)
                .frame(width: 105)
                .disabled(player.isLooping)
        }
    }

    private var rateControls: some View {
        Picker("Requested speed", selection: $preferredRate) {
            ForEach(Set(player.availableRates + [preferredRate]).sorted(), id: \.self) { rate in
                Text(rateLabel(rate) + (player.availableRates.contains(rate) ? "" : " (saved)")).tag(rate)
            }
        }
        .fixedSize()
        .disabled(!player.isReady || player.isLooping)
        .onChange(of: preferredRate) { _, rate in
            if player.isReady, player.availableRates.contains(rate) { player.setRate(rate) }
        }
    }

    private var strategyControls: some View {
        Picker("Loop method", selection: $strategy) {
            ForEach(LoopStrategy.allCases) { Text($0.rawValue).tag($0) }
        }
        .fixedSize()
        .disabled(player.isLooping)
    }

    private var storageControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sections").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack { nameField; saveButton; cancelEditButton }
                VStack(alignment: .leading) { nameField; HStack { saveButton; cancelEditButton } }
            }
            if sections.isEmpty {
                Text("Set A and B, then save a named section such as Intro or Solo.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { selectionButtons }
                    VStack(alignment: .leading) { selectionButtons }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(sections) { section in
                            sectionRow(section)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var selectionButtons: some View {
        Button("Loop Selected (\(selectedSections.count))") {
            player.beginLoop(strategy: strategy, ranges: selectedRanges)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canLoop || player.isLooping || selectedRanges.count != selectedSections.count || selectedRanges.isEmpty)
        if !selectedSections.isEmpty {
            Button("Clear Selection") { selectedSections = [] }
                .disabled(player.isLooping)
        }
    }

    private func sectionRow(_ section: PracticeRecord) -> some View {
        let isCurrent = currentSection?.persistentModelID == section.persistentModelID
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { selectedSections.contains(section.persistentModelID) },
                set: { checked in
                    if checked { selectedSections.insert(section.persistentModelID) }
                    else { selectedSections.remove(section.persistentModelID) }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.name)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .accessibilityLabel(isCurrent ? "\(section.name), current section" : section.name)
                    Text("\(format(section.start))–\(format(section.end)) s")
                        .monospacedDigit()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(player.isLooping || (player.duration != nil && playableRange(for: section) == nil))
            Spacer(minLength: 0)
            Button {
                player.jump(to: section.start)
            } label: {
                Image(systemName: "arrow.right.to.line")
            }
            .accessibilityLabel("Jump to \(section.name)")
            .help("Jump to start")
            .disabled(!player.canJump || playableRange(for: section) == nil)
            Button {
                if let range = playableRange(for: section) {
                    player.beginLoop(strategy: strategy, ranges: [range])
                }
            } label: {
                Image(systemName: "repeat.1")
            }
            .accessibilityLabel("Loop \(section.name)")
            .help("Loop this section")
            .disabled(!canLoop || player.isLooping || playableRange(for: section) == nil)
            Menu {
                Button("Edit Section") { edit(section) }
                Button("Delete Section", role: .destructive) { sectionToDelete = section }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Options for \(section.name)")
            .fixedSize()
            .disabled(player.isLooping)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private var nameField: some View {
        TextField("Section name", text: $name).textFieldStyle(.roundedBorder)
    }

    private var saveButton: some View {
        Button(editedSection == nil ? "Save Section" : "Update Section", action: save)
            .disabled(player.isLooping || range == nil || videoID == nil ||
                      name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @ViewBuilder
    private var cancelEditButton: some View {
        if editedSection != nil {
            Button("Cancel Edit", action: clearEditor)
        }
    }

    private var logControls: some View {
        DisclosureGroup("Diagnostics log (\(player.log.count))") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ShareLink("Export Log", item: player.logText).disabled(player.log.isEmpty)
                    Button("Clear Log") { player.clearLog() }.disabled(player.log.isEmpty)
                }
                ForEach(player.log.suffix(30)) { entry in
                    Text(entry.text).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var range: LoopRange? {
        guard let first = seconds(start), let last = seconds(end) else { return nil }
        let duration = YouTubeLink.videoID(from: link) == player.videoID ? player.duration : nil
        return LoopRange(start: first, end: last, duration: duration)
    }

    private var activeRange: LoopRange? {
        guard let id = player.videoID, YouTubeLink.videoID(from: link) == id, player.duration != nil else { return nil }
        return range
    }

    private var videoID: String? { YouTubeLink.videoID(from: link) }

    private var sections: [PracticeRecord] { PracticeRecord.sections(for: videoID, in: records) }

    private var timelineSections: [PracticeRecord] {
        PracticeRecord.sections(for: player.videoID, in: records).filter { playableRange(for: $0) != nil }
    }

    private var currentSection: PracticeRecord? {
        let time = player.mediaTime
        return timelineSections.last { $0.start <= time && time < $0.end }
    }

    private var savedVideos: [PracticeRecord] {
        var seen = Set<String>()
        return records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.filter {
            guard let id = $0.videoID else { return false }
            return seen.insert(id).inserted
        }
    }

    private var canLoop: Bool {
        player.canLoop && videoID == player.videoID
    }

    private var selectedRanges: [LoopRange] {
        sections.filter { selectedSections.contains($0.persistentModelID) }.compactMap(playableRange(for:))
    }

    private func playableRange(for section: PracticeRecord) -> LoopRange? {
        guard let duration = player.duration, section.videoID == player.videoID else { return nil }
        return LoopRange(start: section.start, end: section.end, duration: duration)
    }

    private func load() {
        guard let id = YouTubeLink.videoID(from: link) else {
            notice = "Paste a valid YouTube video link."
            return
        }
        isEditing = false
        notice = nil
        player.load(id: id, preferredRate: preferredRate)
    }

    private func save() {
        guard let range, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let cleanedLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editedSection, let record = sections.first(where: { $0.persistentModelID == editedSection }) {
            record.name = cleanedName
            record.start = range.start
            record.end = range.end
            record.rate = preferredRate
        } else {
            modelContext.insert(PracticeRecord(link: cleanedLink, name: cleanedName, start: range.start, end: range.end, rate: preferredRate))
        }
        do {
            try modelContext.save()
            clearEditor()
            notice = "Saved “\(cleanedName)”."
        } catch {
            modelContext.rollback()
            notice = "Could not save the section: \(error.localizedDescription)"
        }
    }

    private func edit(_ section: PracticeRecord) {
        editedSection = section.persistentModelID
        name = section.name
        start = format(section.start)
        end = format(section.end)
    }

    private func delete(_ section: PracticeRecord) {
        let id = section.persistentModelID
        modelContext.delete(section)
        do {
            try modelContext.save()
            selectedSections.remove(id)
            if editedSection == id { clearEditor() }
            notice = "Section deleted."
        } catch {
            modelContext.rollback()
            notice = "Could not delete the section: \(error.localizedDescription)"
        }
    }

    private func openSavedVideo(_ section: PracticeRecord) {
        resetSectionSelection()
        link = section.link
        preferredRate = section.rate
        load()
    }

    private func resetSectionSelection() {
        selectedSections = []
        clearEditor()
    }

    private func clearEditor() {
        editedSection = nil
        name = ""
        start = ""
        end = ""
    }

    private func updateActivity(_ fitsPlayer: Bool) {
        player.setActive(scenePhase == .active && fitsPlayer)
    }

    private func seconds(_ input: String) -> Double? {
        Double(input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }

    private func format(_ time: Double) -> String {
        time.formatted(.number.grouping(.never).precision(.fractionLength(3)).locale(Locale(identifier: "en_US_POSIX")))
    }

    private func rateLabel(_ rate: Double) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

#if os(macOS)
private struct EmbedView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct EmbedView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
