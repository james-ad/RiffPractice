import Foundation
import Observation
import WebKit

private final class ScriptReceiver: NSObject, WKScriptMessageHandler {
    weak var player: SpikePlayer?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let event = message.body as? [String: Any] else { return }
        player?.receive(event)
    }
}

@MainActor
@Observable
final class SpikePlayer {
    private enum PlayerState: Int {
        case unstarted = -1
        case ended = 0
        case playing = 1
        case paused = 2
        case buffering = 3
        case cued = 5
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let text: String
    }

    let webView: WKWebView
    private(set) var videoID: String?
    private(set) var status = "Load an embeddable YouTube video."
    private(set) var mediaTime = 0.0
    private(set) var duration: Double?
    private(set) var availableRates = [1.0]
    private(set) var actualRate = 1.0
    private(set) var isReady = false
    private(set) var log: [LogEntry] = []
    private(set) var wrapCount = 0
    private(set) var isActive = false
    private var state: PlayerState?
    private var session = UUID().uuidString
    private var experiment: LoopExperiment?
    private var loopToken = UUID()
    private var requestedRate = 1.0
    private var wrapStartedAt: TimeInterval?
    private var awaitingBoundedStart = false
    private var deadline: TimeInterval?
    private var loadTimeout: Task<Void, Never>?
    private let clockStart = ProcessInfo.processInfo.systemUptime

    var isLooping: Bool { experiment != nil }
    var isPlaying: Bool { state == .playing }
    var canJump: Bool { isActive && isReady && (state == .playing || state == .paused) }
    var canLoop: Bool { duration != nil && (canJump || (isActive && isReady && state == .ended)) }
    var loopPosition: String? {
        guard let experiment else { return nil }
        if experiment.wholeVideo { return "Repeating entire video" }
        return "Looping section \(experiment.index + 1) of \(experiment.count)"
    }
    var logText: String { log.map(\.text).joined(separator: "\n") }

    init() {
        let receiver = ScriptReceiver()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(receiver, contentWorld: .page, name: "playerEvent")
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        receiver.player = self
    }

