import AppKit
import SwiftUI

@main
struct NarrateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("Narrate", id: "main") {
            ContentView()
                .environment(model)
                .onAppear { model.start() }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: ContentView.homeSize.width, height: ContentView.homeSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF…") { model.chooseFile() }.keyboardShortcut("o")
                Button("New Document") { model.closeReader() }.keyboardShortcut("n").disabled(!model.showReader)
            }
            CommandGroup(after: .saveItem) {
                Button("AirDrop Audio to Phone…") { model.airDrop() }.keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.narration == nil)
                Button("Export Audio Copy…") { model.exportCopy() }.keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.narration == nil)
                Button("Show Audio in Finder") { model.revealInFinder() }.keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.narration == nil)
            }
            CommandGroup(replacing: .help) {
                Button("Show Engine Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppModel.supportDir.appendingPathComponent("engine.log")])
                }
            }
        }

        Window("Narrate Browser", id: "browser") {
            BrowserWindow().environment(model)
        }
        .defaultSize(width: 1100, height: 820)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)   // never bring back an empty browser window on launch
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // PDFs (and Narrate audiobooks) opened from Finder / dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.open(urls) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.engine.stop()
        AppModel.shared.cleanupChunks()
    }
}

/// Switches between the setup screen and the reader, resizing the window to suit each.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var window: NSWindow?

    static let homeSize = CGSize(width: 560, height: 780)
    static let readerSize = CGSize(width: 1120, height: 800)

    var body: some View {
        Group {
            if model.showReader, let t = model.timeline {
                ReaderView(timeline: t)
            } else {
                HomeView()
            }
        }
        .background(WindowAccessor(window: $window))
        .onChange(of: model.showReader) { _, reading in
            resize(to: reading ? Self.readerSize : Self.homeSize, grow: reading)
        }
        .frame(minWidth: 520, minHeight: 600)
    }

    /// Resize around the window's current centre, staying on screen. When going to the reader we
    /// only ever grow; coming back we shrink to the compact layout.
    private func resize(to size: CGSize, grow: Bool) {
        guard let w = window else { return }
        var frame = w.frame
        if grow && frame.width >= size.width && frame.height >= size.height { return }
        let target = grow ? CGSize(width: max(frame.width, size.width), height: max(frame.height, size.height)) : size
        let center = CGPoint(x: frame.midX, y: frame.midY)
        frame = NSRect(x: center.x - target.width / 2, y: center.y - target.height / 2, width: target.width, height: target.height)
        if let screen = w.screen ?? NSScreen.main {
            let v = screen.visibleFrame
            frame.origin.x = max(v.minX, min(frame.origin.x, v.maxX - frame.width))
            frame.origin.y = max(v.minY, min(frame.origin.y, v.maxY - frame.height))
        }
        w.setFrame(frame, display: true, animate: true)
    }
}

struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { window = v.window }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if window == nil { DispatchQueue.main.async { window = nsView.window } }
    }
}
