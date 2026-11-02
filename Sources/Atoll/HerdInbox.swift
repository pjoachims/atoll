import AppKit
import SwiftUI

// MARK: - Herd inbox: the notch's view of herdr
//
// The notch is for seconds: see what needs you, answer it, fire off a new
// task. herdr's whole screen (Herd.swift) stays one key away for longer work.

enum HerdMode: Equatable {
    case inbox
    case focus(String) // one agent's pane, big
    case compose
    case full          // herdr's own screen
}

enum HerdBucket: Int, CaseIterable {
    case needsYou, running, idle

    init(_ s: HerdState) {
        switch s {
        case .blocked, .done: self = .needsYou
        case .working: self = .running
        case .idle, .unknown: self = .idle
        }
    }

    var title: String {
        switch self {
        case .needsYou: "NEEDS YOU"
        case .running: "RUNNING"
        case .idle: "IDLE"
        }
    }
}

struct HerdInboxRow: Identifiable {
    let address: String
    let space: HerdSpace
    let tab: HerdTab
    let state: HerdState
    var id: String { address }
}

let herdAgentApps = ["claude", "codex", "opencode", "pi"]

extension HerdHost {
    // every terminal in a space, bucketed; blocked before done, newest first
    var inbox: [(bucket: HerdBucket, rows: [HerdInboxRow])] {
        let rows = spaceRows.map(\.space).flatMap { s in
            s.tabs.flatMap { t in
                // agents only: whatever reports a status, or a known agent that hasn't yet
                t.root.terminals.filter { a in
                    agents[a].map { $0.state != nil || herdAgentApps.contains($0.label) } ?? false
                }
                    .map { HerdInboxRow(address: $0, space: s, tab: t, state: state($0)) }
            }
        }
        return HerdBucket.allCases.compactMap { b in
            var mine = rows.filter { HerdBucket($0.state) == b }
            if b == .needsYou {
                mine.sort {
                    $0.state != $1.state ? $0.state > $1.state
                        : (changed[$0.address] ?? .distantPast) > (changed[$1.address] ?? .distantPast)
                }
            }
            return mine.isEmpty ? nil : (b, mine)
        }
    }

    var inboxOrder: [String] { inbox.flatMap { $0.rows.map(\.address) } }

    func open(_ address: String) {
        guard let r = inbox.flatMap(\.rows).first(where: { $0.address == address }) else { return }
        inboxSelection = address
        select(space: r.space.id, tab: r.tab.id, pane: address)
        mode = .focus(address)
    }

    // the next (or previous) agent that needs you, after the one on screen
    func stepNeedy(_ by: Int) {
        let needy = inbox.first { $0.bucket == .needsYou }?.rows.map(\.address) ?? []
        guard !needy.isEmpty else { return showToast("nothing else needs you") }
        let cur: String? = if case .focus(let a) = mode { a } else { nil }
        let i = cur.flatMap { needy.firstIndex(of: $0) }
        let next = i.map { needy[($0 + by + needy.count) % needy.count] } ?? needy[0]
        open(next)
    }

    // y: Enter takes a dialog's default (yes); n: Esc declines
    func answer(_ address: String, yes: Bool) {
        guard state(address) == .blocked else { return }
        hcDo(["keys", address, yes ? "enter" : "esc"])
    }

