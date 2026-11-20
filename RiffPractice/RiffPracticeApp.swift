import CloudKit
import CoreData
import SwiftData
import SwiftUI
import WebKit

enum SectionsPlacement: String, CaseIterable, Identifiable {
    case left = "Left"
    case right = "Right"
    case below = "Below"

    var id: Self { self }
}

enum PracticeWorkspaceItem: String, Identifiable {
    case video, sections
    var id: Self { self }
}

enum SectionsPanelSizing {
    static let minimumWidth = 280.0
    static let maximumWidth = 320.0

    static func width(_ requested: Double) -> Double {
        requested.isFinite ? min(max(requested, minimumWidth), maximumWidth) : maximumWidth
    }

    static func items(placement: SectionsPlacement, visible: Bool, sideBySide: Bool) -> [PracticeWorkspaceItem] {
        guard visible else { return [.video] }
        return placement == .left && sideBySide ? [.sections, .video] : [.video, .sections]
    }
}

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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Query private var records: [PracticeSection]
    @Query private var videoSessions: [VideoSession]
    @AppStorage("sectionsPanelPlacement") private var panelPlacement = SectionsPlacement.right
    @AppStorage("sectionsPanelVisible") private var panelVisible = true
    @AppStorage("sectionsPanelWidth") private var savedPanelWidth = 320.0
    @AppStorage("skipNewSessionConfirmation") private var skipNewSessionConfirmation = false
    @AppStorage("editorVideoScale") private var savedVideoScale = 1.0
    @GestureState private var panelWidthChange = 0.0
    @GestureState private var videoHeightChange = 0.0
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
    @State private var repeatingSections: [TimelineSection] = []
    @State private var composingSession = true
    @State private var newSessionLink = ""
    @State private var newSessionName = ""
    @State private var confirmingNewSession = false
    @State private var skipConfirmationDraft = false
    @State private var fullScreen = false
    @State private var fullScreenControlsVisible = true
    @State private var pointerOverControls = false
    @State private var interactionToken = 0
    @State private var videoVisible = true
    #if os(macOS)
    @State private var nativeWindow: NSWindow?
    #endif
    @FocusState private var isEditing: Bool

    private func workspaceContent(in proxy: GeometryProxy) -> some View {
        let wide = proxy.size.width >= 720 && panelPlacement != .below
        let fitsPlayer = proxy.size.width >= 240 && proxy.size.height >= 410
        let panelWidth = SectionsPanelSizing.width(savedPanelWidth + panelWidthChange)
        let showPanel = panelVisible && !fullScreen
        let availableHeight = max(200, proxy.size.height - (fullScreen ? 64 : (composingSession ? 210 : 116)))
        let belowPanelHeight = min(280, max(180, availableHeight * 0.36))
        let workspace =
            wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 16)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        let content = VStack(alignment: .leading, spacing: fullScreen ? 0 : 12) {
            if !fullScreen {
                HStack {
                    Text("RiffPractice").font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button {
                        setFullScreen(true)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel("Full-screen practice")
                    .help("Full-screen practice")
                    .disabled(player.videoID == nil)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { panelVisible.toggle() }
                    } label: {
                        Label(
                            panelVisible ? "Hide Sections" : "Show Sections",
                            systemImage: panelPlacement == .left ? "sidebar.left" : "sidebar.right")
                    }
                    .buttonStyle(.bordered)
                    Menu {
                        Picker("Sections position", selection: $panelPlacement) {
                            ForEach(SectionsPlacement.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if panelPlacement != .below {
                            Button("Reset Panel Width") { savedPanelWidth = SectionsPanelSizing.maximumWidth }
                        }
                        Button("Reset Video Size") { savedVideoScale = 1 }
                    } label: {
                        Image(systemName: "rectangle.3.group")
                    }
                    .accessibilityLabel("Layout options")
                    .help("Layout options")
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
                if composingSession { newSessionForm }
            }
            workspace {
                ForEach(SectionsPanelSizing.items(placement: panelPlacement, visible: showPanel, sideBySide: wide)) { item in
                    switch item {
                    case .video:
                        playbackPane(fitsPlayer: fitsPlayer)
                            .frame(maxWidth: .infinity)
                            .frame(
                                maxHeight: wide || !showPanel ? .infinity : max(220, availableHeight - belowPanelHeight - 12),
                                alignment: .top)
                    case .sections:
                        HStack(spacing: 8) {
                            if wide && panelPlacement == .right { resizeHandle }
                            storageControls.frame(width: wide ? panelWidth : nil)
                            if wide && panelPlacement == .left { resizeHandle }
                        }
                        .frame(maxWidth: wide ? nil : .infinity, maxHeight: wide ? .infinity : belowPanelHeight, alignment: .topLeading)
                    }
                }
            }
            if fullScreen { fullScreenDock.frame(height: 64) }
        }
        .padding(fullScreen ? 0 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(fullScreen ? Color.black : Color.clear)
        return
            content
            .preferredColorScheme(fullScreen ? .dark : nil)
            #if os(macOS)
                .background {
                    FullScreenWindowObserver(
                        resolved: { nativeWindow = $0 },
                        changed: { fullScreen = $0 },
                        activity: { if fullScreen { revealFullScreenControls() } }
                    )
                    .frame(width: 0, height: 0)
                }
            #else
                .statusBarHidden(fullScreen)
                .persistentSystemOverlays(fullScreen ? .hidden : .automatic)
            #endif
            .onContinuousHover { phase in
                if case .active = phase, fullScreen { revealFullScreenControls() }
            }
            .simultaneousGesture(TapGesture().onEnded { if fullScreen { revealFullScreenControls() } })
            .onKeyPress(.escape) {
                guard fullScreen else { return .ignored }
                setFullScreen(false)
                return .handled
            }
            .onChange(of: fitsPlayer, initial: true) { updateActivity(fitsPlayer) }
            .onChange(of: scenePhase, initial: true) { updateActivity(fitsPlayer) }
            .onChange(of: videoID) { _, _ in resetSectionSelection() }
            .onChange(of: selectedRanges) { if player.isLooping { player.stopLoop() } }
            .onChange(of: player.isLooping) { if !player.isLooping { repeatingSections = [] } }
            .onChange(of: player.isPlaying) { revealFullScreenControls() }
            .onChange(of: fullScreen) {
            pointerOverControls = false
                revealFullScreenControls()
                updateActivity(fitsPlayer)
            }
            .onChange(of: pointerOverControls) { revealFullScreenControls() }
        .onChange(of: voiceOverEnabled) { revealFullScreenControls() }
            .task(id: interactionToken) { await hideIdleControls() }
            .onDisappear { player.setActive(false) }
    }

    var body: some View {
        GeometryReader { proxy in
            workspaceContent(in: proxy)
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
                .sheet(isPresented: $confirmingNewSession) {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Start a new session?").font(.title2.bold())
                        Text("Saved sessions and markers stay available in Open Session. Unsaved section edits will be cleared.")
                        Toggle("Skip this confirmation next time", isOn: $skipConfirmationDraft)
                        HStack {
                            Spacer()
                            Button("Cancel", role: .cancel) { confirmingNewSession = false }
                            Button("New Session") {
                                skipNewSessionConfirmation = skipConfirmationDraft
                                confirmingNewSession = false
                                beginNewSession()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(24)
                    .frame(idealWidth: 420)
                    .presentationDetents([.height(260)])
                }
        }
    }

    private func playbackPane(fitsPlayer: Bool) -> some View {
        GeometryReader { viewport in
            let fullSize = VideoViewport.fitted(in: viewport.size)
            let scale = min(max(savedVideoScale + videoHeightChange, 0.65), 1.4)
            let width = fullScreen ? fullSize.width : viewport.size.width
            let height = fullScreen ? fullSize.height : VideoViewport.editorHeight(width: width, scale: scale)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: fullScreen ? 0 : 12) {
                        if fitsPlayer {
                            EmbedView(webView: player.webView)
                                .frame(width: width, height: height)
                                .background(Color.black)
                                .background {
                                    GeometryReader { position in
                                        Color.clear.preference(
                                            key: PlayerFramePreference.self,
                                            value: position.frame(in: .named("practiceVideoViewport")))
                                    }
                                }
                                .id("practice-player")
                            if !fullScreen {
                                videoSizeHandle(width: width)
                            }
                            if !fullScreen, let duration = player.duration {
                                PracticeTimeline(
                                    duration: duration,
                                    playhead: player.mediaTime,
                                    sections: timelineEntries,
                                    activeSection: currentSection?.range,
                                    sectionName: currentSection?.name,
                                    canSeek: player.canJump,
                                    seek: { player.jump(to: $0) },
                                    editRange: player.isLooping ? nil : activeRange,
                                    editingSectionID: editedSection,
                                    changeRange: moveEndpoints,
                                    selectSection: selectTimelineSection,
                                    availableWidth: width
                                )
                                .id(player.videoID)
                            }
                        } else {
                            Text("Enlarge the window to view the YouTube player.")
                                .font(.callout)
                        }

                        if !fullScreen {
                            if player.isLooping { activeLoopSummary }
                            VStack(alignment: .leading, spacing: 10) {
                                practiceControls
                                playbackStatus
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        }
                    }
                    .padding(.bottom, fullScreen ? 0 : 16)
                    .frame(
                        maxWidth: .infinity, minHeight: fullScreen ? viewport.size.height : nil,
                        alignment: fullScreen ? .center : .top)
                }
                .scrollDisabled(fullScreen)
                .coordinateSpace(name: "practiceVideoViewport")
                .onPreferenceChange(PlayerFramePreference.self) { frame in
                    guard frame.width > 0, frame.height > 0 else { return }
                    let intersection = frame.intersection(CGRect(origin: .zero, size: viewport.size))
                    videoVisible = !intersection.isNull && intersection.height / frame.height > 0.5
                    updateActivity(fitsPlayer)
                }
                .onChange(of: fullScreen) { reader.scrollTo("practice-player", anchor: .top) }
            }
        }
    }

    private var linkControls: some View {
        HStack {
            Button {
                if skipNewSessionConfirmation {
                    beginNewSession()
                } else {
                    skipConfirmationDraft = false
                    confirmingNewSession = true
                }
            } label: {
                Label("New Session", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
            Menu("Open Session", systemImage: "folder") {
                ForEach(savedSessions) { session in
                    Button(session.title) {
                        openSavedSession(session)
                    }
                }
            }
            .accessibilityLabel("Open saved session")
            .disabled(savedSessions.isEmpty)
            if let id = videoID, let title = sessionTitles[id] {
                Text(title).font(.headline).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let id = player.videoID, let url = YouTubeLink.watchURL(for: id) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                }
                .accessibilityLabel("Open in YouTube")
                .help("Open in YouTube")
            }
        }
    }

    private var fullScreenDock: some View {
        HStack(spacing: 12) {
            Button {
                setFullScreen(false)
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .accessibilityLabel("Exit full-screen practice")
            .help("Exit full screen · Escape")
            Button { player.togglePlayback() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .disabled(!player.isReady)
            rateControls.labelsHidden()
            if player.isLooping {
                Button { player.stopLoop() } label: { Image(systemName: "stop.fill") }
                    .accessibilityLabel("Stop looping")
                Text(player.isRepeatingVideo ? "Entire video" : repeatingSections.map(\.name).joined(separator: " · "))
                    .font(.callout).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 16)
        .opacity(fullScreenControlsVisible ? 1 : 0)
        .allowsHitTesting(fullScreenControlsVisible)
        .accessibilityHidden(!fullScreenControlsVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color.black.contentShape(Rectangle()).onTapGesture { revealFullScreenControls() }
        }
        .onHover { pointerOverControls = $0 }
    }

    private func revealFullScreenControls() {
        guard fullScreen else { return }
        fullScreenControlsVisible = true
        interactionToken += 1
    }

    private func hideIdleControls() async {
        guard fullScreen else { return }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, fullScreen,
              FullScreenControls.shouldHide(playing: player.isPlaying,
                                            pointerOverControls: pointerOverControls,
                                            voiceOver: voiceOverEnabled) else { return }
        withAnimation(.easeOut(duration: 0.25)) { fullScreenControlsVisible = false }
    }

    private func setFullScreen(_ enabled: Bool) {
        #if os(macOS)
        if let nativeWindow, nativeWindow.styleMask.contains(.fullScreen) != enabled {
            nativeWindow.toggleFullScreen(nil)
        }
        #endif
        fullScreen = enabled
    }

    private func videoSizeHandle(width: Double) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 44, height: 3)
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .updating($videoHeightChange) { value, change, _ in
                        change = value.translation.height / max(1, width * 9 / 16)
                    }
                    .onEnded { value in
                        let change = value.translation.height / max(1, width * 9 / 16)
                        savedVideoScale = min(max(savedVideoScale + change, 0.65), 1.4)
                    }
            )
            .accessibilityLabel("Video height")
            .accessibilityAdjustableAction { direction in
                savedVideoScale = min(max(savedVideoScale + (direction == .increment ? 0.1 : -0.1), 0.65), 1.4)
            }
            .help("Drag to resize the video · Reset Video Size in layout options")
    }

    private var newSessionForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Session name", text: $newSessionName).textFieldStyle(.roundedBorder)
            HStack {
                TextField("Paste a YouTube video link", text: $newSessionLink)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($isEditing)
                    .onSubmit(useNewSessionVideo)
                Button("Use YouTube Video", action: useNewSessionVideo)
                    .buttonStyle(.borderedProminent)
                    .disabled(YouTubeLink.videoID(from: newSessionLink) == nil)
            }
        }
    }

    private var playbackStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !player.isPlaying { Text(player.status).font(.callout).foregroundStyle(.secondary) }
            if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private var practiceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !player.isLooping {
                ViewThatFits(in: .horizontal) {
                    HStack { startControls; endControls }
                    VStack(alignment: .leading) { startControls; endControls }
                }
            }
            if editedSection != nil && !player.isLooping {
                Text("Drag A or B on the timeline to adjust this section. Release to save.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack { rateControls; playbackOptions; loopButtons }
                VStack(alignment: .leading) {
                    HStack { rateControls; playbackOptions }
                    HStack { loopButtons }
                }
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var loopButtons: some View {
        if !player.isLooping {
            Button("Loop A–B") {
                if let range = activeRange { beginPracticeLoop(ranges: [range]) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canLoop || activeRange == nil)
            Button("Loop Entire Video") {
                if let duration = player.duration, let full = LoopRange(start: 0, end: duration) {
                    beginPracticeLoop(ranges: [full], wholeVideo: true)
                }
            }
            .disabled(!canLoop)
        }
        Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayback() }
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
        Picker("Speed", selection: $preferredRate) {
            ForEach(Set(player.availableRates + [preferredRate]).sorted(), id: \.self) { rate in
                Text(rateLabel(rate) + (player.availableRates.contains(rate) ? "" : " (saved)")).tag(rate)
            }
        }
        .fixedSize()
        .disabled(!player.isReady)
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

    private var playbackOptions: some View {
        Menu {
            Picker("Repeat method", selection: $strategy) {
                ForEach(LoopStrategy.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(player.isLooping)
            Toggle("Confirm before new sessions", isOn: Binding(
                get: { !skipNewSessionConfirmation },
                set: { skipNewSessionConfirmation = !$0 }
            ))
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityLabel("Playback options")
        .help("Playback options")
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
            let selected = sections.filter { selectedSections.contains($0.id) }
            beginPracticeLoop(ranges: selectedRanges, sections: selected)
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
                        .lineLimit(1)
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
                    beginPracticeLoop(ranges: [range], sections: [section])
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

    private var resizeHandle: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 4, height: 44)
            .frame(width: 16)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .updating($panelWidthChange) { value, change, _ in
                        change = value.translation.width * (panelPlacement == .left ? 1 : -1)
                    }
                    .onEnded { value in
                        let change = value.translation.width * (panelPlacement == .left ? 1 : -1)
                        savedPanelWidth = SectionsPanelSizing.width(savedPanelWidth + change)
                    }
            )
            .accessibilityLabel("Sections panel width")
            .accessibilityValue("\(Int(SectionsPanelSizing.width(savedPanelWidth))) points")
            .accessibilityAdjustableAction { direction in
                savedPanelWidth = SectionsPanelSizing.width(savedPanelWidth + (direction == .increment ? 10 : -10))
            }
            .help("Drag to resize the sections panel")
    }

    private var activeLoopSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: "repeat").foregroundStyle(Color.accentColor)
            if player.isRepeatingVideo {
                Text("Entire video").font(.callout.weight(.medium))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(repeatingSections) { section in
                            let current = player.mediaTime >= section.range.start && player.mediaTime < section.range.end
                            Text(section.name)
                                .font(.callout.weight(current ? .semibold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(current ? 0.2 : 0.07), in: Capsule())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button("Stop") { player.stopLoop() }
                .buttonStyle(.bordered)
                .accessibilityLabel("Stop looping")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Currently repeating")
    }

    private func beginPracticeLoop(ranges: [LoopRange], sections: [PracticeSection] = [], wholeVideo: Bool = false) {
        player.beginLoop(strategy: wholeVideo ? .seek : strategy, ranges: ranges, wholeVideo: wholeVideo)
        guard player.isLooping else { return }
        repeatingSections = sections.compactMap { section in
            section.range.map { TimelineSection(id: section.id, name: section.name, range: $0) }
        }
        if repeatingSections.isEmpty, !wholeVideo, let range = ranges.first {
            let title = self.sections.first { $0.id == editedSection }?.name ?? "A–B loop"
            repeatingSections = [TimelineSection(id: "draft", name: title, range: range)]
        }
    }

    private func selectTimelineSection(_ id: String, endpoint: TimelineEndpoint) {
        guard let section = timelineSections.first(where: { $0.id == id }), let range = section.range else { return }
        player.jump(to: endpoint.time(in: range))
        edit(section)
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

    private var timelineEntries: [TimelineSection] {
        timelineSections.compactMap { section in
            section.range.map { TimelineSection(id: section.id, name: section.name, range: $0) }
        }
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
        composingSession = false
        load()
    }

    private func beginNewSession() {
        player.unload()
        resetSectionSelection()
        link = ""
        newSessionLink = ""
        newSessionName = ""
        preferredRate = 1
        notice = nil
        composingSession = true
    }

    private func useNewSessionVideo() {
        guard let id = YouTubeLink.videoID(from: newSessionLink) else {
            notice = "Paste a valid YouTube video link."
            return
        }
        if let existing = savedSessions.first(where: { $0.id == id }) {
            openSavedSession(existing)
            notice = "Opened the existing session “\(existing.title)”."
            return
        }
        let cleanName = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleanName.isEmpty ? "Untitled Session" : cleanName
        modelContext.insert(VideoSession(videoID: id, title: title))
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            notice = "Could not create the session: \(error.localizedDescription)"
            return
        }
        link = newSessionLink.trimmingCharacters(in: .whitespacesAndNewlines)
        preferredRate = 1
        composingSession = false
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
        player.setActive(scenePhase == .active && fitsPlayer && (fullScreen || videoVisible))
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
