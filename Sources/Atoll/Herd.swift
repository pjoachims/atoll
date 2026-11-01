import AppKit
import SwiftTerm
import SwiftUI

// MARK: - Herd: herdr's screen, drawn from herdr-core (`hc`)
//
// herdr keeps its spaces, tabs and split layouts in herdr-core's "herdr-app"
// document and runs every pane as an hc terminal, so its whole TUI is a
// function of core state: the doc gives the structure, `hc events` the
// live status (OSC 7501), and each pane is an `hc attach` in a regular
// terminal view. Look and keys follow the herdr TUI's defaults (catppuccin
// mocha, dots, ctrl+b prefix); changes go through `herdr-app do`, so the
// app stays the one writing its own document.

struct HerdAgent: Identifiable, Equatable {
    let id: String      // core address: t7, or box/t7 on an added machine
    var app: String
    var state: String?  // nil: the program never reported a status (plain shells)
    var msg: String?    // what it said with its status: "Run migration on prod?"
    var title: String
    var place: String   // herdr's own "where" label: "repos_pj / 1"
    var spaceID: String?
    var cwd: String?    // where it is now (its foreground process), not where it started

    init(_ r: [String: Any]) {
        id = r["address"] as? String ?? "?"
        let status = r["status"] as? [String: Any]
        let fg = r["foreground"] as? [String: Any]
        // foreground "name" is the process title, which for claude is its version
        let argv0 = (fg?["argv"] as? [String])?.first ?? (r["argv"] as? [String])?.first ?? "?"
        app = status?["app"] as? String ?? (argv0 as NSString).lastPathComponent
        state = status?["state"] as? String
        msg = (status?["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        title = r["title"] as? String ?? ""
        let labels = r["labels"] as? [String: Any]
        place = labels?["where"] as? String ?? id
        spaceID = labels?["herdr.space"] as? String
        cwd = fg?["cwd"] as? String ?? r["cwd"] as? String
    }

    // herdr's agent labels: claude, codex, opencode, …
    var label: String { app.hasSuffix("-code") ? String(app.dropLast(5)) : app }
    var workspace: String? { place.components(separatedBy: " / ").first }
}

// herdr's layout tree: row, column, stack or block; a block holds a terminal
struct HerdNode: Identifiable {
    var id: String
    var kind: String
    var terminal: String?
    var children: [HerdNode]
    var weight: Double?
    var px: Double?
    var active: String?
    var hidden: Bool

    init(_ j: [String: Any]) {
        id = j["id"] as? String ?? UUID().uuidString
        kind = j["type"] as? String ?? "block"
        terminal = (j["content"] as? [String: Any])?["terminal"] as? String
        children = (j["children"] as? [[String: Any]] ?? []).map(HerdNode.init)
        let size = j["size"] as? [String: Any]
        weight = size?["weight"] as? Double
        px = size?["px"] as? Double
        active = j["active"] as? String
        hidden = j["hidden"] as? Bool ?? false
    }

    var visible: [HerdNode] { children.filter { !$0.hidden } }
    // what's on screen: a stack shows only its active child
    var shown: [String] {
        if let terminal { return [terminal] }
        if kind == "stack" {
            return (visible.first { $0.id == active } ?? visible.first)?.shown ?? []
        }
        return visible.flatMap(\.shown)
    }
    var terminals: [String] { (terminal.map { [$0] } ?? []) + children.flatMap(\.terminals) }

    // the block (pane id) holding a terminal: what pane.split/close target
    func block(of terminal: String) -> String? {
        if self.terminal == terminal { return id }
        return children.lazy.compactMap { $0.block(of: terminal) }.first
    }
}

struct HerdTab: Identifiable {
    var id: String
    var name: String
    var root: HerdNode
}

struct HerdSpace: Identifiable {
    var id: String
    var name: String
    var folder: String
    var tabs: [HerdTab]
}

struct HerdGit: Equatable {
    var branch: String
    var ahead = 0
    var behind = 0
    var root = ""     // the checkout's top level
    var repo = ""     // the main checkout this belongs to
    var linked = false // a worktree of `repo`, not the repo itself
}

func tilde(_ p: String) -> String {
    let home = NSHomeDirectory()
    return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
}

// one checkout of a repo (`git worktree list`): the main one, or a worktree
struct HerdCheckout: Hashable {
    var path: String
    var branch: String?
}

// a sidebar entry: worktree spaces hang under their repo's space
struct HerdSpaceRow: Identifiable {
    var space: HerdSpace
    var child: Bool
    var last: Bool        // last child: └─ instead of ├─
    var children: Int     // for a parent: how many hang under it
    var id: String { space.id }
}

// MARK: herdr's palette and status dots

enum Mocha {
    static func hex(_ v: UInt32) -> SwiftUI.Color {
        .init(.sRGB, red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255,
              blue: Double(v & 0xff) / 255)
    }
    static let accent = hex(0x89b4fa)
    static let panelBG = hex(0x181825)
    static let activeRow = hex(0x1e1e2e)
    static let surface0 = hex(0x313244)
    static let surfaceDim = hex(0x1e1e2e)
    static let overlay0 = hex(0x6c7086)
    static let overlay1 = hex(0x7f849c)
    static let text = hex(0xcdd6f4)
    static let subtext0 = hex(0xa6adc8)
    static let mauve = hex(0xcba6f7)
    static let green = hex(0xa6e3a1)
    static let yellow = hex(0xf9e2af)
    static let red = hex(0xf38ba8)
    static let teal = hex(0x94e2d5)
}

// herdr's states: "done" is idle that you haven't looked at yet
enum HerdState: Int, Comparable {
    case unknown, idle, working, done, blocked // ascending urgency

    static func < (a: HerdState, b: HerdState) -> Bool { a.rawValue < b.rawValue }

    init(_ reported: String?, seen: Bool) {
        switch reported {
        case "working": self = .working
        case "blocked", "error": self = .blocked
        case "done": self = seen ? .idle : .done
        case nil: self = .unknown
        default: self = .idle
        }
    }

    var icon: String { self == .idle ? "○" : self == .unknown ? "·" : "●" }
    var color: SwiftUI.Color {
        switch self {
        case .working: Mocha.yellow
        case .blocked: Mocha.red
        case .done: Mocha.teal
        case .idle: Mocha.green
        case .unknown: Mocha.overlay0
        }
    }
}

// the prefix keymap: herdr's defaults, as herdr-app actions or local view changes
let herdKeyHelp: [(String, String)] = [
    ("c", "new tab"), ("n / p", "next / previous tab"), ("1-9", "go to tab"),
    ("X", "close tab"), ("T", "rename tab"),
    ("N", "new space"), ("W", "rename space"), ("D", "close space"), ("G", "new worktree"),
    ("v", "split right"), ("-", "split down"), ("x", "close pane"), ("z", "zoom pane"),
    ("h j k l", "focus pane"), ("tab", "next pane"), ("b", "toggle sidebar"),
    ("ctrl+b", "send ctrl+b"), ("?", "this help"), ("esc", "cancel"),
]

final class HerdHost: ObservableObject {
    static let shared = HerdHost()
    @Published private(set) var agents: [String: HerdAgent] = [:]
    @Published private(set) var spaces: [HerdSpace] = []
    @Published private(set) var online = false
    @Published private(set) var missing = false // no hc on PATH
    @Published private(set) var git: [String: HerdGit] = [:] // by folder
    @Published private(set) var checkouts: [String: [HerdCheckout]] = [:] // by main checkout
    @Published var selectedSpace: String? = UserDefaults.standard.string(forKey: "herdSpace") {
        didSet { UserDefaults.standard.set(selectedSpace, forKey: "herdSpace") }
    }
    @Published var selectedTab: [String: String] = [:] // space id -> tab id
    @Published var focusedPane: String?
    @Published var zoomed: String?      // the one pane shown, or nil for the whole tab
    @Published var prefix = false        // ctrl+b pressed: the next key is a command
    @Published var help = false
    @Published var toast: String?        // last action's error, in the mode bar
    @Published var sidebarCollapsed = UserDefaults.standard.bool(forKey: "herdSidebarCollapsed") {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: "herdSidebarCollapsed") }
    }
    @Published var foldedRepos: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "herdFolded") ?? []) {
        didSet { UserDefaults.standard.set(Array(foldedRepos), forKey: "herdFolded") }
    }
    // done agents you've looked at turn idle, like herdr's "seen"
    @Published private(set) var seen: Set<String> = []
    var visible: Set<String> = [] { didSet { markSeen(visible) } }
    var keysActive = false // the herd pane is on screen
    // agent turned blocked or done after the first snapshot: flash the pill
    var onAlert: ((String) -> Void)?
    var onCollapse: (() -> Void)?

    // inbox (what needs you), one agent's pane, the composer, or herdr's whole screen
    @Published var mode: HerdMode = UserDefaults.standard.bool(forKey: "herdFull") ? .full : .inbox {
        didSet { UserDefaults.standard.set(mode == .full, forKey: "herdFull") }
    }
    @Published var inboxSelection: String?
    @Published private(set) var changed: [String: Date] = [:] // last status change, for "12s"
    var watchNext = false // the next space we create opens in focus

    private(set) var hc: String?
    private var herdrApp: String?
    private var records: [String: [String: Any]] = [:]
    private var proc: Process?
    private var connecting = false
    private var buffer = Data()
    private var enabled = false
    private var primed = false
    // what a create action is waiting to select once the doc shows it
    private enum Pending {
        case space(before: Set<String>)
        case tab(space: String, before: Set<String>)
        case pane(space: String, tab: String, before: Set<String>)
    }
    private var pending: Pending?
    private var gitAsked: Set<String> = [] // folders git has been run in (non-repos stay out of `git`)
    private var toastTimer: Timer?

    init() {
        // which split has the keyboard: a click inside a herd pane focuses it
        // (SwiftTerm's becomeFirstResponder can't be overridden)
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            for (key, v) in PaneHost.shared.terms where key.hasPrefix("herd:") && v.window === e.window {
                if v.bounds.contains(v.convert(e.locationInWindow, from: nil)) {
                    self?.focusedPane = String(key.dropFirst(5))
                }
            }
            return e
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.handleKey(e) ? nil : e
        }
    }

    func state(_ address: String) -> HerdState {
        HerdState(agents[address]?.state, seen: seen.contains(address))
    }

    func markSeen(_ addresses: Set<String>) {
        let done = addresses.filter { agents[$0]?.state == "done" && !seen.contains($0) }
        if !done.isEmpty { seen.formUnion(done) }
    }

    // the stream only runs while some tab is a herd tab
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            connect()
        } else {
            proc?.terminate()
            detach(except: [])
        }
    }

    // drop attach viewers for panes that went off screen; hc keeps the terminal
    func detach(except keep: Set<String>) {
        for key in PaneHost.shared.terms.keys where key.hasPrefix("herd:") {
            if !keep.contains(String(key.dropFirst(5))) { PaneHost.shared.shutdown(key) }
        }
    }

    private func connect() {
        guard enabled, proc == nil, !connecting else { return }
        connecting = true
        DispatchQueue.global(qos: .utility).async {
            let path = self.hc ?? HerdHost.which("hc")
            let app = self.herdrApp ?? HerdHost.which("herdr-app")
            DispatchQueue.main.async {
                self.connecting = false
                self.herdrApp = app
                guard self.enabled, self.proc == nil else { return }
                guard let path else { self.missing = true; return }
                self.hc = path
                self.missing = false
                self.start(path)
            }
        }
    }

    private func start(_ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["events", "--json"]
        p.environment = cleanEnvironment()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return } // EOF
            DispatchQueue.main.async { self.feed(d) }
        }
        // core restarted or not up yet: retry, the next snapshot resyncs
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                self.proc = nil
                self.online = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.connect() }
            }
        }
        buffer = Data()
        primed = false
        do {
            try p.run()
            proc = p
        } catch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.connect() }
        }
    }

    private func feed(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            apply(line)
        }
    }

    // one JSON line: a snapshot (first line, or `missed`), or an event; the
    // bare params and the full JSON-RPC notification both parse
    private func apply(_ line: Data) {
        guard var obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if let p = obj["params"] as? [String: Any] { obj = p }
        if let ts = obj["terminals"] as? [[String: Any]] {
            records = [:]
            for r in ts where r["state"] as? String == "live" {
                if let a = r["address"] as? String { records[a] = r }
            }
            online = true
            publish()
            // what was already done before Atoll looked counts as seen
            if !primed { seen = Set(agents.values.filter { $0.state == "done" }.map(\.id)) }
            primed = true
            // documents aren't in snapshots; read after (re)subscribing
            fetchSpaces()
            return
        }
        // doc events carry no terminal, only the name and new version
        if obj["type"] as? String == "doc" {
            if (obj["data"] as? [String: Any])?["name"] as? String == "herdr-app" { fetchSpaces() }
            return
        }
        guard let type = obj["type"] as? String, let addr = obj["terminal"] as? String else { return }
        let data = obj["data"] as? [String: Any] ?? [:]
        switch type {
        case "created", "restarted":
            records[addr] = data
            changed[addr] = Date()
        case "finished", "removed": records[addr] = nil
        case "status":
            records[addr]?["status"] = data["status"]
            seen.remove(addr)
            changed[addr] = Date()
        case "title", "labels": records[addr]?[type] = data[type]
        case "foreground": records[addr]?["foreground"] = obj["data"]
        default: return
        }
        publish()
        markSeen(visible)
    }

    private func publish() {
        let new = Dictionary(uniqueKeysWithValues: records.map { ($0.key, HerdAgent($0.value)) })
        if primed {
            for a in new.values where a.state == "blocked" || a.state == "done" {
                guard agents[a.id]?.state != a.state, !visible.contains(a.id) else { continue }
                let s = HerdState(a.state, seen: false)
                if a.state == "blocked" { inboxSelection = a.id }
                onAlert?("\(s.icon) \(a.place) · \(a.label) \(a.state == "blocked" ? "blocked" : "done")")
            }
        }
        agents = new
        if spaces.contains(where: { git[place(of: $0)] == nil && !gitAsked.contains(place(of: $0)) }) { refreshGit() }
    }

    // doc.get has no CLI verb: one JSON-RPC line through `hc connect`
    func fetchSpaces() {
        guard let hc else { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: hc)
            p.arguments = ["connect"]
            p.environment = cleanEnvironment()
            let inp = Pipe(), out = Pipe()
            p.standardInput = inp
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let req = #"{"jsonrpc":"2.0","id":1,"method":"doc.get","params":{"name":"herdr-app"}}"# + "\n"
            inp.fileHandleForWriting.write(req.data(using: .utf8)!)
            var line = Data()
            while true {
                let d = out.fileHandleForReading.availableData
                if d.isEmpty { break }
                line.append(d)
                if line.contains(0x0A) { break }
            }
            p.terminate()
            let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            let value = ((reply?["result"] as? [String: Any])?["value"] as? [String: Any])
            let spaces = (value?["spaces"] as? [[String: Any]] ?? []).map { s in
                HerdSpace(
                    id: s["id"] as? String ?? "",
                    name: s["name"] as? String ?? "",
                    folder: s["folder"] as? String ?? "",
                    tabs: (s["tabs"] as? [[String: Any]] ?? []).map { t in
                        HerdTab(id: t["id"] as? String ?? "",
                                name: t["name"] as? String ?? "",
                                root: HerdNode(t["root"] as? [String: Any] ?? [:]))
                    })
            }
            DispatchQueue.main.async {
                self.spaces = spaces
                self.selectPending()
                self.refreshGit()
            }
        }
    }

    // a space/tab/pane we just asked herdr-app for shows up: go to it
    private func selectPending() {
        switch pending {
        case .space(let before):
            if let s = spaces.first(where: { !before.contains($0.id) }) {
                pending = nil
                select(space: s.id, tab: s.tabs.first?.id, pane: s.tabs.first?.root.shown.first)
                if watchNext, let t = s.tabs.first?.root.shown.first {
                    watchNext = false
                    mode = .focus(t)
                }
            }
        case .tab(let sid, let before):
            if let t = spaces.first(where: { $0.id == sid })?.tabs.first(where: { !before.contains($0.id) }) {
                pending = nil
                select(space: sid, tab: t.id, pane: t.root.shown.first)
                if watchNext, let p = t.root.shown.first {
                    watchNext = false
                    mode = .focus(p)
                }
            }
        case .pane(let sid, let tid, let before):
            let tab = spaces.first { $0.id == sid }?.tabs.first { $0.id == tid }
            if let t = tab?.root.terminals.first(where: { !before.contains($0) }) {
                pending = nil
                select(space: sid, tab: tid, pane: t)
            }
        case nil: break
        }
    }

    // branch + ahead/behind for each space's folder (second sidebar row), and
    // which repo a worktree belongs to (the sidebar nests those)
    func refreshGit() {
        let folders = Set(spaces.map(place(of:)))
        gitAsked.formUnion(folders)
        DispatchQueue.global(qos: .utility).async {
            var out: [String: HerdGit] = [:]
            for f in folders {
                let branch = HerdHost.git(f, ["rev-parse", "--abbrev-ref", "HEAD"])
                guard !branch.isEmpty else { continue }
                var g = HerdGit(branch: branch)
                let counts = HerdHost.git(f, ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"])
                    .split(separator: "\t").compactMap { Int($0) }
                if counts.count == 2 { g.behind = counts[0]; g.ahead = counts[1] }
                let dirs = HerdHost.git(f, ["rev-parse", "--path-format=absolute",
                                            "--show-toplevel", "--git-common-dir", "--git-dir"])
                    .split(separator: "\n").map(String.init)
                if dirs.count == 3 {
                    g.root = dirs[0]
                    g.repo = dirs[1].hasSuffix("/.git") ? String(dirs[1].dropLast(5)) : dirs[1]
                    g.linked = dirs[1] != dirs[2]
                }
                out[f] = g
            }
            var lists: [String: [HerdCheckout]] = [:]
            for repo in Set(out.values.map(\.repo)) where !repo.isEmpty {
                lists[repo] = HerdHost.checkouts(repo)
            }
            DispatchQueue.main.async {
                if out != self.git { self.git = out }
                if lists != self.checkouts { self.checkouts = lists }
            }
        }
    }

    // `git worktree list --porcelain`, main checkout first, prunable ones left out
    static func checkouts(_ repo: String) -> [HerdCheckout] {
        git(repo, ["worktree", "list", "--porcelain"]).components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n").map(String.init)
            guard let path = lines.first(where: { $0.hasPrefix("worktree ") })?.dropFirst(9),
                  !lines.contains(where: { $0 == "bare" || $0.hasPrefix("prunable") }) else { return nil }
            let branch = lines.first { $0.hasPrefix("branch ") }
                .map { String($0.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
            return HerdCheckout(path: String(path), branch: branch)
        }
    }

    static func git(_ dir: String, _ args: [String]) -> String {
        let r = gitRun(dir, args)
        return r.ok ? r.out : ""
    }

    static func gitRun(_ dir: String, _ args: [String]) -> (ok: Bool, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else { return (false, "", "git failed to start") }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let trim = { (d: Data) in String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        return (p.terminationStatus == 0, trim(o), trim(e))
    }

    // MARK: selection

    var space: HerdSpace? { spaces.first { $0.id == selectedSpace } ?? spaces.first }

    func tab(of space: HerdSpace) -> HerdTab? {
        space.tabs.first { $0.id == selectedTab[space.id] } ?? space.tabs.first
    }

    var currentTab: HerdTab? { space.flatMap(tab(of:)) }

    // herdr names a space after its "where" label; the folder otherwise
    func name(of space: HerdSpace) -> String {
        if !space.name.isEmpty { return space.name }
        let fromCore = agents.values.first { $0.spaceID == space.id }?.workspace
        return fromCore ?? (space.folder as NSString).lastPathComponent
    }

    // where a space is: its first terminal's folder right now (what herdr-app
    // names it after and runs git in), else the folder it started in
    func place(of space: HerdSpace) -> String {
        space.tabs.flatMap(\.root.terminals).lazy.compactMap { self.agents[$0]?.cwd }.first ?? space.folder
    }

    // the most urgent pane decides the space's dot
    func state(of space: HerdSpace) -> HerdState {
        space.tabs.flatMap(\.root.terminals).map(state).max() ?? .unknown
    }

    // doc order, except a worktree space sits right under its repo's space
    var spaceRows: [HerdSpaceRow] {
        let parentOf: [String: String] = Dictionary(uniqueKeysWithValues: spaces.compactMap { s in
            guard let g = git[place(of: s)], g.linked,
                  let p = spaces.first(where: { git[place(of: $0)].map { !$0.linked && $0.root == g.repo } ?? false })
            else { return nil }
            return (s.id, p.id)
        })
        var rows: [HerdSpaceRow] = []
        for s in spaces where parentOf[s.id] == nil {
            let kids = spaces.filter { parentOf[$0.id] == s.id }
            rows.append(.init(space: s, child: false, last: false, children: kids.count))
            if foldedRepos.contains(s.id) { continue }
            for (i, k) in kids.enumerated() {
                rows.append(.init(space: k, child: true, last: i == kids.count - 1, children: 0))
            }
        }
        return rows
    }

    func select(space: String, tab: String? = nil, pane: String? = nil) {
        if selectedSpace != space { zoomed = nil }
        selectedSpace = space
        if let tab { selectedTab[space] = tab }
        if let pane { focus(pane) }
    }

    func focus(_ pane: String) {
        focusedPane = pane
        // the pane view may not exist yet when switching tabs
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let v = PaneHost.shared.terms["herd:" + pane] { v.window?.makeFirstResponder(v) }
        }
    }

    // MARK: actions (herdr-app does the work; the doc event brings it back)

    func newSpace() {
        newSpace(space.map { ["folder": place(of: $0)] } ?? [:])
    }

    func newTab(_ s: HerdSpace, _ extra: [String: Any] = [:]) {
        pending = .tab(space: s.id, before: Set(s.tabs.map(\.id)))
        app("tab.new", ["space": s.id, "folder": place(of: s)].merging(extra) { _, b in b })
    }

    func split(_ direction: String) {
        guard let s = space, let t = tab(of: s), let p = focusedPane, let block = t.root.block(of: p) else { return }
        pending = .pane(space: s.id, tab: t.id, before: Set(t.root.terminals))
        app("pane.split", ["direction": direction, "pane": block])
    }

    func closePane() {
        guard let t = currentTab, let p = focusedPane, let block = t.root.block(of: p) else { return }
        app("pane.close", ["pane": block])
    }

    func renameSpace(_ s: HerdSpace) {
        guard let n = HerdHost.ask("Rename space", initial: s.name) else { return }
        app("space.rename", ["id": s.id, "name": n])
    }

    func closeSpace(_ s: HerdSpace) {
        guard HerdHost.confirm("Close space \"\(name(of: s))\"?", "Its terminals end.") else { return }
        app("space.close", ["id": s.id, "confirmed": true])
    }

    func renameTab(_ t: HerdTab) {
        guard let n = HerdHost.ask("Rename tab", initial: t.name) else { return }
        app("tab.rename", ["id": t.id, "name": n])
    }

    func closeTab(_ t: HerdTab) {
        guard HerdHost.confirm("Close this tab?", "Its terminals end.") else { return }
        app("tab.close", ["id": t.id, "confirmed": true])
    }

    // MARK: worktrees (what herdr-app's worktree mod does)

    // checkouts go to ~/.herdr/worktrees/<repo>/<branch, slashes as dashes>
    func newWorktree(_ s: HerdSpace) {
        guard let g = git[place(of: s)], !g.repo.isEmpty else {
            showToast("\(name(of: s)) is not in a git repository")
            return
        }
        guard let branch = HerdHost.ask("New worktree of \((g.repo as NSString).lastPathComponent)", initial: "",
                                        detail: "Branch name: an existing branch, or a new one from HEAD.",
                                        button: "Create")?.trimmingCharacters(in: .whitespaces),
              !branch.isEmpty else { return }
        addWorktree(g, branch: branch) { path in
            // unnamed, so it follows the checkout folder and nests under the repo
            self.newSpace(["folder": path])
        }
    }

    func addWorktree(_ g: HerdGit, branch: String, then: @escaping (String) -> Void) {
        let slug = branch.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let path = NSHomeDirectory() + "/.herdr/worktrees/\((g.repo as NSString).lastPathComponent)/\(slug)"
        DispatchQueue.global(qos: .userInitiated).async {
            let exists = HerdHost.gitRun(g.repo, ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"]).ok
            let add = exists ? ["worktree", "add", path, branch] : ["worktree", "add", "-b", branch, path, "HEAD"]
            let r = HerdHost.gitRun(g.root, add)
            DispatchQueue.main.async {
                guard r.ok else { return self.showToast(r.err.isEmpty ? "git worktree add failed" : r.err) }
                then(path)
            }
        }
    }

    func newSpace(_ args: [String: Any]) {
        pending = .space(before: Set(spaces.map(\.id)))
        app("space.new", args)
    }

    // the space already showing a checkout, or a new one on it
    func openWorktree(_ c: HerdCheckout) {
        let inside = { (p: String) in p == c.path || p.hasPrefix(c.path + "/") }
        if let s = spaces.first(where: { inside(place(of: $0)) }) {
            select(space: s.id)
        } else {
            newSpace(["folder": c.path])
        }
    }

    // terminals first (a shell in the folder keeps it busy), then the checkout
    func removeWorktree(_ s: HerdSpace) {
        guard let g = git[place(of: s)], g.linked else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let status = HerdHost.gitRun(g.root, ["--no-optional-locks", "-c", "core.fsmonitor=false",
                                                  "status", "--porcelain"])
            DispatchQueue.main.async {
                guard status.ok else { return self.showToast(status.err) }
                let dirty = !status.out.isEmpty
                guard HerdHost.confirm(
                    "Remove worktree \(self.name(of: s))?",
                    dirty ? "It has uncommitted changes. They are deleted with the checkout."
                          : "Its terminals end and \(tilde(g.root)) is deleted.",
                    button: "Remove") else { return }
                self.app("space.close", ["id": s.id, "confirmed": true]) {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let r = HerdHost.gitRun(g.repo, ["worktree", "remove"] + (dirty ? ["--force"] : []) + [g.root])
                        DispatchQueue.main.async {
                            if !r.ok { self.showToast(r.err.isEmpty ? "git worktree remove failed" : r.err) }
                            self.refreshGit()
                        }
                    }
                }
            }
        }
    }

    func toggleZoom() {
        zoomed = zoomed == nil ? focusedPane : nil
    }

    func stepTab(_ by: Int) {
        guard let s = space, let t = tab(of: s), let i = s.tabs.firstIndex(where: { $0.id == t.id }) else { return }
        let next = s.tabs[(i + by + s.tabs.count) % s.tabs.count]
        select(space: s.id, tab: next.id)
    }

    func showToast(_ msg: String) {
        toast = msg
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            self?.toast = nil
        }
    }

    func app(_ action: String, _ args: [String: Any], then: (() -> Void)? = nil) {
        guard let herdrApp else {
            pending = nil
            showToast("herdr-app not on PATH: needed to change spaces, tabs and panes")
            return
        }
        let json = String(data: (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8),
                          encoding: .utf8) ?? "{}"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: herdrApp)
            p.arguments = ["do", action, json]
            p.environment = cleanEnvironment()
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            guard (try? p.run()) != nil else { return }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            guard p.terminationStatus != 0 else {
                if let then { DispatchQueue.main.async(execute: then) }
                return
            }
            // failures come back as {"error": "..."}
            let err = (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])?["error"] as? String
            DispatchQueue.main.async {
                self.pending = nil
                self.showToast("\(action): \(err ?? out.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    // a modal over the island; nil when cancelled
    static func ask(_ title: String, initial: String,
                    detail: String = "Leave empty to go back to the default name.",
                    button: String = "Rename") -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        a.accessoryView = field
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func confirm(_ title: String, _ detail: String, button: String = "Close") -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: keys (herdr's prefix mode)

    private func handleKey(_ e: NSEvent) -> Bool {
        guard keysActive, e.window is IslandPanel else { return false }
        // text fields (renames, the + card) keep their keys
        if e.window?.firstResponder is NSTextView { return mode == .compose && composeKey(e) }
        if mode != .full { return inboxKey(e) }
        let chars = e.charactersIgnoringModifiers ?? ""
        let ctrlB = e.modifierFlags.contains(.control) && chars.lowercased() == "b"
        if e.modifierFlags.contains(.command) && chars == "i" {
            mode = .inbox
            return true
        }
        if help {
            help = false
            return true
        }
        if !prefix {
            guard ctrlB else { return false }
            prefix = true
            return true
        }
        prefix = false
        if ctrlB { return false } // ctrl+b twice: the program gets one
        let shift = e.modifierFlags.contains(.shift)
        switch (e.keyCode, chars) {
        case (53, _): break // esc
        case (48, _): cyclePane(shift ? -1 : 1) // tab
        case (_, "c"): if let s = space { newTab(s) }
        case (_, "n"): stepTab(1)
        case (_, "p"): stepTab(-1)
        case (_, "X"): if let t = currentTab { closeTab(t) }
        case (_, "T"): if let t = currentTab { renameTab(t) }
        case (_, "N"): newSpace()
        case (_, "W"): if let s = space { renameSpace(s) }
        case (_, "D"): if let s = space { closeSpace(s) }
        case (_, "G"): if let s = space { newWorktree(s) }
        case (_, "v"): split("right")
        case (_, "-"): split("down")
        case (_, "x"): closePane()
        case (_, "z"): toggleZoom()
        case (_, "h"): focusNeighbor(dx: -1, dy: 0)
        case (_, "l"): focusNeighbor(dx: 1, dy: 0)
        case (_, "j"): focusNeighbor(dx: 0, dy: 1)
        case (_, "k"): focusNeighbor(dx: 0, dy: -1)
        case (_, "b"): sidebarCollapsed.toggle()
        case (_, "?"): help = true
        case (_, let d) where d.count == 1 && ("1"..."9").contains(d):
            if let s = space, let i = Int(d), i <= s.tabs.count { select(space: s.id, tab: s.tabs[i - 1].id) }
        default: break
        }
        return true
    }

    private func paneFrames() -> [(String, NSRect)] {
        visible.compactMap { a in
            guard let v = PaneHost.shared.terms["herd:" + a], v.window != nil else { return nil }
            return (a, v.convert(v.bounds, to: nil))
        }
    }

    // nearest pane whose centre lies that way (window coords: y grows upward)
    private func focusNeighbor(dx: CGFloat, dy: CGFloat) {
        let frames = paneFrames()
        guard let cur = frames.first(where: { $0.0 == focusedPane })?.1 else { return }
        let best = frames.filter { $0.0 != focusedPane }.compactMap { a, r -> (String, CGFloat)? in
            let vx = r.midX - cur.midX, vy = cur.midY - r.midY // flip so +dy is down
            let along = vx * dx + vy * dy
            guard along > 0 else { return nil }
            return (a, along + abs(vx * dy) + abs(vy * dx))
        }.min { $0.1 < $1.1 }
        if let best { focus(best.0) }
    }

    private func cyclePane(_ by: Int) {
        guard let order = currentTab?.root.shown, !order.isEmpty else { return }
        let i = order.firstIndex { $0 == focusedPane } ?? 0
        focus(order[(i + by + order.count) % order.count])
    }

    // MARK: attach

    // stderr goes to a file so a dead attach can say why
    static func errFile(_ address: String) -> String {
        NSTemporaryDirectory() + "atoll-herd-" + address.replacingOccurrences(of: "/", with: "_") + ".err"
    }

    func attachSpec(_ address: String) -> TabSpec {
        .init(name: "herd:" + address,
              command: "\(HerdHost.quote(hc ?? "hc")) attach --history 2000 \(HerdHost.quote(address))"
                  + " 2>\(HerdHost.quote(HerdHost.errFile(address)))")
    }

    static func which(_ tool: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(tool)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.hasPrefix("/") ? s : nil
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Cell grid
//
// herdr draws in terminal cells; the sidebar and tab bar use the panes' own
// font so their columns line up with the terminals next to them

struct HerdCell {
    let font: NSFont
    let bold: NSFont
    let w: CGFloat
    let h: CGFloat

    static func current() -> HerdCell {
        let f = PaneHost.shared.paneFont(PaneHost.shared.fontSize)
        let b = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
        let w = ("W" as NSString).size(withAttributes: [.font: f]).width
        return .init(font: f, bold: b, w: w, h: ceil(f.ascender - f.descender + f.leading))
    }
}

struct HerdSpan {
    var text: String
    var fg: SwiftUI.Color = .clear
    var bold = false
}

// one row of cells: spans clipped to `clip` columns (with …), padded to `cols`
struct HerdLine: View {
    let spans: [HerdSpan]
    var right: [HerdSpan] = []
    let cols: Int
    var clip: Int? = nil
    var bg: SwiftUI.Color = .clear
    let cell: HerdCell

    var body: some View {
        let limit = clip ?? cols
        let rightLen = right.reduce(0) { $0 + $1.text.count }
        var left: [HerdSpan] = []
        var used = 0
        for s in spans {
            let room = limit - used
            if room <= 0 { break }
            if s.text.count > room {
                left.append(.init(text: String(s.text.prefix(max(room - 1, 0))) + "…", fg: s.fg, bold: s.bold))
                used = limit
                break
            }
            left.append(s)
            used += s.text.count
        }
        let gap = max(cols - used - rightLen, 0)
        let all = left + [HerdSpan(text: String(repeating: " ", count: gap))] + right
        return all.reduce(Text("")) { acc, s in
            acc + Text(s.text).font(Font(s.bold ? cell.bold : cell.font)).foregroundColor(s.fg)
        }
        .lineLimit(1)
        .frame(width: CGFloat(cols) * cell.w, height: cell.h, alignment: .leading)
        .background(bg)
    }
}

// MARK: - Herd pane

struct HerdPane: View {
    @ObservedObject var store: Store
    @ObservedObject var host: HerdHost

    var body: some View {
        let cell = HerdCell.current()
        GeometryReader { g in
            let rows = max(Int(g.size.height / cell.h), 6)
            if host.missing {
                message("hc not on PATH · install herdr-core:\ncurl -fsSL https://releases.herdr.dev/core/install.sh | sh")
            } else if host.spaces.isEmpty {
                message(host.online ? "no herdr spaces in herdr-core" : "connecting to herdr-core…")
            } else if host.mode != .full {
                HerdInbox(store: store, host: host, cell: cell)
            } else {
                HStack(spacing: 0) {
                    if host.sidebarCollapsed {
                        compactSidebar(rows: rows, cell: cell)
                    } else {
                        sidebar(rows: rows, cell: cell)
                    }
                    main(cell: cell)
                }
            }
        }
        .background(Color(nsColor: store.theme.ink))
        .onAppear { host.keysActive = true }
        .onDisappear {
            host.keysActive = false
            host.prefix = false
            host.help = false
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in host.refreshGit() }
    }

    func message(_ s: String) -> some View {
        Text(s)
            .font(mono(10))
            .foregroundStyle(Mocha.overlay0)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: sidebar (26 columns: 25 of content and a │)

    static let sidebarCols = 26

    func sidebar(rows: Int, cell: HerdCell) -> some View {
        let w = Self.sidebarCols - 1
        let top = min(max(Int((Double(rows) * 0.5).rounded()), 3), rows - 3)
        let current = host.space
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                // spaces
                HerdLine(spans: [.init(text: " spaces", fg: Mocha.overlay0, bold: true)], cols: w, cell: cell)
                HerdLine(spans: [], cols: w, cell: cell)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(host.spaceRows) { r in spaceRows(r, focused: r.id == current?.id, w: w, cell: cell) }
                    }
                }
                .frame(height: CGFloat(max(top - 3, 0)) * cell.h)
                HStack(spacing: 0) {
                    Button { host.newSpace() } label: {
                        HerdLine(spans: [.init(text: " new", fg: Mocha.overlay0)], cols: 4, cell: cell)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    menu(cell: cell)
                }
                .frame(width: CGFloat(w) * cell.w, height: cell.h)
                // agents
                HerdLine(spans: [.init(text: String(repeating: "─", count: w), fg: Mocha.surfaceDim)],
                         cols: w, cell: cell)
                HerdLine(spans: [.init(text: " agents", fg: Mocha.overlay0, bold: true)],
                         right: [.init(text: "grouped", fg: Mocha.overlay0, bold: true)], cols: w, cell: cell)
                HerdLine(spans: [], cols: w, cell: cell)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(agentEntries, id: \.address) { e in agentRows(e, w: w, cell: cell) }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: CGFloat(w) * cell.w)
            .overlay(alignment: .bottomTrailing) {
                Button { host.sidebarCollapsed = true } label: {
                    HerdLine(spans: [.init(text: "«", fg: Mocha.overlay0)], cols: 1, cell: cell)
                }
                .buttonStyle(.plain)
                .padding(.trailing, cell.w)
            }
            rule(cell)
        }
    }

    // herdr's global menu: the same actions as the prefix keys
    func menu(cell: HerdCell) -> some View {
        Menu {
            Button("New Space") { host.newSpace() }
            if let s = host.space {
                Button("New Tab") { host.newTab(s) }
                worktreeItems(s)
                Divider()
                Button("Rename Space…") { host.renameSpace(s) }
                if let t = host.tab(of: s) { Button("Rename Tab…") { host.renameTab(t) } }
                Divider()
                Button("Split Right") { host.split("right") }
                Button("Split Down") { host.split("down") }
                Button(host.zoomed == nil ? "Zoom Pane" : "Unzoom Pane") { host.toggleZoom() }
                Button("Close Pane") { host.closePane() }
                Divider()
                if let t = host.tab(of: s) { Button("Close Tab…") { host.closeTab(t) } }
                Button("Close Space…") { host.closeSpace(s) }
            }
            Divider()
            Button("Keys…") { host.help = true }
        } label: {
            Text("menu").font(Font(cell.font)).foregroundColor(Mocha.overlay0)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // new / open / remove worktree for a space in a git repo
    @ViewBuilder func worktreeItems(_ s: HerdSpace) -> some View {
        if let g = host.git[host.place(of: s)], !g.repo.isEmpty {
            Button("New Worktree…") { host.newWorktree(s) }
            let others = (host.checkouts[g.repo] ?? []).filter { $0.path != g.root }
            if !others.isEmpty {
                Menu("Open Worktree") {
                    ForEach(others, id: \.self) { c in
                        Button((c.branch ?? (c.path as NSString).lastPathComponent)
                               + "  " + tilde(c.path)) { host.openWorktree(c) }
                    }
                }
            }
            if g.linked { Button("Remove Worktree…") { host.removeWorktree(s) } }
        }
    }

    func rule(_ cell: HerdCell) -> some View {
        Rectangle().fill(Mocha.surfaceDim).frame(width: 1).frame(width: cell.w)
    }

    func spaceRows(_ r: HerdSpaceRow, focused: Bool, w: Int, cell: HerdCell) -> some View {
        let s = r.space
        let st = host.state(of: s)
        let git = host.git[host.place(of: s)]
        let bg = focused ? Mocha.activeRow : .clear
        // worktree children: tree prefixes instead of the plain indent
        let lead = r.child ? (r.last ? "   └─ " : "   ├─ ") : " "
        let cont = r.child ? (r.last ? "        " : "   │    ") : "   "
        let fold: [HerdSpan] = r.children > 0
            ? [.init(text: host.foldedRepos.contains(s.id) ? "▸" : "▾", fg: Mocha.accent)] : []
        return VStack(spacing: 0) {
            HerdLine(spans: [
                .init(text: lead, fg: Mocha.overlay0),
                .init(text: st.icon, fg: st.color),
                .init(text: " "),
                .init(text: host.name(of: s), fg: focused ? Mocha.text : Mocha.subtext0, bold: focused),
            ], right: fold, cols: w, clip: w - 2, bg: bg, cell: cell)
            if let git {
                HerdLine(spans: [.init(text: cont, fg: Mocha.overlay0),
                                 .init(text: git.branch, fg: focused ? Mocha.mauve : Mocha.overlay0)]
                    + gitCounts(git), cols: w, clip: w - 2, bg: bg, cell: cell)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { location in
            // the ▾/▸ column folds the repo's worktrees
            if r.children > 0 && location.x >= CGFloat(w - 1) * cell.w {
                if host.foldedRepos.contains(s.id) { host.foldedRepos.remove(s.id) } else { host.foldedRepos.insert(s.id) }
            } else {
                host.select(space: s.id)
            }
        }
        .contextMenu {
            Button("New Tab") { host.newTab(s) }
            Divider()
            worktreeItems(s)
            Divider()
            Button("Rename Space…") { host.renameSpace(s) }
            Button("Close Space…") { host.closeSpace(s) }
        }
    }

    func gitCounts(_ g: HerdGit) -> [HerdSpan] {
        var out: [HerdSpan] = []
        if g.ahead > 0 || g.behind > 0 { out.append(.init(text: " ")) }
        if g.ahead > 0 { out.append(.init(text: "↑\(g.ahead)", fg: Mocha.green)) }
        if g.ahead > 0 && g.behind > 0 { out.append(.init(text: " ")) }
        if g.behind > 0 { out.append(.init(text: "↓\(g.behind)", fg: Mocha.red)) }
        return out
    }

    struct AgentEntry {
        var address: String
        var space: HerdSpace
        var tab: HerdTab
        var tabLabel: String?
    }

    // panes with a reporting agent, grouped by space then tab; shells are left out
    var agentEntries: [AgentEntry] {
        host.spaceRows.map(\.space).flatMap { s in
            s.tabs.enumerated().flatMap { i, t in
                let label: String? = !t.name.isEmpty ? t.name : s.tabs.count > 1 ? "\(i + 1)" : nil
                return t.root.terminals
                    .filter { host.agents[$0]?.state != nil }
                    .map { AgentEntry(address: $0, space: s, tab: t, tabLabel: label) }
            }
        }
    }

    func agentRows(_ e: AgentEntry, w: Int, cell: HerdCell) -> some View {
        let st = host.state(e.address)
        let focused = host.focusedPane == e.address && host.space?.id == e.space.id
        let bg = focused ? Mocha.activeRow : .clear
        var row0: [HerdSpan] = [
            .init(text: " " + st.icon, fg: st.color),
            .init(text: " "),
            .init(text: host.name(of: e.space), fg: focused ? Mocha.text : Mocha.subtext0, bold: true),
        ]
        if let t = e.tabLabel {
            row0 += [.init(text: " · ", fg: Mocha.overlay0), .init(text: t, fg: Mocha.overlay0)]
        }
        return VStack(spacing: 0) {
            HerdLine(spans: row0, cols: w, clip: w - 2, bg: bg, cell: cell)
            HerdLine(spans: [.init(text: "   " + (host.agents[e.address]?.label ?? "?"), fg: Mocha.overlay0)],
                     cols: w, clip: w - 2, bg: bg, cell: cell)
        }
        .contentShape(Rectangle())
        .onTapGesture { host.select(space: e.space.id, tab: e.tab.id, pane: e.address) }
    }

    // collapsed: 3 columns of number + dot, then the │
    func compactSidebar(rows: Int, cell: HerdCell) -> some View {
        let current = host.space
        let entries = agentEntries
        let spaces = host.spaceRows.map(\.space)
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(spaces.enumerated()), id: \.element.id) { i, s in
                    let st = host.state(of: s)
                    let focused = s.id == current?.id
                    HerdLine(spans: [
                        .init(text: String("\(i + 1)  ".prefix(2)), fg: focused ? Mocha.text : Mocha.overlay0),
                        .init(text: st.icon, fg: st.color),
                    ], cols: 3, bg: focused ? Mocha.activeRow : .clear, cell: cell)
                    .contentShape(Rectangle())
                    .onTapGesture { host.select(space: s.id) }
                }
                Spacer(minLength: 0)
                    .frame(maxHeight: CGFloat(max((rows + 1) / 2 - spaces.count, 0)) * cell.h)
                HerdLine(spans: [.init(text: "───", fg: Mocha.surfaceDim)], cols: 3, cell: cell)
                ForEach(Array(entries.enumerated()), id: \.element.address) { i, e in
                    let st = host.state(e.address)
                    HerdLine(spans: [
                        .init(text: String("\(i + 1)  ".prefix(2)), fg: Mocha.overlay0),
                        .init(text: st.icon, fg: st.color),
                    ], cols: 3, cell: cell)
                    .contentShape(Rectangle())
                    .onTapGesture { host.select(space: e.space.id, tab: e.tab.id, pane: e.address) }
                }
                Spacer(minLength: 0)
                Button { host.sidebarCollapsed = false } label: {
                    HerdLine(spans: [.init(text: " »", fg: Mocha.overlay0)], cols: 3, cell: cell)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 3 * cell.w)
            rule(cell)
        }
    }

    // MARK: tab bar + panes

    @ViewBuilder func main(cell: HerdCell) -> some View {
        if let s = host.space {
            let tab = host.tab(of: s)
            VStack(spacing: 0) {
                tabBar(s, active: tab?.id, cell: cell)
                if let tab {
                    let zoom = host.zoomed.flatMap { tab.root.shown.contains($0) ? $0 : nil }
                    let panes = zoom.map { [$0] } ?? tab.root.shown
                    Group {
                        if let zoom {
                            HerdPaneView(address: zoom, borders: false, store: store, host: host, cell: cell)
                        } else {
                            HerdLayout(node: tab.root, borders: panes.count > 1, store: store, host: host, cell: cell)
                        }
                    }
                    .overlay { if host.help { helpOverlay(cell) } }
                    .overlay(alignment: .bottom) { modeBar(cell) }
                    .onAppear { show(panes) }
                    .onChange(of: panes) { _, new in show(new) }
                } else {
                    Spacer()
                }
            }
        }
    }

    func show(_ panes: [String]) {
        host.visible = Set(panes)
        host.detach(except: Set(panes))
        if host.focusedPane.map({ !panes.contains($0) }) ?? true { host.focusedPane = panes.first }
    }

    // herdr's mode bar: only while a prefix is pending, or to report a failed action
    @ViewBuilder func modeBar(_ cell: HerdCell) -> some View {
        if host.prefix || host.toast != nil {
            HStack(spacing: 0) {
                if host.prefix {
                    HerdLine(spans: [.init(text: " PREFIX ", fg: Mocha.panelBG, bold: true)],
                             cols: 8, bg: Mocha.accent, cell: cell)
                    HerdLine(spans: [.init(text: " "),
                                     .init(text: "c", fg: Mocha.accent, bold: true), .init(text: " tab  ", fg: Mocha.overlay0),
                                     .init(text: "v", fg: Mocha.accent, bold: true), .init(text: " split  ", fg: Mocha.overlay0),
                                     .init(text: "x", fg: Mocha.accent, bold: true), .init(text: " close  ", fg: Mocha.overlay0),
                                     .init(text: "z", fg: Mocha.accent, bold: true), .init(text: " zoom  ", fg: Mocha.overlay0),
                                     .init(text: "?", fg: Mocha.accent, bold: true), .init(text: " help", fg: Mocha.overlay0)],
                             cols: 60, cell: cell)
                } else if let t = host.toast {
                    HerdLine(spans: [.init(text: " " + t, fg: Mocha.red)], cols: 120, cell: cell)
                }
                Spacer(minLength: 0)
            }
            .frame(height: cell.h)
            .background(Mocha.panelBG)
        }
    }

    func helpOverlay(_ cell: HerdCell) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HerdLine(spans: [.init(text: " keys · ctrl+b, then", fg: Mocha.text, bold: true)], cols: 36, cell: cell)
            HerdLine(spans: [], cols: 36, cell: cell)
            ForEach(herdKeyHelp, id: \.0) { k, what in
                HerdLine(spans: [.init(text: " " + k.padding(toLength: 10, withPad: " ", startingAt: 0),
                                       fg: Mocha.accent, bold: true),
                                 .init(text: what, fg: Mocha.subtext0)], cols: 36, cell: cell)
            }
            HerdLine(spans: [], cols: 36, cell: cell)
            HerdLine(spans: [.init(text: " any key closes", fg: Mocha.overlay0)], cols: 36, cell: cell)
        }
        .padding(.vertical, cell.h / 2)
        .background(Mocha.panelBG)
        .overlay(Rectangle().strokeBorder(Mocha.accent, lineWidth: 1))
        .onTapGesture { host.help = false }
    }

    func tabBar(_ s: HerdSpace, active: String?, cell: HerdCell) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(s.tabs.enumerated()), id: \.element.id) { i, t in
                let on = t.id == active
                let custom = !t.name.isEmpty
                let label = (custom ? t.name : "\(i + 1)") + (on && host.zoomed != nil ? " Z" : "")
                let width = max(label.count + 4, 8)
                let pad = (width - label.count) / 2
                let text = String(repeating: " ", count: pad) + label
                    + String(repeating: " ", count: width - pad - label.count)
                HerdLine(spans: [.init(text: text,
                                       fg: on ? Mocha.panelBG : custom ? Mocha.overlay1 : Mocha.overlay0,
                                       bold: on && custom)],
                         cols: width, bg: on ? Mocha.accent : Mocha.surface0, cell: cell)
                    .contentShape(Rectangle())
                    .onTapGesture { host.select(space: s.id, tab: t.id) }
                    .contextMenu {
                        Button("Rename Tab…") { host.renameTab(t) }
                        Button("Close Tab…") { host.closeTab(t) }
                    }
                HerdLine(spans: [], cols: 1, cell: cell)
            }
            Button { host.newTab(s) } label: {
                HerdLine(spans: [.init(text: " + ", fg: Mocha.overlay1)], cols: 3, cell: cell)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button { host.mode = .inbox } label: {
                HerdLine(spans: [.init(text: "⌘I", fg: Mocha.accent, bold: true),
                                 .init(text: " inbox ", fg: Mocha.overlay0)], cols: 9, cell: cell)
            }
            .buttonStyle(.plain)
        }
        .frame(height: cell.h)
        .background(Mocha.panelBG)
    }
}