    func openInApp(_ address: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Herdr"]
        try? p.run()
        // the window has to be up before it can show the agent
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.app("agent.focus", ["terminal": address]) }
        onCollapse?()
    }

    // a space running the agent with the task as its first message; with a
    // branch, in a new worktree of that folder's repo
    // herdr's way: a task is a tab named after it, in the space for its folder
    func send(_ task: String, folder: String, agent: String, branch: String?, watch: Bool) {
        let words = task.split(whereSeparator: \.isWhitespace).prefix(5).joined(separator: " ")
        let name = words.count > 32 ? String(words.prefix(31)) + "…" : words
        let args: [String: Any] = ["argv": [agent], "task": task]
        watchNext = watch
        if let branch, let g = git[folder], !g.repo.isEmpty {
            addWorktree(g, branch: branch) { path in
                self.newSpace(args.merging(["folder": path, "tab": name]) { a, _ in a })
            }
        } else if let s = spaces.first(where: { place(of: $0) == folder }) {
            newTab(s, args.merging(["folder": folder, "name": name]) { a, _ in a })
        } else {
            newSpace(args.merging(["folder": folder, "tab": name]) { a, _ in a })
        }
        mode = .inbox
        if !watch { onCollapse?() }
    }

    // folders to start in: where each space is now, in sidebar order
    var places: [String] {
        var seen = Set<String>()
        return spaceRows.map { place(of: $0.space) }.filter { seen.insert($0).inserted }
    }

    func hcDo(_ args: [String]) {
        guard let hc else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: hc)
            p.arguments = args + ["--json"]
            p.environment = cleanEnvironment()
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            guard (try? p.run()) != nil else { return }
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus != 0 else { return }
            let err = ((try? JSONSerialization.jsonObject(with: out)) as? [String: Any])?["error"] as? [String: Any]
            let msg = err?["message"] as? String ?? String(data: out, encoding: .utf8) ?? ""
            DispatchQueue.main.async { self.showToast("hc \(args[0]): \(msg)") }
        }
    }

    // MARK: keys

    func inboxKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let chars = e.charactersIgnoringModifiers ?? ""
        if cmd {
            switch (e.keyCode, chars) {
            // letters, not [ or \\: those need ⌥ on a German layout
            case (_, "f"): mode = .full
            case (_, "n"): mode = .compose
            case (_, "i"), (123, _): mode = .inbox // ⌘← too: plain ← belongs to the pane
            case (126, _): stepNeedy(-1)
            case (125, _): stepNeedy(1)
            case (_, "o"):
                if case .focus(let a) = mode { openInApp(a) } else if let a = inboxSelection { openInApp(a) }
            default: return false
            }
            return true
        }
        // a pane on screen gets every other key
        guard mode == .inbox else { return false }
        let order = inboxOrder
        let i = inboxSelection.flatMap { order.firstIndex(of: $0) }
        switch (e.keyCode, chars) {
        case (126, _), (_, "k"):
            if !order.isEmpty { inboxSelection = order[max((i ?? 0) - 1, 0)] }
        case (125, _), (_, "j"):
            if !order.isEmpty { inboxSelection = order[min((i ?? -1) + 1, order.count - 1)] }
        case (36, _), (76, _): if let a = inboxSelection ?? order.first { open(a) }
        case (_, "y"): if let a = inboxSelection { answer(a, yes: true) }
        case (_, "n"): if let a = inboxSelection { answer(a, yes: false) }
        default: return false
        }
        return true
    }

    // the composer's text field has the keyboard; only these are ours
    func composeKey(_ e: NSEvent) -> Bool {
        if e.keyCode == 53 {
            mode = .inbox
            return true
        }
        if e.keyCode == 36 && e.modifierFlags.contains(.command) {
            NotificationCenter.default.post(name: .herdSendAndWatch, object: nil)
            return true
        }
        return false
    }
}

// MARK: views

struct HerdInbox: View {
    @ObservedObject var store: Store
    @ObservedObject var host: HerdHost
    let cell: HerdCell
    var accent: SwiftUI.Color { store.theme.herdAccent }
    var raised: SwiftUI.Color { store.theme.herdRaised }

    var body: some View {
        GeometryReader { g in
            let cols = max(Int(g.size.width / cell.w), 40)
            VStack(spacing: 0) {
                switch host.mode {
                case .focus(let a): focus(a, cols: cols)
                case .compose: HerdComposer(host: host, theme: store.theme, cell: cell, cols: cols)
                default: list(cols: cols)
                }
                if let t = host.toast {
                    HerdLine(spans: [.init(text: " " + t, fg: Mocha.red)], cols: cols, bg: raised, cell: cell)
                }
            }
        }
        .onAppear { show(host.mode) }
        .onChange(of: host.mode) { _, m in show(m) }
    }

    func show(_ m: HerdMode) {
        if case .focus(let a) = m {
            host.visible = [a]
            host.detach(except: [a])
            host.focusedPane = a
        } else {
            host.visible = []
            host.detach(except: [])
        }
    }

