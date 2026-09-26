import AppKit
import Carbon.HIToolbox
import Combine
import SwiftTerm
import SwiftUI
import WebKit

// MARK: - Hotkey presets

struct HotKeyPreset {
    let id: String
    let label: String
    let keyCode: UInt32
    let mods: UInt32
}

let hotKeyPresets: [HotKeyPreset] = [
    .init(id: "ctrl-opt-space", label: "⌃⌥ Space", keyCode: UInt32(kVK_Space), mods: UInt32(controlKey | optionKey)),
    .init(id: "opt-space", label: "⌥ Space", keyCode: UInt32(kVK_Space), mods: UInt32(optionKey)),
    .init(id: "cmd-shift-space", label: "⌘⇧ Space", keyCode: UInt32(kVK_Space), mods: UInt32(cmdKey | shiftKey)),
    .init(id: "ctrl-opt-c", label: "⌃⌥ C", keyCode: UInt32(kVK_ANSI_C), mods: UInt32(controlKey | optionKey)),
    .init(id: "ctrl-opt-i", label: "⌃⌥ I", keyCode: UInt32(kVK_ANSI_I), mods: UInt32(controlKey | optionKey)),
    .init(id: "off", label: "Off", keyCode: 0, mods: 0),
]

// MARK: - Theme

struct Theme {
    let id: String
    let name: String
    let ink: NSColor     // chrome + terminal background
    let paper: NSColor   // primary text
    let dim: NSColor     // secondary text
    let accent: NSColor  // active tab, cursor, drop shadows
}

let themes: [Theme] = [
    .init(id: "tarmac", name: "tarmac",
          ink: NSColor(srgbRed: 0.071, green: 0.075, blue: 0.090, alpha: 1),
          paper: NSColor(srgbRed: 0.910, green: 0.902, blue: 0.878, alpha: 1),
          dim: NSColor(srgbRed: 0.478, green: 0.494, blue: 0.541, alpha: 1),
          accent: NSColor(srgbRed: 1.000, green: 0.706, blue: 0.294, alpha: 1)),
    .init(id: "bubblegum", name: "bubblegum",
          ink: NSColor(srgbRed: 0.098, green: 0.063, blue: 0.086, alpha: 1),
          paper: NSColor(srgbRed: 0.949, green: 0.894, blue: 0.922, alpha: 1),
          dim: NSColor(srgbRed: 0.502, green: 0.404, blue: 0.467, alpha: 1),
          accent: NSColor(srgbRed: 1.000, green: 0.361, blue: 0.596, alpha: 1)),
    .init(id: "phosphor", name: "phosphor",
          ink: NSColor(srgbRed: 0.020, green: 0.039, blue: 0.027, alpha: 1),
          paper: NSColor(srgbRed: 0.847, green: 0.910, blue: 0.851, alpha: 1),
          dim: NSColor(srgbRed: 0.290, green: 0.376, blue: 0.310, alpha: 1),
          accent: NSColor(srgbRed: 0.231, green: 1.000, blue: 0.486, alpha: 1)),
    .init(id: "pool", name: "pool",
          ink: NSColor(srgbRed: 0.039, green: 0.071, blue: 0.094, alpha: 1),
          paper: NSColor(srgbRed: 0.862, green: 0.910, blue: 0.925, alpha: 1),
          dim: NSColor(srgbRed: 0.357, green: 0.443, blue: 0.494, alpha: 1),
          accent: NSColor(srgbRed: 0.275, green: 0.847, blue: 1.000, alpha: 1)),
]

func currentTheme() -> Theme {
    let id = UserDefaults.standard.string(forKey: "theme") ?? "tarmac"
    return themes.first { $0.id == id } ?? themes[0]
}

// MARK: - Tabs config

// A tab is a terminal running `command` (empty -> plain shell), or one of:
//   type "notes"  native scratchpad persisted to notes.md
//   type "widget" polled `command` output rendered as text, every `refresh`s
//   type "web"    WKWebView pinned to `url` (session survives tab switches)
struct TabSpec: Codable, Equatable {
    var name: String
    var command: String?
    var type: String?
    var url: String?
    var refresh: Int?
    var isNotes: Bool { type == "notes" }
    var isWidget: Bool { type == "widget" }
    var isWeb: Bool { type == "web" }
}

enum Config {
    static let dir = NSHomeDirectory() + "/.config/atoll"
    static let tabsFile = dir + "/tabs.json"
    static let notesFile = dir + "/notes.md"

    static let defaultTabs: [TabSpec] = [
        .init(name: "Fleet", command: "~/.local/bin/claude agents", type: nil),
        .init(name: "Notes", command: nil, type: "notes"),
    ]

    static func loadTabs() -> [TabSpec] {
        guard let data = FileManager.default.contents(atPath: tabsFile),
              let tabs = try? JSONDecoder().decode([TabSpec].self, from: data),
              !tabs.isEmpty
        else { return defaultTabs }
        return tabs
    }

    static func save(_ tabs: [TabSpec]) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? (try? enc.encode(tabs))?.write(to: URL(fileURLWithPath: tabsFile))
    }

    // materialize the default config so "Edit Tabs…" has a file to open
    static func writeDefaultTabsIfMissing() {
        guard !FileManager.default.fileExists(atPath: tabsFile) else { return }
        save(defaultTabs)
    }

    // MARK: launch directory

    // Where new panes cd to. install.sh can seed the "launchDir" pref; if it
    // didn't (or the saved path has since gone away) fall back to the first
    // checkout root that actually exists, and to $HOME if none do.
    static let launchDirCandidates: [String] = ["Documents/git", "Documents/repos",
                                                "Developer", "repos", "dev", "src",
                                                "code", "projects"]
        .map { NSHomeDirectory() + "/" + $0 }

    static var defaultLaunchDir: String {
        launchDirCandidates.first(where: isDir) ?? NSHomeDirectory()
    }

    static var launchDir: String {
        guard let saved = UserDefaults.standard.string(forKey: "launchDir"), isDir(saved)
        else { return defaultLaunchDir }
        return saved
    }

    static func isDir(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }
}

// MARK: - Model

