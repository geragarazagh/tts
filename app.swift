// TTS: text to speech on the Mac, offline, with Supertonic 3 voices. One window: voice and speed on top, the text in
// the middle, the player at the bottom.

import AppKit
import UniformTypeIdentifiers

@main
@MainActor final class App: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let d = App()
        app.delegate = d
        app.setActivationPolicy(.regular)
        app.run()
    }

    var window: MainWindow!

    func applicationWillFinishLaunching(_ n: Notification) {
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false, "voice": 0, "speed": Speed.standard])
        NSApp.mainMenu = makeMenu()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Model.removeParts()
        window = MainWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        _ = Updates.shared
        if let pending = pendingOpen { window.open(pending); pendingOpen = nil }
    }

    private var pendingOpen: URL?

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let u = urls.first else { return }
        if let w = window { w.open(u); w.makeKeyAndOrderFront(nil) } else { pendingOpen = u }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        Updates.shared.appOpened()
        return true
    }

    func applicationWillTerminate(_ n: Notification) {
        window?.shutDown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: menu

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = m
            main.addItem(i)
            return m
        }
        func item(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let services = item(L("Services"), nil)
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        let check = item(L("Check for Updates…"), #selector(Updates.check))
        check.target = Updates.shared
        _ = sub("TTS", [
            item(L("About TTS"), #selector(about)),
            check,
            .separator(),
            item(L("Show Model in Finder"), #selector(MainWindow.showModel)),
            item(L("Delete Model…"), #selector(MainWindow.deleteModel)),
            .separator(),
            services,
            .separator(),
            item(L("Hide TTS"), #selector(NSApplication.hide(_:)), "h"),
            item(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(L("Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(L("Quit TTS"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = sub(L("File"), [
            item(L("Open…"), #selector(MainWindow.openDocument(_:)), "o"),
            item(L("Save MP3…"), #selector(MainWindow.saveMP3), "s"),
            .separator(),
            item(L("Close"), #selector(NSWindow.performClose(_:)), "w"),
        ])
        let find = NSMenu(title: L("Find"))
        for (t, tag, k, m) in [(L("Find…"), 1, "f", NSEvent.ModifierFlags.command), (L("Find and Replace…"), 12, "f", [.command, .option]),
                               (L("Find Next"), 2, "g", .command), (L("Find Previous"), 3, "g", [.command, .shift]),
                               (L("Use Selection for Find"), 7, "e", .command)] {
            let i = item(t, #selector(NSTextView.performFindPanelAction(_:)), k, m)
            i.tag = tag
            find.addItem(i)
        }
        let findItem = item(L("Find"), nil)
        findItem.submenu = find
        _ = sub(L("Edit"), [
            item(L("Undo"), Selector(("undo:")), "z"),
            item(L("Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L("Cut"), #selector(NSText.cut(_:)), "x"),
            item(L("Copy"), #selector(NSText.copy(_:)), "c"),
            item(L("Paste"), #selector(NSText.paste(_:)), "v"),
            item(L("Delete"), #selector(NSText.delete(_:))),
            item(L("Select All"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            findItem,
        ])
        // Text size: TextEdit's own words and keys (Format > Font > Bigger ⌘+, Smaller ⌘−; View > Actual Size ⌘0).
        // ⌘= is the same key as ⌘+ without Shift; a hidden twin takes it, as browsers do.
        let same = item(L("Bigger"), #selector(MainWindow.biggerText(_:)), "=")
        same.isHidden = true
        same.allowsKeyEquivalentWhenHidden = true
        _ = sub(L("View"), [
            item(L("Actual Size"), #selector(MainWindow.actualSizeText(_:)), "0"),
            item(L("Bigger"), #selector(MainWindow.biggerText(_:)), "+"),
            same,
            item(L("Smaller"), #selector(MainWindow.smallerText(_:)), "-"),
            .separator(),
            item(L("Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let win = sub(L("Window"), [
            item(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L("Zoom"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(L("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = win
        return main
    }

    @objc func about() {
        let credits = NSMutableAttributedString()
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                   .foregroundColor: NSColor.labelColor, .paragraphStyle: p]
        func link(_ t: String, _ u: String) -> NSAttributedString {
            var a = base; a[.link] = URL(string: u)!
            return NSAttributedString(string: t, attributes: a)
        }
        credits.append(link(L("Herman Harazha"), "https://geragaraza.com"))
        credits.append(NSAttributedString(string: " · ", attributes: base))
        credits.append(link(L("GitHub"), "https://github.com/geragarazagh/tts"))
        credits.append(NSAttributedString(string: "\n", attributes: base))
        credits.append(NSAttributedString(string: L("Voices: Supertonic 3 by Supertone") + " · ", attributes: base))
        credits.append(link("OpenRAIL\u{2011}M", "https://huggingface.co/Supertone/supertonic-3/blob/main/LICENSE"))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}
