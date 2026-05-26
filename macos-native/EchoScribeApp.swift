import SwiftUI
import AppKit

@main
struct EchoScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Window("EchoScribe", id: "main-window") {
            ContentView()
                .frame(minWidth: 1024, minHeight: 700)
                .background(VisualEffectView().ignoresSafeArea())
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}

// Visual Effect View helper for macOS blur styling
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .underWindowBackground
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// AppDelegate to support Menu Bar controls natively
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "EchoScribe Recorder")
        button.action = #selector(menuBarAction)
        button.target = self
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show EchoScribe", action: #selector(showMainWindow), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc func menuBarAction() {
        showMainWindow()
    }
    
    @objc func showMainWindow() {
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main-window" }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Re-open if closed
            if let firstWindow = NSApplication.shared.windows.first {
                firstWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