final class Store: ObservableObject {
    @Published var expanded = false
    @Published var resizing = false // drag in progress: show bare black box
    @Published var tabs: [TabSpec]
    @Published var selected: String {
        didSet { UserDefaults.standard.set(selected, forKey: "selectedTab") }
    }
    @Published var autoFocus: Bool = UserDefaults.standard.object(forKey: "autoFocus") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoFocus, forKey: "autoFocus") }
    }
    @Published var hotkey: String = UserDefaults.standard.string(forKey: "hotkey") ?? "ctrl-opt-space" {
        didSet { UserDefaults.standard.set(hotkey, forKey: "hotkey") }
    }
    @Published var launchDir: String = Config.launchDir {
        didSet {
            UserDefaults.standard.set(launchDir, forKey: "launchDir")
            repoChoices = Store.repoChoices(for: launchDir)
        }
    }
    @Published var themeID: String = UserDefaults.standard.string(forKey: "theme") ?? "tarmac" {
        didSet { UserDefaults.standard.set(themeID, forKey: "theme") }
    }
    var theme: Theme { themes.first { $0.id == themeID } ?? themes[0] }
    // brutalist slabs vs soft corners; pill/panel/chip radii follow
    @Published var sharpCorners: Bool = UserDefaults.standard.object(forKey: "sharpCorners") as? Bool ?? false {
        didSet { UserDefaults.standard.set(sharpCorners, forKey: "sharpCorners") }
    }
    // off: the collapsed pill hides inside the notch and the expanded island
    // hangs below the menu bar instead of covering it
    @Published var overMenuBar: Bool = UserDefaults.standard.object(forKey: "overMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(overMenuBar, forKey: "overMenuBar") }
    }
    var pillRadius: CGFloat { sharpCorners ? 4 : 18 }
    var panelRadius: CGFloat { sharpCorners ? 2 : 14 }
    var chipRadius: CGFloat { sharpCorners ? 1 : 8 }
    // tabs with a live process (drives the activity dots on the collapsed pill)
    @Published var livePanes: Set<String> = []
    // transient message pushed over the atoll socket, shown on the pill
    @Published var flash: String?
    private var flashTimer: Timer?

    func showFlash(_ msg: String) {
        flash = msg
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            self?.flash = nil
        }
    }
    // startup policy: which tab is selected on launch, and whether its process
    // is spawned up front. Defaults touch nothing until the user expands.
    @Published var startSelection: String =
        UserDefaults.standard.string(forKey: "startSelection") ?? "last" {
        didSet { UserDefaults.standard.set(startSelection, forKey: "startSelection") }
    }
    @Published var warmStart: Bool = UserDefaults.standard.object(forKey: "warmStart") as? Bool ?? false {
        didSet { UserDefaults.standard.set(warmStart, forKey: "warmStart") }
    }
    // user-dragged pane size; panel chrome is added around it
    @Published var termW: CGFloat = UserDefaults.standard.object(forKey: "termW") as? CGFloat ?? 556 {
        didSet { UserDefaults.standard.set(termW, forKey: "termW") }
    }
    @Published var termH: CGFloat = UserDefaults.standard.object(forKey: "termH") as? CGFloat ?? 440 {
        didSet { UserDefaults.standard.set(termH, forKey: "termH") }
    }
    // the current launch dir itself + every git repo directly under it, so the
    // menu keeps offering useful jumps wherever the user pointed Atoll
    @Published var repoChoices: [String] = Store.repoChoices(for: Config.launchDir)

    static func repoChoices(for root: String) -> [String] {
        let fm = FileManager.default
        let subs = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        let repos = subs.sorted().compactMap { name -> String? in
            let p = root + "/" + name
            return fm.fileExists(atPath: p + "/.git") ? p : nil
        }
        // home is always reachable, so the picker can never strand the user
        let home = NSHomeDirectory()
        return ([root] + repos + [home]).reduce(into: []) { acc, p in
            if !acc.contains(p) { acc.append(p) }
        }
    }

    // ~/Documents/git rather than /Users/me/Documents/git, and just the repo
    // name for the checkouts underneath
    static func menuLabel(for path: String, root: String) -> String {
        let home = NSHomeDirectory()
        guard path == root || path == home else {
            return (path as NSString).lastPathComponent
        }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    // "Other Folder…": pick any directory, not just a sibling checkout
    func chooseLaunchDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "New Atoll sessions will start here."
        panel.directoryURL = URL(fileURLWithPath: launchDir)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            launchDir = url.path
        }
    }

    init() {
        let t = Config.loadTabs()
        tabs = t
        // "last" resumes where the user left off; "first" always opens tab 1
        let sel = UserDefaults.standard.string(forKey: "startSelection") ?? "last"
        if sel == "last",
           let saved = UserDefaults.standard.string(forKey: "selectedTab"),
           t.contains(where: { $0.name == saved }) {
            selected = saved
        } else {
            selected = t[0].name
        }
    }

    var selectedTab: TabSpec { tabs.first { $0.name == selected } ?? tabs[0] }

    @Published var addingTab = false
    // CLI tools found on PATH, offered as one-click tabs in the + card
    @Published var foundTools: [String] = []

    func scanTools() {
        let candidates = ["herdr", "lazygit", "btop", "htop", "k9s", "yazi", "ranger"]
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "for t in \(candidates.joined(separator: " ")); do command -v $t >/dev/null 2>&1 && echo $t; done"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let found = out.split(separator: "\n").map(String.init)
            DispatchQueue.main.async { self.foundTools = found }
        }
    }

    func addTab(name: String, command: String, notes: Bool) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !tabs.contains(where: { $0.name == n }) else { return }
        let cmd = command.trimmingCharacters(in: .whitespaces)
        tabs.append(.init(
            name: n,
            command: notes || cmd.isEmpty ? nil : cmd,
            type: notes ? "notes" : nil))
        Config.save(tabs)
        selected = n
        addingTab = false
    }

    func removeTab(_ name: String) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.name == name }) else { return }
        tabs.remove(at: i)
        PaneHost.shared.shutdown(name)
        WebHost.shared.shutdown(name)
        Config.save(tabs)
        if selected == name { selected = tabs[0].name }
    }

    // flip one tab between interactive terminal and polled widget, same command
    func convertTab(_ tab: TabSpec) {
        guard let i = tabs.firstIndex(where: { $0.name == tab.name }) else { return }
        if tab.isWidget {
            tabs[i].type = nil
        } else {
            PaneHost.shared.shutdown(tab.name)
            tabs[i].type = "widget"
            if tabs[i].refresh == nil { tabs[i].refresh = 5 }
        }
        Config.save(tabs)
    }

    // pick up edits to tabs.json (called on each expand); panes of removed tabs die
    func reloadTabs() {
        let new = Config.loadTabs()
        guard new != tabs else { return }
        let removed = tabs.map(\.name).filter { n in !new.contains { $0.name == n } }
        tabs = new
        removed.forEach {
            PaneHost.shared.shutdown($0)
            WebHost.shared.shutdown($0)
        }
        if !new.contains(where: { $0.name == selected }) { selected = new[0].name }
    }
}