    func key(_ k: String, _ what: String) -> [HerdSpan] {
        [.init(text: k, fg: accent, bold: true), .init(text: " " + what + "  ", fg: Mocha.overlay0)]
    }

    func bar(_ left: [HerdSpan], right: [HerdSpan] = [], cols: Int) -> some View {
        HerdLine(spans: left, right: right, cols: cols, bg: raised, cell: cell)
    }

    // MARK: list

    func list(cols: Int) -> some View {
        let sections = host.inbox
        return VStack(spacing: 0) {
            bar([.init(text: " ◈ ", fg: accent), .init(text: "Herd", fg: Mocha.text, bold: true)],
                right: key("⌘N", "send") + key("⌘F", "herdr screen"), cols: cols)
            ScrollView {
                VStack(spacing: 0) {
                    if sections.isEmpty {
                        HerdLine(spans: [.init(text: "  no terminals in herdr · ⌘N to start one", fg: Mocha.overlay0)],
                                 cols: cols, cell: cell)
                    }
                    ForEach(sections, id: \.bucket) { s in
                        HerdLine(spans: [], cols: cols, cell: cell)
                        HerdLine(spans: [.init(text: " " + s.bucket.title,
                                               fg: s.bucket == .needsYou ? Mocha.red : Mocha.overlay1, bold: true)],
                                 cols: cols, cell: cell)
                        ForEach(s.rows) { r in row(r, cols: cols) }
                    }
                }
            }
            .scrollIndicators(.never)
            bar([.init(text: " ")] + key("↑↓", "move") + key("⏎", "open") + key("y/n", "answer")
                + key("⌘O", "herdr-app"), cols: cols)
        }
    }

    func row(_ r: HerdInboxRow, cols: Int) -> some View {
        let a = host.agents[r.address]
        let on = host.inboxSelection == r.address
        let g = host.git[host.place(of: r.space)]
        let name = g.map { $0.linked ? "⎇ " + $0.branch : host.name(of: r.space) } ?? host.name(of: r.space)
        let what: String = switch r.state {
        case .idle, .unknown: a?.msg ?? (a?.state == nil ? (a?.cwd).map(tilde) ?? "" : a?.title ?? "")
        default: a?.msg ?? a?.title ?? ""
        }
        let nameW = min(18, cols / 5)
        return TimelineView(.periodic(from: .now, by: 5)) { ctx in
            HerdLine(spans: [
                .init(text: on ? "▌" : " ", fg: accent),
                .init(text: r.state.icon + " ", fg: r.state.color),
                .init(text: pad(name, nameW), fg: on ? Mocha.text : Mocha.subtext0, bold: true),
                .init(text: pad(a?.label ?? "?", 9), fg: Mocha.overlay1),
                .init(text: what, fg: r.state == .blocked ? Mocha.text : Mocha.subtext0),
            ], right: [.init(text: " " + age(host.changed[r.address], now: ctx.date) + " ", fg: Mocha.overlay0)],
            cols: cols, clip: cols - 6, bg: on ? Mocha.activeRow : .clear, cell: cell)
        }
        .contentShape(Rectangle())
        .onTapGesture { host.open(r.address) }
        .contextMenu {
            if r.state == .blocked {
                Button("Answer Yes (Enter)") { host.answer(r.address, yes: true) }
                Button("Answer No (Esc)") { host.answer(r.address, yes: false) }
            }
            Button("Open in herdr-app") { host.openInApp(r.address) }
        }
    }