// herdr's split tree: weights share what fixed px sizes leave over
struct HerdLayout: View {
    let node: HerdNode
    let borders: Bool
    @ObservedObject var store: Store
    @ObservedObject var host: HerdHost
    let cell: HerdCell

    var body: some View {
        if let t = node.terminal {
            HerdPaneView(address: t, borders: borders, store: store, host: host, cell: cell)
        } else if node.kind == "stack" {
            if let child = node.visible.first(where: { $0.id == node.active }) ?? node.visible.first {
                AnyView(HerdLayout(node: child, borders: borders, store: store, host: host, cell: cell))
            }
        } else {
            let kids = node.visible
            let row = node.kind == "row"
            GeometryReader { g in
                let total = row ? g.size.width : g.size.height
                let fixed = kids.compactMap(\.px).reduce(0, +)
                let weights = kids.filter { $0.px == nil }.map { $0.weight ?? 1 }.reduce(0, +)
                let sizes = kids.map { k in
                    k.px.map { CGFloat($0) } ?? max(total - fixed, 0) * (k.weight ?? 1) / max(weights, 0.0001)
                }
                let layout = row ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    ForEach(Array(kids.enumerated()), id: \.element.id) { i, k in
                        AnyView(HerdLayout(node: k, borders: borders, store: store, host: host, cell: cell))
                            .frame(width: row ? sizes[i] : nil, height: row ? nil : sizes[i])
                    }
                }
            }
        }
    }
}