// MARK: - Embedded terminal panes

final class IslandTerminalView: LocalProcessTerminalView {
    // accessory app has no Edit menu, so ⌘V/⌘+/⌘- never reach their actions on their own
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v": paste(self); return true
            case "+", "=": PaneHost.shared.bumpFont(+1); return true
            case "-": PaneHost.shared.bumpFont(-1); return true
            case "0": PaneHost.shared.bumpFont(0); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // SwiftTerm only reports left-button events on macOS, so right-clicks fall
    // through NSView's default path into the island's SwiftUI context menu.
    // Forward them to the TUI when it asked for mouse events, swallow them
    // otherwise — the island menu lives on the chrome (pill, margins, tab bar).
    override func rightMouseDown(with event: NSEvent) { sendRightButton(event, release: false) }
    override func rightMouseUp(with event: NSEvent) { sendRightButton(event, release: true) }

    private func sendRightButton(_ event: NSEvent, release: Bool) {
        let t = getTerminal()
        // sendButtonPress()/sendButtonRelease() are internal to SwiftTerm; same checks
        let m = t.mouseMode
        let wants = release ? m != .off : (m == .vt200 || m == .buttonEventTracking || m == .anyEvent)
        guard wants else { return }
        let p = convert(event.locationInWindow, from: nil)
        let col = max(0, min(t.cols - 1, Int(p.x / (bounds.width / CGFloat(t.cols)))))
        let row = max(0, min(t.rows - 1, Int((bounds.height - p.y) / (bounds.height / CGFloat(t.rows)))))
        // xterm right button is 2 (macOS buttonNumber says 1, so encode explicitly)
        let flags = t.encodeButton(
            button: 2, release: release,
            shift: event.modifierFlags.contains(.shift),
            meta: event.modifierFlags.contains(.option),
            control: event.modifierFlags.contains(.control))
        t.sendEvent(buttonFlags: flags, x: col, y: row)
    }

    // image on the clipboard (e.g. a screenshot): Claude Code reads the clipboard
    // itself when it sees ^V, so replay ⌘V as a ^V keypress and let it do the work
    override func paste(_ sender: Any) {
        let pb = NSPasteboard.general
        if pb.string(forType: .string) == nil, NSImage(pasteboard: pb) != nil {
            if let ev = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0, context: nil,
                characters: "\u{16}", charactersIgnoringModifiers: "v",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_V)) {
                keyDown(with: ev)
            }
            return
        }
        super.paste(sender)
    }
}

// One live terminal per tab, spawned on first use and kept running across
// tab switches; only the selected one is attached to the view hierarchy.
// Terminal panes share the theme ink so the island reads as one slab
var terminalBG: NSColor = currentTheme().ink

final class PaneHost: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = PaneHost()
    private(set) var terms: [String: LocalProcessTerminalView] = [:]
    // fired whenever the set of live panes changes (pill activity dots)
    var onLiveChange: (() -> Void)?

    var fontSize: CGFloat = UserDefaults.standard.object(forKey: "fontSize") as? CGFloat ?? 10

    // SF Mono has no Nerd Font glyphs (herdr's sidebar icons render as "?"
    // boxes); prefer an installed Nerd Font like Terminal.app does
    func paneFont(_ size: CGFloat) -> NSFont {
        NSFont(name: "JetBrainsMonoNL Nerd Font", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // ⌘+/⌘-/⌘0 zoom for every pane; delta 0 resets
    func bumpFont(_ delta: CGFloat) {
        fontSize = delta == 0 ? 10 : min(max(fontSize + delta, 7), 24)
        UserDefaults.standard.set(fontSize, forKey: "fontSize")
        for t in terms.values {
            t.font = paneFont(fontSize)
        }
    }

    // theme change: recolor live panes in place
    func applyTheme(_ t: Theme) {
        for term in terms.values { term.nativeBackgroundColor = t.ink }
    }

    func terminal(for tab: TabSpec) -> LocalProcessTerminalView {
        if let v = terms[tab.name] { return v }
        // boot at the persisted size so TUIs lay out right before first expand
        let w = UserDefaults.standard.object(forKey: "termW") as? CGFloat ?? 556
        let h = UserDefaults.standard.object(forKey: "termH") as? CGFloat ?? 440
        let t = IslandTerminalView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        t.processDelegate = self
        t.font = paneFont(fontSize)
        t.nativeBackgroundColor = terminalBG
        var env = ProcessInfo.processInfo.environment
        // `open` from a herdr pane leaks HERDR_* into the app; panes would then
        // look like nested herdr sessions
        for k in env.keys where k.hasPrefix("HERDR_") { env.removeValue(forKey: k) }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let cwd = Config.launchDir
        let cmd = (tab.command?.isEmpty == false) ? tab.command! : "zsh -il"
        t.startProcess(
            executable: "/bin/zsh",
            args: ["-lc", "cd '\(cwd)' && exec \(cmd)"],
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: nil)
        terms[tab.name] = t
        onLiveChange?()
        return t
    }

    func shutdown(_ name: String) {
        // TUIs like `claude agents` are singletons; an orphan blocks the next launch
        if let v = terms.removeValue(forKey: name) {
            kill(v.process.shellPid, SIGHUP)
            onLiveChange?()
        }
    }

    func shutdownAll() { Array(terms.keys).forEach { shutdown($0) } }

    // respawn on next attach if the process exits
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if let k = terms.first(where: { $0.value === source })?.key {
            terms.removeValue(forKey: k)
            onLiveChange?()
        }
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

struct TerminalPane: NSViewRepresentable {
    let tab: TabSpec
    func makeNSView(context: Context) -> LocalProcessTerminalView { PaneHost.shared.terminal(for: tab) }
    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
}

// MARK: - Notes pane

struct NotesPane: View {
    @ObservedObject var store: Store
    @State private var text = (try? String(contentsOfFile: Config.notesFile, encoding: .utf8)) ?? ""
    @State private var savedFlash = false
    @FocusState private var focused: Bool

    var body: some View {
        let t = store.theme
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(nsColor: t.paper))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: t.ink))
                .focused($focused)
                .padding(.horizontal, 4)
            Rectangle().fill(Color(nsColor: t.paper).opacity(0.14)).frame(height: 1)
            HStack(spacing: 6) {
                Text("-- notes.md · autosaves --")
                Spacer()
                Text("✓ saved")
                    .foregroundStyle(Color(nsColor: t.accent))
                    .opacity(savedFlash ? 1 : 0)
            }
            .font(mono(9))
            .foregroundStyle(Color(nsColor: t.dim))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
        }
        .onChange(of: text) { _, newText in
            try? newText.write(toFile: Config.notesFile, atomically: true, encoding: .utf8)
            savedFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { savedFlash = false }
        }
        .onChange(of: store.expanded) { _, e in if e { focused = true } }
        .onAppear { if store.expanded { focused = true } }
    }
}

