import CloudKit
import CoreData
import SwiftData
import SwiftUI
import WebKit

@main
struct RiffPracticeApp: App {
    var body: some Scene {
        #if os(macOS)
        Window("RiffPractice", id: "practice") {
            LibraryRoot().frame(minWidth: 560, minHeight: 550)
        }
        .defaultSize(width: 1040, height: 760)
        .windowResizability(.contentMinSize)
        #else
        WindowGroup {
            LibraryRoot()
        }
        #endif
    }
}

private struct LibraryRoot: View {
    @State private var library = PracticeLibrary()

    var body: some View {
        Group {
            if let container = library.container {
                SpikeView(library: library).modelContainer(container)
            } else if let error = library.error {
                ContentUnavailableView {
                    Label("Library Could Not Open", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { library.open() }
                }
            } else {
                ProgressView("Opening practice library…")
            }
        }
        .task {
            library.open()
            await library.refreshAccount()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)) {
            library.receivedCloudEvent($0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            Task { await library.refreshAccount() }
        }
    }
}

private struct SpikeView: View {
    let library: PracticeLibrary
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var records: [PracticeSection]
    @Query private var videoSessions: [VideoSession]
    @State private var player = SpikePlayer()
    @State private var link = ""
    @State private var name = ""
    @State private var start = ""
    @State private var end = ""
    @State private var preferredRate = 1.0
    @State private var selectedSections: Set<String> = []
    @State private var editedSection: String?
    @State private var sectionToDelete: PracticeSection?
    @State private var lastPreviewSeek = 0.0
    @State private var sessionToName: String?
    @State private var sessionTitleDraft = ""
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
                HStack {
                    Text("RiffPractice").font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Menu {
                        Text(library.syncStatus)
                        Button("Check iCloud") { Task { await library.refreshAccount() } }
                        if let backupURL = library.backupURL {
                            ShareLink("Export Original Marker Backup", item: backupURL)
                        }
                    } label: {
                        Image(systemName: library.cloudEnabled ? "icloud" : "internaldrive")
                    }
                    .accessibilityLabel(library.syncStatus)
                    .help(library.syncStatus)
                }
                linkControls
                workspace {
                    playbackPane(fitsPlayer: fitsPlayer, height: playerHeight)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: wide ? .infinity : playerHeight + (activeRange == nil ? 128 : 208), alignment: .top)
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
            .onChange(of: selectedRanges) { if player.isLooping { player.stopLoop() } }
            .onDisappear { player.setActive(false) }
            .confirmationDialog(
                "Delete this section?",
                isPresented: Binding(get: { sectionToDelete != nil }, set: { if !$0 { sectionToDelete = nil } }),
                presenting: sectionToDelete
            ) { section in
                Button("Delete \(section.name)", role: .destructive) { delete(section) }
            }
            .alert(
                "Session Name",
                isPresented: Binding(get: { sessionToName != nil }, set: { if !$0 { sessionToName = nil } }),
                presenting: sessionToName
            ) { id in
                TextField("Session name", text: $sessionTitleDraft)
                Button("Save") { saveSessionTitle(for: id) }
                    .disabled(sessionTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This name appears in Saved Sessions.")
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
                        seek: { player.jump(to: $0) },
                        editRange: activeRange,
                        changeRange: moveEndpoints
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
            Menu("Saved Sessions", systemImage: "bookmark") {
                ForEach(savedSessions) { session in
                    Button(session.title) {
                        openSavedSession(session)
                    }
                }
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Saved Sessions")
            .help("Saved Sessions")
            .disabled(savedSessions.isEmpty)
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
            if editedSection != nil {
                Text("Drag A or B on the timeline to adjust this section. Release to save.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            if player.isReady, player.availableRates.contains(rate) {
                player.setRate(rate)
                if let id = videoID, id == player.videoID {
                    let session = VideoSession.latest(in: videoSessions)[id] ?? VideoSession(videoID: id, title: "", rate: rate)
                    if session.modelContext == nil { modelContext.insert(session) }
                    session.rate = rate
                    session.updatedAt = Date()
                    do { try modelContext.save() }
                    catch {
                        modelContext.rollback()
                        notice = "Could not save the preferred speed: \(error.localizedDescription)"
                    }
                }
            }
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
            if let id = videoID {
                let title = sessionTitles[id]
                HStack {
                    if let title {
                        Text(title).font(.headline).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button(title == nil ? "Name Session" : "Rename Session") {
                        sessionTitleDraft = title ?? ""
                        sessionToName = id
                    }
                }
            }
            HStack {
                Text("Sections").font(.headline)
                Spacer()
                Button("New Section") {
                    guard let duration = player.duration else { return }
                    clearEditor()
                    let beginning = min(player.mediaTime, max(0, duration - 0.05))
                    start = format(beginning)
                    end = format(min(duration, beginning + 5))
                }
                .disabled(!player.canJump || videoID != player.videoID)
            }
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

    private func sectionRow(_ section: PracticeSection) -> some View {
        let isCurrent = currentSection?.id == section.id
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { selectedSections.contains(section.id) },
                set: { checked in
                    if checked { selectedSections.insert(section.id) }
                    else { selectedSections.remove(section.id) }
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

    private var sections: [PracticeSection] { PracticeSection.sections(for: videoID, in: records) }

    private var timelineSections: [PracticeSection] {
        PracticeSection.sections(for: player.videoID, in: records).filter { playableRange(for: $0) != nil }
    }

    private var currentSection: PracticeSection? {
        let time = player.mediaTime
        return timelineSections.last { $0.start <= time && time < $0.end }
    }

    private var sessionTitles: [String: String] {
        VideoSession.latest(in: videoSessions.filter { !$0.title.isEmpty }).mapValues(\.title)
    }

    private var savedSessions: [SavedVideoSession] {
        SavedVideoSession.all(sections: records, titles: sessionTitles, rates: VideoSession.latest(in: videoSessions).mapValues(\.rate))
    }

    private var canLoop: Bool {
        player.canLoop && videoID == player.videoID
    }

    private var selectedRanges: [LoopRange] {
        sections.filter { selectedSections.contains($0.id) }.compactMap(playableRange(for:))
    }

    private func playableRange(for section: PracticeSection) -> LoopRange? {
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
        if let editedSection {
            guard let record = sections.first(where: { $0.id == editedSection }) else {
                notice = "This section was removed. Choose New Section to create another."
                return
            }
            record.name = cleanedName
            record.start = range.start
            record.end = range.end
            record.rate = preferredRate
            record.updatedAt = Date()
        } else {
            modelContext.insert(PracticeSection(link: cleanedLink, name: cleanedName, start: range.start, end: range.end, rate: preferredRate))
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

    private func edit(_ section: PracticeSection) {
        editedSection = section.id
        name = section.name
        start = format(section.start)
        end = format(section.end)
    }

    private func delete(_ section: PracticeSection) {
        let id = section.id
        section.removed = true
        section.updatedAt = Date()
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

    private func saveSessionTitle(for id: String) {
        let title = sessionTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let session = VideoSession.latest(in: videoSessions)[id] ?? VideoSession(videoID: id, title: title, rate: preferredRate)
        if session.modelContext == nil { modelContext.insert(session) }
        session.title = title
        session.rate = preferredRate
        session.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            notice = "Could not save the session name: \(error.localizedDescription)"
        }
    }

    private func moveEndpoints(_ range: LoopRange, target: Double, finished: Bool) {
        start = format(range.start)
        end = format(range.end)
        let now = ProcessInfo.processInfo.systemUptime
        if finished || now - lastPreviewSeek >= 0.15 {
            player.jump(to: target)
            lastPreviewSeek = now
        }
        guard finished, let editedSection,
              let record = sections.first(where: { $0.id == editedSection }) else { return }
        record.start = range.start
        record.end = range.end
        record.updatedAt = Date()
        do {
            try modelContext.save()
            notice = "Section endpoints saved."
        } catch {
            modelContext.rollback()
            start = format(record.start)
            end = format(record.end)
            notice = "Could not save the endpoints: \(error.localizedDescription)"
        }
    }

    private func openSavedSession(_ session: SavedVideoSession) {
        guard let url = YouTubeLink.watchURL(for: session.id) else { return }
        resetSectionSelection()
        link = url.absoluteString
        preferredRate = session.rate
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