// one pane: a live `hc attach` with herdr's scrollbar gutter; boxed in
// accent/overlay0 when the tab is split
struct HerdPaneView: View {
    let address: String
    let borders: Bool
    @ObservedObject var store: Store
    @ObservedObject var host: HerdHost
    let cell: HerdCell
    @State private var detached: String?
    @State private var generation = 0
    @State private var scroll: (pos: Double, thumb: CGFloat)?

    var body: some View {
        let focused = host.focusedPane == address
        Group {
            if host.agents[address] == nil {
                Text("· \(address) is gone")
                    .font(Font(cell.font))
                    .foregroundStyle(Mocha.overlay0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let reason = detached {
                Button {
                    detached = nil
                    generation += 1
                } label: {
                    Text(reason.isEmpty ? "detached · click to reattach" : "\(reason)\n\nclick to reattach")
                        .font(Font(cell.font))
                        .foregroundStyle(Mocha.overlay0)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 0) {
                    HerdAttachView(tab: host.attachSpec(address), focus: focused)
                        .id("\(address)#\(generation)")
                    scrollbar(focused)
                }
            }
        }
        .padding(borders ? EdgeInsets(top: cell.h, leading: cell.w, bottom: cell.h, trailing: cell.w)
                 : EdgeInsets())
        .overlay {
            if borders {
                Rectangle()
                    .strokeBorder(focused ? Mocha.accent : Mocha.overlay0, lineWidth: 1)
                    .padding(EdgeInsets(top: cell.h / 2, leading: cell.w / 2,
                                        bottom: cell.h / 2, trailing: cell.w / 2))
                    .allowsHitTesting(false)
            }
        }
        // ctrl+\ or a lost stream ends `hc attach`; say why and offer it back
        .onChange(of: store.livePanes) { old, new in
            let key = "herd:" + address
            guard old.contains(key) && !new.contains(key) && host.visible.contains(address) else { return }
            let err = (try? String(contentsOfFile: HerdHost.errFile(address), encoding: .utf8)) ?? ""
            detached = err.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.first ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .atollPaneScrolled)) { n in
            if (n.object as AnyObject?) === PaneHost.shared.terms["herd:" + address] { readScroll() }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { readScroll() } }
    }

    func readScroll() {
        guard let v = PaneHost.shared.terms["herd:" + address] else { return }
        scroll = v.canScroll ? (v.scrollPosition, v.scrollThumbsize) : nil
    }

    // herdr: ▕ track, ▐ thumb when focused (▕ otherwise); empty without scrollback
    func scrollbar(_ focused: Bool) -> some View {
        GeometryReader { g in
            if let s = scroll {
                let h = g.size.height
                let thumb = max(h * s.thumb, cell.h)
                let thumbW = focused ? cell.w / 2 : cell.w / 8
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                        .fill(focused ? Mocha.overlay0 : Mocha.surfaceDim)
                        .frame(width: cell.w / 8, height: h)
                    Rectangle()
                        .fill(focused ? Mocha.overlay1 : Mocha.overlay0)
                        .frame(width: thumbW, height: thumb)
                        .offset(y: (h - thumb) * CGFloat(s.pos))
                }
                .frame(width: g.size.width, height: h, alignment: .topTrailing)
            }
        }
        .frame(width: cell.w)
        .allowsHitTesting(false)
    }
}