// monospace chrome font; the island UI speaks terminal
func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

// MARK: - Widget pane

// A widget is a command polled on an interval, its output shown as text.
// No pty: cheap enough to keep several running as ambient islands
// (git status, disk space, CI state via curl, ...).
struct WidgetPane: View {
    let tab: TabSpec
    @State private var out = ""
    @State private var ranAt = ""
    // drops stale results if a tick lands while the previous run is still going
    @State private var gen = 0

    var body: some View {
        let t = currentTheme()
        let interval = max(1, tab.refresh ?? 5)
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                Text(out.isEmpty ? "-- waiting for first refresh --" : out)
                    .font(mono(11))
                    .foregroundStyle(Color(nsColor: t.paper))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .textSelection(.enabled)
            }
            Rectangle().fill(Color(nsColor: t.paper).opacity(0.14)).frame(height: 1)
            HStack(spacing: 6) {
                Text("-- \(tab.name.lowercased()) · every \(interval)s")
                Spacer()
                Text(ranAt)
            }
            .font(mono(9))
            .foregroundStyle(Color(nsColor: t.dim))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
        }
        .background(Color(nsColor: t.ink))
        .onAppear { tick() }
        .onChange(of: tab.command) { _, _ in tick() } // tabs.json edits re-run
        .onReceive(Timer.publish(every: TimeInterval(interval), on: .main, in: .common).autoconnect()) { _ in
            tick()
        }
    }

    func tick() {
        gen += 1
        let g = gen
        let cmd = (tab.command?.isEmpty == false) ? tab.command! : "echo 'set \"command\" in tabs.json'"
        let cwd = Config.launchDir
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "cd '\(cwd)' && exec \(cmd)"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch {
                DispatchQueue.main.async { if g == self.gen { self.out = "\(error)" } }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak p] in
                if p?.isRunning == true { p?.terminate() } // don't let widgets hang forever
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data.prefix(64 * 1024), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard g == self.gen else { return }
                self.out = s.trimmingCharacters(in: .whitespacesAndNewlines)
                self.ranAt = DateFormatter.localizedString(
                    from: Date(), dateStyle: .none, timeStyle: .medium)
            }
        }
    }
}

// MARK: - Web pane

// One WKWebView per web tab, kept alive across tab switches so logins and
// scroll position survive; created lazily on first expand like terminals
final class WebHost: NSObject, WKUIDelegate {
    static let shared = WebHost()
    private(set) var webs: [String: WKWebView] = [:]

    // target=_blank / window.open: there is no second window, so open it in place
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func web(for tab: TabSpec) -> WKWebView {
        if let w = webs[tab.name] { return w }
        let w = WKWebView(frame: .zero)
        w.uiDelegate = self
        var s = tab.url ?? ""
        if !s.isEmpty && !s.contains("://") { s = "https://" + s }
        if let u = URL(string: s) { w.load(URLRequest(url: u)) }
        webs[tab.name] = w
        return w
    }

    func shutdown(_ name: String) { _ = webs.removeValue(forKey: name) }
    func shutdownAll() { webs.removeAll() }
}