    func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? String(s.prefix(w - 2)) + "… " : s.padding(toLength: w, withPad: " ", startingAt: 0)
    }

    func age(_ d: Date?, now: Date) -> String {
        guard let d else { return "" }
        let s = Int(now.timeIntervalSince(d))
        return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : s < 86400 ? "\(s / 3600)h" : "\(s / 86400)d"
    }

    // MARK: focus

    func focus(_ address: String, cols: Int) -> some View {
        let a = host.agents[address]
        let st = host.state(address)
        let space = host.spaces.first { $0.tabs.contains { $0.root.terminals.contains(address) } }
        let g = space.flatMap { host.git[host.place(of: $0)] }
        let place = (a?.cwd).map(tilde) ?? ""
        return VStack(spacing: 0) {
            Button { host.mode = .inbox } label: {
                bar([.init(text: " ⌘← inbox   ", fg: Mocha.overlay1),
                     .init(text: st.icon + " ", fg: st.color),
                     .init(text: space.map(host.name) ?? address, fg: Mocha.text, bold: true),
                     .init(text: " · " + (a?.label ?? "?") + " · " + place + (g.map { " (\($0.branch))" } ?? ""),
                           fg: Mocha.overlay0)],
                    right: key("⌘O", "herdr-app"), cols: cols)
            }
            .buttonStyle(.plain)
            HerdPaneView(address: address, borders: false, store: store, host: host, cell: cell)
            bar([.init(text: " ")] + key("⌘I", "inbox") + key("⌘↑↓", "prev/next needing you")
                + key("⌘N", "send") + key("⌘F", "herdr screen"), cols: cols)
        }
    }
}

struct HerdComposer: View {
    @ObservedObject var host: HerdHost
    let theme: Theme
    let cell: HerdCell
    let cols: Int
    var accent: SwiftUI.Color { theme.herdAccent }
    var raised: SwiftUI.Color { theme.herdRaised }
    @State private var task = ""
    // what you picked last time is what you get next time
    @AppStorage("herdSendFolder") private var folder = ""
    @AppStorage("herdSendAgent") private var agent = "claude"
    @AppStorage("herdSendWorktree") private var worktree = false
    @State private var branch = ""
    @State private var branchEdited = false
    @FocusState private var typing: Bool

