import SwiftUI

enum VideoViewport {
    static func editorHeight(width: Double, scale: Double) -> Double {
        max(200, width * 9 / 16 * min(max(scale, 0.65), 1.4))
    }

    static func fitted(in size: CGSize) -> CGSize {
        guard size.width >= 200, size.height >= 200 else { return .zero }
        let width = min(size.width, size.height * 16 / 9)
        return CGSize(width: width, height: max(200, width * 9 / 16))
    }
}

struct PlayerFramePreference: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

enum FullScreenControls {
    static func shouldHide(playing: Bool, pointerOverControls: Bool, voiceOver: Bool) -> Bool {
        playing && !pointerOverControls && !voiceOver
    }
}

#if os(macOS)
struct FullScreenWindowObserver: NSViewRepresentable {
    let resolved: (NSWindow?) -> Void
    let changed: (Bool) -> Void
    let activity: () -> Void

    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.resolved = resolved
        view.changed = changed
        view.activity = activity
        return view
    }

    func updateNSView(_ view: WindowProbe, context: Context) {
        view.resolved = resolved
        view.changed = changed
        view.activity = activity
    }

    static func dismantleNSView(_ view: WindowProbe, coordinator: ()) { view.disconnect() }

    final class WindowProbe: NSView {
        var resolved: (NSWindow?) -> Void = { _ in }
        var changed: (Bool) -> Void = { _ in }
        var activity: () -> Void = {}
        private var observations: [NSObjectProtocol] = []
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            disconnect()
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            Task { @MainActor [weak self, weak window] in
                self?.resolved(window)
                if let window { self?.changed(window.styleMask.contains(.fullScreen)) }
            }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window else { return }
                        self.changed(window.styleMask.contains(.fullScreen))
                    }
                })
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window == self.window { self.activity() }
                }
                return event
            }
        }

        func disconnect() {
            observations.forEach(NotificationCenter.default.removeObserver)
            observations = []
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }
    }
}
#endif