struct WebPane: NSViewRepresentable {
    let tab: TabSpec
    func makeNSView(context: Context) -> WKWebView { WebHost.shared.web(for: tab) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

// MARK: - Views

struct IslandView: View {
    @ObservedObject var store: Store
    var notchH: CGFloat
    var onHover: (Bool) -> Void
    var onResize: (Bool) -> Void // ended?
    @State private var newName = ""
    @State private var newCommand = ""
    @FocusState private var commandFocus: Bool

    var body: some View {
        let t = store.theme
        // overlays don't inflate layout: a fixed-size child in a ZStack made the
        // root bigger than the pill window, pushing bottom content (and the
        // rounded corners) outside the visible frame
        UnevenRoundedRectangle(
            bottomLeadingRadius: store.expanded ? store.panelRadius : store.pillRadius,
            bottomTrailingRadius: store.expanded ? store.panelRadius : store.pillRadius)
            .fill(store.expanded ? Color(nsColor: t.ink) : Color.black)
            .overlay(alignment: .top) {
                // detached while collapsed: an invisible pane still re-laid-out on
                // every TUI redraw (~4% CPU idle). PaneHost keeps the terminal +
                // pty alive at the chosen size, so re-attaching never resizes it
                if store.expanded {
                    VStack(spacing: 6) {
                        tabBar
                        pane
                            .frame(width: store.termW, height: store.termH)
                            .overlay(alignment: .top) {
                                if store.addingTab { addCard.padding(.top, 4) }
                            }
                    }
                    .padding(.top, (store.overMenuBar ? notchH : 0) + 8)
                    .opacity(store.resizing ? 0 : 1)
                    .allowsHitTesting(!store.resizing)
                }
            }
            .overlay(alignment: .bottom) { if !store.expanded && store.overMenuBar { pillDots } }
            .overlay(alignment: .bottomTrailing) {
                if store.expanded { resizeGrip }
            }
            .onHover { onHover($0) }
            .contextMenu {
                Toggle("Auto-focus keyboard on hover", isOn: $store.autoFocus)
                Picker("New sessions start in", selection: $store.launchDir) {
                    ForEach(store.repoChoices, id: \.self) { p in
                        Text(Store.menuLabel(for: p, root: store.launchDir)).tag(p)
                    }
                }
                Button("Choose Start Folder…") { store.chooseLaunchDir() }
                Picker("Toggle Shortcut", selection: $store.hotkey) {
                    ForEach(hotKeyPresets, id: \.id) { p in
                        Text(p.label).tag(p.id)
                    }
                }
                Divider()
                Picker("On Launch, Show", selection: $store.startSelection) {
                    Text("Last Used Tab").tag("last")
                    Text("First Tab").tag("first")
                }
                Toggle("Pre-Warm Panes at Launch", isOn: $store.warmStart)
                Divider()
                Picker("Theme", selection: $store.themeID) {
                    ForEach(themes, id: \.id) { th in Text(th.name).tag(th.id) }
                }
                Toggle("Sharp corners", isOn: $store.sharpCorners)
                Toggle("Show Over Menu Bar", isOn: $store.overMenuBar)
                Divider()
                Button("Edit Tabs…") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Config.tabsFile))
                }
                Button("Quit Atoll") { NSApp.terminate(nil) }
            }
    }

    @ViewBuilder var pane: some View {
        let tab = store.selectedTab
        if tab.isNotes {
            NotesPane(store: store).id(tab.name)
        } else if tab.isWidget {
            WidgetPane(tab: tab).id(tab.name)
        } else if tab.isWeb {
            WebPane(tab: tab)
                .id(tab.name)
                .contextMenu {
                    Button("Back") { WebHost.shared.webs[tab.name]?.goBack() }
                    Button("Reload") { WebHost.shared.webs[tab.name]?.reload() }
                    if let s = tab.url, let u = URL(string: s.contains("://") ? s : "https://" + s) {
                        Button("Open in Browser") { NSWorkspace.shared.open(u) }
                    }
                }
        } else {
            // dir change -> fresh terminal + process
            TerminalPane(tab: tab).id(tab.name + "|" + store.launchDir)
        }
    }

    var tabBar: some View {
        let t = store.theme
        return HStack(spacing: 6) {
            ForEach(store.tabs, id: \.name) { tab in
                let active = store.selected == tab.name
                Button { store.selected = tab.name } label: {
                    HStack(spacing: 4) {
                        Text(paneGlyph(tab))
                        Text(tab.name)
                        if active {
                            BlinkCursor(color: SwiftUI.Color(nsColor: t.ink), size: 9)
                        }
                    }
                    .font(mono(10, .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        active ? Color(nsColor: t.accent) : Color(nsColor: t.paper).opacity(0.07),
                        in: RoundedRectangle(cornerRadius: store.chipRadius))
                    .foregroundStyle(active ? Color(nsColor: t.ink) : Color(nsColor: t.dim))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Remove \"\(tab.name)\"") { store.removeTab(tab.name) }
                    // same command, no pty: turn a one-shot tool into a live island
                    if !tab.isNotes && !tab.isWeb {
                        Button(tab.isWidget ? "Use as Terminal" : "Use as Widget") {
                            store.convertTab(tab)
                        }
                    }
                }
            }
            Button {
                withAnimation(.easeOut(duration: 0.12)) { store.addingTab.toggle() }
            } label: {
                Text("+")
                    .font(mono(11, .bold))
                    .foregroundStyle(store.addingTab ? Color(nsColor: t.accent) : Color(nsColor: t.dim))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 22)
    }

    // collapsed pill: one dot per live pane, accent for the selected tab,
    // plus a blinking cursor so the slab feels alive. A CLI flash takes over.
    var pillDots: some View {
        Group {
            if let f = store.flash {
                Text(f)
                    .font(mono(9, .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Color(nsColor: store.theme.accent),
                        in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(Color(nsColor: store.theme.ink))
                    .lineLimit(1)
            } else {
                HStack(spacing: 4) {
                    ForEach(store.tabs.filter { store.livePanes.contains($0.name) }, id: \.name) { tab in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(tab.name == store.selected
                                  ? Color(nsColor: store.theme.accent)
                                  : Color(nsColor: store.theme.paper).opacity(0.35))
                            .frame(width: 5, height: 5)
                    }
                    BlinkCursor(color: Color(nsColor: store.theme.accent), size: 7)
                }
            }
        }
        .padding(.bottom, notchH > 0 ? 5 : 6)
    }

    func paneGlyph(_ tab: TabSpec) -> String {
        tab.isNotes ? "✎" : tab.isWidget ? "↻" : tab.isWeb ? "◎" : "❯"
    }

    // + card: one-click chips for tools found on PATH, custom row below.
    // Drawn inside the panel — a popover would be its own window, the panel
    // would lose key status, and the collapse timer would fold the island.
    var addCard: some View {
        let t = store.theme
        // one hair lighter than ink so the card reads against the slab
        let card = Color(nsColor: t.ink.blended(withFraction: 0.045, of: .white) ?? t.ink)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("new tab")
                    .font(mono(11, .bold))
                    .foregroundStyle(Color(nsColor: t.paper))
                Spacer()
                Button { cancelNewTab() } label: {
                    Text("✕")
                        .font(mono(10, .bold))
                        .foregroundStyle(Color(nsColor: t.dim))
                }
                .buttonStyle(.plain)
            }
            if !suggestions.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        Button { addSuggestion(s) } label: {
                            Text(s)
                                .font(mono(10))
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BrutalChip(corner: store.chipRadius))
                    }
                }
            } else {
                Text("type a command below · name is optional")
                    .font(mono(10))
                    .foregroundStyle(Color(nsColor: t.dim))
            }
            HStack(spacing: 8) {
                TextField("command, e.g. dbq dev", text: $newCommand)
                    .focused($commandFocus)
                TextField(newCommand.isEmpty ? "name" : derivedName, text: $newName)
                    .frame(width: 76)
                Button("add") { submitNewTab() }
                    .buttonStyle(BrutalChip(corner: store.chipRadius))
                    .disabled(!canAdd)
            }
            .textFieldStyle(.plain)
            .font(mono(11))
            .foregroundStyle(Color(nsColor: t.paper))
        }
        .padding(12)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: store.chipRadius + 2).fill(card))
        .overlay(
            RoundedRectangle(cornerRadius: store.chipRadius + 2)
                .strokeBorder(Color(nsColor: t.paper), lineWidth: 1))
        .background(
            RoundedRectangle(cornerRadius: store.chipRadius + 2)
                .fill(Color(nsColor: t.accent))
                .offset(x: 4, y: 4))
        .onSubmit { submitNewTab() }
        .onExitCommand { cancelNewTab() }
        .onAppear {
            store.scanTools() // tools installed since launch show up as chips
            // panel only becomes key a beat after the + click; focus too early is dropped
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { commandFocus = true }
        }
    }

    // PATH tools + the built-in pane types, minus tabs that already exist
    var suggestions: [String] {
        (store.foundTools + ["Shell", "Notes"]).filter { s in
            !store.tabs.contains { $0.name.caseInsensitiveCompare(s) == .orderedSame }
        }
    }

    func addSuggestion(_ s: String) {
        switch s {
        case "Notes": store.addTab(name: "Notes", command: "", notes: true)
        case "Shell": store.addTab(name: "Shell", command: "", notes: false)
        default: store.addTab(name: s, command: s, notes: false)
        }
        cancelNewTab()
    }

    // name left blank → the command itself (or "Shell"), suffixed until unique
    var derivedName: String {
        let cmd = newCommand.trimmingCharacters(in: .whitespaces)
        let base = cmd.isEmpty ? "Shell" : cmd
        var n = base, i = 2
        while store.tabs.contains(where: { $0.name == n }) { n = "\(base) \(i)"; i += 1 }
        return n
    }

    var tabName: String {
        let n = newName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? derivedName : n
    }

    var canAdd: Bool { !store.tabs.contains { $0.name == tabName } }

    func submitNewTab() {
        guard canAdd else { return }
        store.addTab(name: tabName, command: newCommand, notes: false)
        cancelNewTab()
    }

    func cancelNewTab() {
        store.addingTab = false
        newName = ""
        newCommand = ""
    }

    // drag to resize the expanded island; AppDelegate tracks the mouse in screen
    // coords (gesture translation is useless inside a live-resizing view)
    var resizeGrip: some View {
        Text("◢")
            .font(mono(9, .bold))
            .foregroundStyle(Color(nsColor: store.theme.dim))
            .padding(8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onResize(false) }
                    .onEnded { _ in onResize(true) })
    }
}