    var body: some View {
        let places = host.places
        let place = places.contains(folder) ? folder : places.first ?? NSHomeDirectory()
        let repo = host.git[place].map { !$0.repo.isEmpty } ?? false
        let font = Font(cell.font)
        VStack(alignment: .leading, spacing: 0) {
            HerdLine(spans: [.init(text: " ◈ ", fg: accent), .init(text: "New task", fg: Mocha.text, bold: true)],
                     right: [.init(text: "esc", fg: accent, bold: true), .init(text: " cancel ", fg: Mocha.overlay0)],
                     cols: cols, bg: raised, cell: cell)
            VStack(alignment: .leading, spacing: cell.h * 0.9) {
                // the prompt: a box like herdr's focused pane
                HStack(alignment: .firstTextBaseline, spacing: cell.w) {
                    Text("▸").font(Font(cell.bold)).foregroundStyle(accent)
                    TextField("", text: $task, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focusEffectDisabled()
                        .font(font)
                        .foregroundStyle(Mocha.text)
                        .lineLimit(1...4)
                        .focused($typing)
                        .onSubmit { send(place, watch: false) }
                        .onChange(of: task) { _, t in if !branchEdited { branch = slug(t) } }
                        .background(alignment: .topLeading) { placeholder("what should it do?", shown: task.isEmpty) }
                }
                .padding(.horizontal, cell.w)
                .padding(.vertical, cell.h * 0.5)
                .background(raised)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(typing ? accent : Mocha.surface0, lineWidth: 1))

                Grid(alignment: .leading, horizontalSpacing: cell.w * 2, verticalSpacing: cell.h * 0.6) {
                    GridRow {
                        label("in")
                        HStack(spacing: cell.w * 2) {
                            Menu {
                                ForEach(places, id: \.self) { p in Button(tilde(p)) { folder = p } }
                            } label: {
                                chip((place as NSString).lastPathComponent, detail: tilde((place as NSString).deletingLastPathComponent))
                            }
                            // one click to the other places you work in
                            HStack(spacing: cell.w) {
                                ForEach(places.filter { $0 != place }.prefix(3), id: \.self) { p in
                                    Text((p as NSString).lastPathComponent)
                                        .font(font).foregroundStyle(Mocha.overlay1)
                                        .onTapGesture { folder = p }
                                }
                            }
                        }
                    }
                    GridRow {
                        label("as")
                        HStack(spacing: cell.w) {
                            ForEach(herdAgentApps, id: \.self) { a in
                                Text(a)
                                    .font(a == agent ? Font(cell.bold) : font)
                                    .foregroundStyle(a == agent ? raised : Mocha.overlay1)
                                    .padding(.horizontal, cell.w * 0.8)
                                    .padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(a == agent ? accent : Mocha.surface0))
                                    .onTapGesture { agent = a }
                            }
                        }
                    }
                    GridRow {
                        label("⎇")
                        HStack(spacing: cell.w * 2) {
                            Text((worktree && repo ? "[x]" : "[ ]") + " new worktree")
                                .font(font)
                                .foregroundStyle(repo ? (worktree ? Mocha.text : Mocha.subtext0) : Mocha.overlay0)
                                .onTapGesture { if repo { worktree.toggle() } }
                            if !repo {
                                Text("not a git repo").font(font).foregroundStyle(Mocha.overlay0)
                            } else if worktree {
                                TextField("", text: $branch)
                                    .textFieldStyle(.plain)
                                    .focusEffectDisabled()
                                    .font(font)
                                    .foregroundStyle(Mocha.mauve)
                                    .onSubmit { send(place, watch: false) }
                                    .onChange(of: branch) { _, b in branchEdited = b != slug(task) }
                                    .background(alignment: .leading) { placeholder("branch", shown: branch.isEmpty) }
                            }
                        }
                    }
                }
                .padding(.leading, cell.w)
            }
            .padding(.horizontal, cell.w * 2)
            .padding(.vertical, cell.h)
            Spacer(minLength: 0)
            HerdLine(spans: [.init(text: " "),
                             .init(text: "⏎", fg: accent, bold: true), .init(text: " send & hide  ", fg: Mocha.overlay0),
                             .init(text: "⌘⏎", fg: accent, bold: true), .init(text: " send & watch  ", fg: Mocha.overlay0),
                             .init(text: "tab", fg: accent, bold: true), .init(text: " next field", fg: Mocha.overlay0)],
                     cols: cols, bg: raised, cell: cell)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onReceive(NotificationCenter.default.publisher(for: .herdSendAndWatch)) { _ in send(place, watch: true) }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { typing = true } }
    }

    // macOS draws a TextField's prompt in its own grey, whatever the style says
    func placeholder(_ s: String, shown: Bool) -> some View {
        Text(s).font(Font(cell.font)).foregroundStyle(SwiftUI.Color(nsColor: theme.dim))
            .opacity(shown ? 1 : 0).allowsHitTesting(false)
    }

    func label(_ s: String) -> some View {
        Text(s).font(Font(cell.font)).foregroundStyle(Mocha.overlay0).gridColumnAlignment(.trailing)
    }

    func chip(_ name: String, detail: String) -> some View {
        HStack(spacing: cell.w) {
            Text(name).font(Font(cell.bold)).foregroundStyle(Mocha.text)
            Text(detail).font(Font(cell.font)).foregroundStyle(Mocha.overlay0)
            Text("▾").font(Font(cell.font)).foregroundStyle(Mocha.overlay1)
        }
        .padding(.horizontal, cell.w * 0.8)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(Mocha.surface0))
        .fixedSize()
    }

    func send(_ place: String, watch: Bool) {
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        folder = place
        let b = branch.trimmingCharacters(in: .whitespaces)
        host.send(t, folder: place, agent: agent, branch: worktree && !b.isEmpty ? b : nil, watch: watch)
    }

    // the task's first words: "fix the flaky test in orders" -> fix-the-flaky-test-in
    func slug(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.prefix(5).joined(separator: "-")
    }
}

extension Notification.Name {
    static let herdSendAndWatch = Notification.Name("herdSendAndWatch")
}

extension Theme {
    var herdAccent: SwiftUI.Color { SwiftUI.Color(nsColor: accent) }
    // bars and boxes: the island's ink, lifted a little toward its text
    var herdRaised: SwiftUI.Color { SwiftUI.Color(nsColor: ink.blended(withFraction: 0.06, of: paper) ?? ink) }
}