    func load(id: String, preferredRate: Double) {
        let newSession = UUID().uuidString
        session = newSession
        loadTimeout?.cancel()
        resetLoop()
        wrapCount = 0
        videoID = id
        isReady = false
        state = nil
        duration = nil
        mediaTime = 0
        actualRate = 1
        availableRates = [1]
        requestedRate = preferredRate
        status = "Loading YouTube player…"

        guard let bundleID = Bundle.main.bundleIdentifier,
              let baseURL = URL(string: "https://\(bundleID.lowercased())"),
              let wrapper = Bundle.main.url(forResource: "Player", withExtension: "html"),
              let template = try? String(contentsOf: wrapper, encoding: .utf8),
              let configuration = try? JSONSerialization.data(withJSONObject: [
                  "videoID": id, "session": newSession, "origin": baseURL.absoluteString
              ]),
              let payload = String(data: configuration, encoding: .utf8)
        else {
            fail("Missing player wrapper or application identity.")
            return
        }

        record("Load \(id) · \(baseURL.absoluteString)")
        webView.loadHTMLString(template.replacingOccurrences(of: "__PLAYER_CONFIGURATION__", with: payload), baseURL: baseURL)
        loadTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.session == newSession, !self.isReady else { return }
            self.fail("The player did not become ready. Check your connection and load the video again.")
        }
    }

    func setActive(_ newValue: Bool) {
        guard isActive != newValue else { return }
        isActive = newValue
        if !newValue { pause() }
    }

    func pause() {
        stopLoop()
        if isReady { send("pause") }
    }

    func setRate(_ rate: Double) {
        requestedRate = rate
        record("Requested rate \(rate)")
        send("rate", data: ["rate": rate])
    }

    func jump(to time: Double) {
        guard canJump, time.isFinite, time >= 0,
              let duration, time <= duration else { return }
        if isLooping {
            record("Stop loop to seek")
            resetLoop()
        }
        send("seek", data: ["start": min(time, max(0, duration - 0.05))])
    }

    func beginLoop(strategy: LoopStrategy, ranges: [LoopRange], wholeVideo: Bool = false) {
        guard canLoop, !isLooping, let range = ranges.first else { return }
        experiment = LoopExperiment(strategy: strategy, range: range,
                                    followingRanges: Array(ranges.dropFirst()), wholeVideo: wholeVideo)
        wrapCount = 0
        record("Start \(strategy.rawValue) · A=\(formatted(range.start)) B=\(formatted(range.end)) · rate=\(actualRate)")
        requestedRate = actualRate
        if wholeVideo {
            if state == .ended {
                experiment?.beginSeek(at: ProcessInfo.processInfo.systemUptime)
                send("restart", data: ["start": 0], tiedToLoop: true)
            } else if !isPlaying {
                send("play", tiedToLoop: true)
            }
            return
        }
        if strategy == .seek {
            experiment?.beginSeek(at: ProcessInfo.processInfo.systemUptime)
            send(isPlaying ? "seek" : "restart", data: ["start": range.start], tiedToLoop: true)
        } else {
            requestSegment(range)
        }
    }

    func stopLoop() {
        let clearBoundary = experiment?.strategy == .bounded
        if isLooping { record("Stop loop") }
        resetLoop()
        if clearBoundary, isReady { send("clearBoundary") }
    }

    func clearLog() {
        log = []
    }

    fileprivate func receive(_ event: [String: Any]) {
        guard event["session"] as? String == session, let type = event["type"] as? String else { return }
        switch type {
        case "ready":
            loadTimeout?.cancel()
            isReady = true
            status = "Ready. Press Play in the YouTube player."
            record("Ready")
            if requestedRate != 1 { send("rate", data: ["rate": requestedRate]) }
        case "capabilities":
            availableRates = (event["rates"] as? [Double] ?? []).filter { $0.isFinite && $0 > 0 }
            if !availableRates.contains(1) { availableRates.append(1) }
            availableRates.sort()
            if let value = event["duration"] as? Double, value.isFinite && value > 0 { duration = value }
            record("Capabilities \(availableRates) · duration \(duration.map { formatted($0) } ?? "unknown")")
        case "state":
            guard let code = event["state"] as? Int, let newState = PlayerState(rawValue: code) else { return }
            let eventTime = event["time"] as? Double ?? mediaTime
            receiveState(newState, at: eventTime)
        case "sample":
            guard isActive, let time = event["time"] as? Double, time.isFinite,
                  let code = event["state"] as? Int, let sampleState = PlayerState(rawValue: code)
            else { return }
            mediaTime = time
            if let rate = event["rate"] as? Double, rate.isFinite && rate > 0 { actualRate = rate }
            takeSample(state: sampleState, time: time)
        case "rate":
            if let rate = event["rate"] as? Double, rate.isFinite && rate > 0 {
                actualRate = rate
                record("Rate confirmed \(rate)")
            }
        case "rateUnavailable":
            status = "Saved rate unavailable. Choose a supported speed."
            record("Rate unavailable \(event["requested"] ?? "?")")
        case "autoplayBlocked":
            stopLoop()
            status = "Scripted play was blocked. Press Play in the YouTube player."
            record("Scripted playback blocked")
        case "scriptFailed":
            fail("Could not load the YouTube API. Check your connection and retry.")
        case "error":
            let code = event["code"] as? Int ?? 0
            switch code {
            case 100: fail("Video unavailable or private (100).")
            case 101, 150: fail("This video does not allow embedding (\(code)).")
            case 153: fail("YouTube did not receive the required app identification (153).")
            default: fail("YouTube playback error (\(code)).")
            }
        default:
            break
        }
    }

    private func receiveState(_ newState: PlayerState, at time: Double) {
        state = newState
        record("State \(newState) at \(formatted(time))")
        if newState == .playing, !isActive {
            pause()
            return
        }
        switch newState {
        case .playing:
            status = "Playing"
            if experiment?.strategy == .bounded {
                _ = experiment?.sample(mediaTime: time, uptime: ProcessInfo.processInfo.systemUptime, isPlaying: true)
            }
        case .paused:
            status = "Paused"
            if !awaitingBoundedStart { stopLoop() }
        case .buffering:
            status = "Buffering…"
        case .ended:
            status = "Playback ended"
            let now = ProcessInfo.processInfo.systemUptime
            if isActive, let action = experiment?.reachedEnd(mediaTime: time, uptime: now), let range = experiment?.range {
                wrapStartedAt = now
                record("End sampled at \(formatted(time))")
                if action == .replaySegment {
                    requestSegment(range)
                } else if action == .restartAfterEnd {
                    send("restart", data: ["start": range.start], tiedToLoop: true)
                }
            } else if !awaitingBoundedStart {
                stopLoop()
            }
        case .unstarted, .cued:
            break
        }
    }

    private func takeSample(state: PlayerState, time: Double) {
        guard let range = experiment?.range else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if awaitingBoundedStart {
            if self.state == .playing, state == .playing, time >= max(0, range.start - 2),
               time < range.end, time <= range.start + 0.5 {
                awaitingBoundedStart = false
                deadline = nil
                finishWrap(at: time, uptime: now)
            } else if let deadline, now > deadline {
                record("Bounded reload timed out")
                stopLoop()
                status = "Segment reload timed out."
            }
            return
        }
        switch experiment?.sample(mediaTime: time, uptime: now, isPlaying: state == .playing, videoDuration: duration) {
        case .seekToStart:
            wrapStartedAt = now
            record("Seek B sampled at \(formatted(time))")
            if let next = experiment?.range {
                send("seek", data: ["start": next.start], tiedToLoop: true)
            }
        case .arrived:
            finishWrap(at: time, uptime: now)
        case .timedOut:
            record("Seek timed out")
            stopLoop()
            status = "Seek timed out."
        default:
            break
        }
    }

    private func requestSegment(_ range: LoopRange) {
        awaitingBoundedStart = true
        state = nil
        deadline = ProcessInfo.processInfo.systemUptime + 8
        send("segment", data: ["start": range.start, "end": range.end, "rate": requestedRate], tiedToLoop: true)
    }

    private func finishWrap(at start: Double, uptime: TimeInterval) {
        if let wrapStartedAt {
            wrapCount += 1
            record("Wrap \(wrapCount) · A sampled at \(formatted(start)) · command-to-sample \(formatted(uptime - wrapStartedAt)) s · observed rate \(actualRate)")
        } else {
            record("Initial A sampled at \(formatted(start))")
        }
        wrapStartedAt = nil
    }

    private func resetLoop() {
        loopToken = UUID()
        experiment = nil
        awaitingBoundedStart = false
        deadline = nil
        wrapStartedAt = nil
    }

    private func fail(_ message: String) {
        loadTimeout?.cancel()
        isReady = false
        state = nil
        stopLoop()
        status = message
        record(message)
    }

    private func send(_ command: String, data: [String: Double] = [:], tiedToLoop: Bool = false) {
        let commandSession = session
        let commandLoop = loopToken
        Task { [weak self] in
            guard let self, self.session == commandSession,
                  !tiedToLoop || self.loopToken == commandLoop else { return }
            do {
                _ = try await webView.callAsyncJavaScript(
                    "if (typeof configuration !== 'undefined' && configuration.session === token) window.runPlayerCommand(command, values)",
                    arguments: ["token": commandSession, "command": command, "values": data],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                guard self.session == commandSession else { return }
                self.record("Bridge error: \(error.localizedDescription)")
            }
        }
    }

    private func record(_ line: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - clockStart
        log.append(LogEntry(text: "\(formatted(elapsed))  \(line)"))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(3)).locale(Locale(identifier: "en_US_POSIX")))
    }
}