// square chip with a 1px paper border and a hard accent drop-block;
// pressing collapses the offset so the face lands on the shadow
struct BrutalChip: ButtonStyle {
    var corner: CGFloat
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let t = currentTheme()
        configuration.label
            .foregroundStyle(Color(nsColor: t.paper).opacity(enabled ? 1 : 0.35))
            .background(RoundedRectangle(cornerRadius: corner).fill(Color(nsColor: t.ink)))
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(Color(nsColor: t.paper).opacity(enabled ? 1 : 0.35), lineWidth: 1))
            .background(
                RoundedRectangle(cornerRadius: corner)
                    .fill(Color(nsColor: t.accent))
                    .opacity(enabled ? 1 : 0.25)
                    .offset(x: configuration.isPressed ? 0 : 2,
                            y: configuration.isPressed ? 0 : 2))
            .offset(y: configuration.isPressed ? 2 : 0)
    }
}

// terminal cursor block that blinks on a fixed clock (no timers to manage)
struct BlinkCursor: View {
    var color: SwiftUI.Color
    var size: CGFloat
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.1)) { ctx in
            Text("▮")
                .font(mono(size))
                .foregroundStyle(color)
                .opacity(ctx.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.1) < 0.65 ? 1 : 0.15)
        }
    }
}

// MARK: - App

final class IslandPanel: NSPanel {
    // borderless panels refuse key status by default; without it SwiftUI taps never fire
    override var canBecomeKey: Bool { true }