extension Notification.Name {
    static let atollPaneScrolled = Notification.Name("atollPaneScrolled")
}

// `hc attach` in a regular pane, keyed "herd:<address>" so it never collides
// with a tab
struct HerdAttachView: NSViewRepresentable {
    let tab: TabSpec
    let focus: Bool
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let v = PaneHost.shared.terminal(for: tab)
        if focus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                v.window?.makeKey()
                v.window?.makeFirstResponder(v)
            }
        }
        return v
    }
    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
}

// collapsed pill: herdr's dot per reporting agent; blocked ones pulse
struct HerdDots: View {
    @ObservedObject var host: HerdHost

    var body: some View {
        let states = host.spaces.flatMap { $0.tabs.flatMap(\.root.terminals) }
            .filter { host.agents[$0]?.state != nil }
            .map(host.state)
            .prefix(8)
        // the pill idles cheaply: only tick while something needs pulsing
        if states.contains(.blocked) {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                dots(Array(states), pulse: Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0)
            }
        } else if !states.isEmpty {
            dots(Array(states), pulse: true)
        }
    }

    func dots(_ states: [HerdState], pulse: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, s in
                Circle()
                    .fill(s == .idle ? .clear : s.color)
                    .overlay(Circle().strokeBorder(s.color, lineWidth: 1))
                    .frame(width: 6, height: 6)
                    .opacity(s == .blocked && !pulse ? 0.25 : 1)
            }
        }
    }
}