    // An accessory app has no Edit menu, and ⌘C/⌘V/… only reach text fields
    // and web panes through one. Views that handle a shortcut themselves
    // (terminal panes) get it first via super; the rest go to the responder chain.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }
        let shift = flags.contains(.shift)
        let action: Selector?
        switch (key, shift) {
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("a", false): action = #selector(NSText.selectAll(_:))
        case ("z", false): action = Selector(("undo:"))
        case ("z", true): action = Selector(("redo:"))
        default: action = nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    // without this, the first click on the non-active panel is swallowed as an activation click
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    let store = Store()
    var hovering = false
    var bag = Set<AnyCancellable>()

    var screen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }
    var notchH: CGFloat { max(screen.safeAreaInsets.top, 0) }
    var notchW: CGFloat {
        let s = screen
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return s.frame.width - l.width - r.width
        }
        return 160
    }
    // tab bar (22) + gap (6) between the notch padding and the pane
    let tabBarH: CGFloat = 28
    // menu-bar rows the expanded island covers: all of them, or none (hangs below)
    var topPad: CGFloat { store.overMenuBar ? notchH : 0 }
    var notchRect: NSRect {
        let sc = screen
        return NSRect(x: sc.frame.midX - notchW / 2, y: sc.frame.maxY - notchH, width: notchW, height: notchH)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = IslandView(
            store: store, notchH: notchH,
            onHover: { [weak self] hover in self?.hoverChanged(hover) },
            onResize: { [weak self] ended in self?.resizeDrag(ended: ended) })
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.sizingOptions = [] // never let SwiftUI intrinsic size fight setFrame
        panel.contentView = hosting
        // opt-in warm start: boot the selected pane's process before the first
        // expand. Default is cold: nothing spawns until the user expands.
        if store.warmStart, !store.selectedTab.isNotes {
            _ = PaneHost.shared.terminal(for: store.selectedTab)
        }
        store.scanTools() // populate the + card's suggestions
        PaneHost.shared.onLiveChange = { [weak self] in
            // processTerminated can arrive off-main; @Published needs main
            DispatchQueue.main.async {
                self?.store.livePanes = Set(PaneHost.shared.terms.keys)
            }
        }
        store.livePanes = Set(PaneHost.shared.terms.keys)
        applyHotKey()
        store.$hotkey
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyHotKey() }
            .store(in: &bag)
        store.$overMenuBar
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in guard let self else { return }; self.setExpanded(self.store.expanded) }
            .store(in: &bag)

        // live panes recolor when the theme changes
        store.$themeID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                if let t = themes.first(where: { $0.id == id }) {
                    PaneHost.shared.applyTheme(t)
                    terminalBG = t.ink
                    self?.refreshGhostChrome()
                }
            }
            .store(in: &bag)
        store.$sharpCorners
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshGhostChrome() }
            .store(in: &bag)

        // kill the old processes before SwiftUI (.id change) attaches fresh ones
        store.$launchDir
            .dropFirst()
            .sink { _ in PaneHost.shared.shutdownAll() }
            .store(in: &bag)

        // the + form needs key status for its text fields before any field click
        store.$addingTab
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] adding in
                guard let self, adding else { return }
                self.typedSinceExpand = true // pin open while the form is up
                self.panel.makeKey()
                // steal the keyboard back from the pane so @FocusState can take it
                self.panel.makeFirstResponder(self.panel.contentView)
            }
            .store(in: &bag)

        // switching tabs while expanded moves the keyboard to the new pane
        store.$selected
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.store.expanded else { return }
                self.focusPrompt()
            }
            .store(in: &bag)
        setExpanded(false)
        panel.orderFrontRegardless()
        startLauncherWatch()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.typedSinceExpand = true
            return e
        }

        // collapse when keyboard focus leaves the embedded pane (click in another app)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            self?.scheduleCollapse()
        }

        startCommandSocket()
    }

    // MARK: atoll command socket
    //
    // A tiny AF_UNIX server (~/.config/atoll/atoll.sock) so scripts can drive
    // the island:  atollctl <toggle|expand|collapse|select <tab>|flash <msg>|status>
    func startCommandSocket() {
        let path = Config.dir + "/atoll.sock"
        try? FileManager.default.removeItem(atPath: path) // stale socket from a crash
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            path.utf8CString.withUnsafeBufferPointer { src in
                let n = min(src.count - 1, ptr.count - 1)
                ptr.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: n)
            }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return }
        DispatchQueue.global(qos: .utility).async {
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { break }
                DispatchQueue.global().async {
                    defer { close(c) }
                    self.handleCommandConn(c)
                }
            }
        }
    }

    func handleCommandConn(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count - 1)
        guard n > 0 else { return }
        let line = String(decoding: buf[0..<n], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let reply = handleCommand(line)
        reply.data(using: .utf8)?.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, raw.count)
        }
    }

    func handleCommand(_ line: String) -> String {
        let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true) { $0 == " " }
        let cmd = parts.first.map(String.init) ?? ""
        let arg = parts.count > 1 ? String(parts[1]) : ""
        switch cmd {
        case "toggle":
            DispatchQueue.main.sync { toggleIsland() }
            return "ok\n"
        case "expand", "collapse":
            DispatchQueue.main.sync { setExpanded(cmd == "expand") }
            return "ok\n"
        case "select":
            guard !arg.isEmpty else { return "err: select needs a tab name\n" }
            var hit: String?
            DispatchQueue.main.sync {
                store.reloadTabs() // pick up tabs.json edits even while expanded
                if let t = store.tabs.first(where: { $0.name.lowercased() == arg.lowercased() }) {
                    hit = t.name
                    store.selected = t.name
                    setExpanded(true)
                    typedSinceExpand = true
                }
            }
            return hit != nil ? "ok\n" : "err: no tab named \(arg)\n"
        case "flash":
            guard !arg.isEmpty else { return "err: flash needs a message\n" }
            DispatchQueue.main.sync { store.showFlash(String(arg.prefix(48))) }
            return "ok\n"
        case "status":
            var out = ""
            DispatchQueue.main.sync {
                out = """
                expanded=\(store.expanded)
                selected=\(store.selected)
                tabs=\(store.tabs.map(\.name).joined(separator: ","))
                live=\(PaneHost.shared.terms.keys.sorted().joined(separator: ","))
                """
            }
            return out + "\n"
        default:
            return "err: unknown command '\(cmd)'. usage: atollctl <toggle|expand|collapse|select <tab>|flash <msg>|status>\n"
        }
    }

    var collapseTimer: Timer?
    var typedSinceExpand = false

    func applicationWillTerminate(_ notification: Notification) {
        PaneHost.shared.shutdownAll()
        WebHost.shared.shutdownAll()
    }

    func hoverChanged(_ h: Bool) {
        hovering = h
        if h {
            collapseTimer?.invalidate()
            collapseTimer = nil
            setExpanded(true)
        } else {
            scheduleCollapse()
        }
    }

    // SwiftUI hover events flap during the frame animation; trust the actual
    // mouse position instead and only collapse once it has really left.
    func scheduleCollapse() {
        guard collapseTimer == nil, store.expanded else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.dragStartSize != nil { return } // never collapse mid-resize
            let m = NSEvent.mouseLocation
            if self.panel.frame.insetBy(dx: -8, dy: -8).contains(m) { return }
            // below-menu-bar mode: the island hangs under the notch, so a cursor
            // parked in the notch is outside the frame but still "on" the island
            if self.notchRect.contains(m) { return }
            // pinned only when the user actually typed into the pane
            if self.panel.isKeyWindow && self.typedSinceExpand { return }
            self.collapseTimer?.invalidate()
            self.collapseTimer = nil
            self.setExpanded(false)
        }
    }

    // Launcher-style windows (Raycast sits at layer 8, Spotlight at 23) open
    // below our .statusBar panel. While another app shows a window above the
    // floating level that overlaps us, drop just beneath its layer; restore
    // once it's gone. Floating (3) and below is left alone so persistent
    // utility windows (PiP, reminders) don't keep us sunk. Their panels don't
    // activate, so nothing notifies us — poll the (cheap) on-screen list.
    var launcherTimer: Timer?

    func startLauncherWatch() {
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.yieldToOverlays() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        launcherTimer = t
    }

    func yieldToOverlays() {
        let base = NSWindow.Level.statusBar
        // CG window bounds are top-left based on the primary screen
        let f = panel.frame
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let ours = CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)
        let me = Int(getpid())
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let layers = list.compactMap { w -> Int? in
            guard let layer = w[kCGWindowLayer as String] as? Int,
                  layer > NSWindow.Level.floating.rawValue, layer < base.rawValue,
                  (w[kCGWindowOwnerPID as String] as? Int) != me,
                  // system chrome: menu bar, Dock
                  !["Window Server", "Dock"].contains(w[kCGWindowOwnerName as String] as? String ?? ""),
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.intersects(ours) else { return nil }
            return layer
        }
        let want = layers.min().map { NSWindow.Level(rawValue: $0 - 1) } ?? base
        if panel.level != want { panel.level = want }
    }

    // Resize drag: the real panel (SwiftUI + terminal) is expensive to resize
    // per mouse tick and flickers. So during the drag the panel goes invisible
    // and a dumb layer-backed black window tracks the mouse — pure window-server
    // ops, nothing re-renders. On release the panel snaps to the final size and
    // the pty reflows once, still hidden.
    var dragStartMouse: NSPoint?
    var dragStartSize: CGSize?

    lazy var ghost: NSPanel = {
        let g = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        g.level = .statusBar
        g.backgroundColor = .clear
        g.isOpaque = false
        g.hasShadow = false
        g.ignoresMouseEvents = true
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = terminalBG.cgColor
        v.layer?.cornerRadius = store.panelRadius
        v.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        g.contentView = v
        return g
    }()

    // keep the resize ghost in step with the current theme + corner pref
    func refreshGhostChrome() {
        guard let v = ghost.contentView else { return }
        v.wantsLayer = true
        v.layer?.backgroundColor = terminalBG.cgColor
        v.layer?.cornerRadius = store.panelRadius
    }

    func resizeDrag(ended: Bool) {
        let sc = screen
        if dragStartMouse == nil {
            dragStartMouse = NSEvent.mouseLocation
            dragStartSize = CGSize(width: store.termW, height: store.termH)
            store.resizing = true // hide the pane for the end-of-drag reflow
            ghost.setFrame(panel.frame, display: false)
            ghost.orderFrontRegardless()
            panel.alphaValue = 0 // keeps key status, unlike orderOut
        }
        guard let m0 = dragStartMouse, let s0 = dragStartSize else { return }
        let m = NSEvent.mouseLocation
        // panel is centered on the notch, so the right edge only moves half of
        // any width change — double dx so the grip stays under the cursor
        let w = min(max(400, s0.width + (m.x - m0.x) * 2), sc.frame.width - 64)
        let h = min(max(240, s0.height + (m0.y - m.y)), sc.frame.height * 0.8 - notchH - tabBarH - 24)
        if ended {
            dragStartMouse = nil
            dragStartSize = nil
            store.termW = w
            store.termH = h
            setExpanded(true) // snap panel to the final size, reflow the pty once
            panel.alphaValue = 1
            ghost.orderOut(nil)
            // let the TUI redraw at the new size before unveiling it
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.store.resizing = false
            }
            return
        }
        let pw = max(notchW + 40, w + 24)
        let ph = topPad + 8 + tabBarH + h + 16
        ghost.setFrame(
            NSRect(x: sc.frame.midX - pw / 2, y: sc.frame.maxY - (notchH - topPad) - ph, width: pw, height: ph),
            display: true)
    }

    func setExpanded(_ e: Bool) {
        let wasExpanded = store.expanded
        if e && !wasExpanded { store.reloadTabs() }
        store.expanded = e
        // hand the keyboard back to whatever app had it before auto-focus
        if !e, panel.isKeyWindow { panel.orderOut(nil) }
        let sc = screen
        let w: CGFloat
        let h: CGFloat
        var top: CGFloat = 0 // gap between screen top and the panel
        if e {
            w = max(notchW + 40, store.termW + 24)
            h = min(topPad + 8 + tabBarH + store.termH + 16, sc.frame.height * 0.8)
            top = notchH - topPad
        } else {
            w = store.overMenuBar ? notchW + 16 : notchW // exact notch = invisible
            h = notchH > 0 ? notchH : 22
        }
        let f = NSRect(
            x: sc.frame.midX - w / 2,
            y: sc.frame.maxY - top - h,
            width: w, height: h)
        if f != panel.frame {
            // animate only expand/collapse transitions; drag-resize must track 1:1
            panel.setFrame(
                f, display: true,
                animate: e != wasExpanded || (!e && panel.frame.width > 0))
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        if e && !wasExpanded {
            typedSinceExpand = false
            if store.autoFocus { focusPrompt() }
        }
    }

    // cursor straight into the selected pane — type immediately
    func focusPrompt() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.store.expanded else { return }
            self.panel.makeKey()
            // notes pane focuses itself via @FocusState once the panel is key
            if !self.store.selectedTab.isNotes,
               let t = PaneHost.shared.terms[self.store.selected] {
                self.panel.makeFirstResponder(t)
            }
        }
    }

    func toggleIsland() {
        if store.expanded {
            setExpanded(false)
        } else {
            setExpanded(true)
            typedSinceExpand = true // pin until the user clicks elsewhere or toggles
            focusPrompt() // explicit invocation always focuses, ignores autoFocus
        }
    }

    // `open`ing the app while it runs lands here — lets Raycast (or any
    // launcher hotkey bound to the app) toggle the island
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        toggleIsland()
        return false
    }

    var hotKeyRef: EventHotKeyRef?
    var hotKeyHandlerInstalled = false

    func applyHotKey() {
        if let r = hotKeyRef {
            UnregisterEventHotKey(r)
            hotKeyRef = nil
        }
        guard let p = hotKeyPresets.first(where: { $0.id == store.hotkey }), p.id != "off"
        else { return }
        if !hotKeyHandlerInstalled {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetEventDispatcherTarget(),
                { _, _, userData in
                    Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue().toggleIsland()
                    return noErr
                },
                1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
            hotKeyHandlerInstalled = true
        }
        RegisterEventHotKey(
            p.keyCode, p.mods,
            EventHotKeyID(signature: OSType(0x434C_4953), id: 1),
            GetEventDispatcherTarget(), 0, &hotKeyRef)
    }
}

// pkill sends SIGTERM which skips applicationWillTerminate; route it there
signal(SIGTERM, SIG_IGN)
let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigTerm.setEventHandler { NSApp.terminate(nil) }
sigTerm.resume()

Config.writeDefaultTabsIfMissing()

// one-time migration of prefs from the Claude Island days
if UserDefaults.standard.object(forKey: "termW") == nil,
   let old = UserDefaults(suiteName: "dev.pj.claude-island") {
    for k in ["autoFocus", "hotkey", "launchDir", "termW", "termH"] {
        if let v = old.object(forKey: k) { UserDefaults.standard.set(v, forKey: k) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
