#if os(macOS)
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Places the vertical tabs sidebar to the left of the terminal content.
struct VerticalTabsLayout<Content: View>: View {
    let controller: TerminalController
    @ObservedObject var ghostty: Ghostty.App
    @StateObject private var model: VerticalTabsModel
    @StateObject private var overlay = VerticalTabsOverlayState()
    @ObservedObject private var editorPanel = EditorPanel.shared
    @ObservedObject private var hermes = HermesSessions.shared
    @ObservedObject private var commandBlocks = CommandBlocksPanel.shared
    @ObservedObject private var visualFix = VisualFixPanel.shared
    /// Pauses the chrome's animations while this window (tab) isn't on screen.
    @StateObject private var motion = WindowMotion()
    @ObservedObject private var settings = ExtremeSettings.shared
    @AppStorage(EditorPanel.widthKey) private var editorWidth: Double = EditorPanel.defaultWidth
    @AppStorage(VisualFixPanel.widthKey) private var visualFixWidth: Double = VisualFixPanel.defaultWidth
    @AppStorage(AgentAurora.enabledKey) private var aurora = false
    @AppStorage(VerticalTabs.visibleKey) private var visible: Bool = true
    @AppStorage(VerticalTabs.widthKey) private var width: Double = VerticalTabs.defaultWidth
    private let content: Content

    init(controller: TerminalController, ghostty: Ghostty.App, @ViewBuilder content: () -> Content) {
        self.controller = controller
        self.ghostty = ghostty
        self._model = StateObject(wrappedValue: VerticalTabsModel(owner: controller))
        self.content = content()
    }

    /// The terminal never gets narrower than this to make room for side panels.
    private var minTerminalWidth: CGFloat { 320 }

    var body: some View {
        // Side panels have set widths; when the window is narrower than they need (macOS can
        // hand a window back smaller, e.g. from Stage Manager), the editor gives way so
        // nothing is pushed past the window's edge.
        GeometryReader { geometry in
            let limits = panelLimits(in: geometry.size.width)
            layout(maxEditorWidth: limits.editor, maxVisualFixWidth: limits.visualFix)
        }
        // "Status only" in Settings stops the decorative motion everywhere.
        .environment(\.extremeMotion, motion.active && settings.motion == .full)
        .onAppear { motion.attach(controller.window) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in motion.attach(controller.window) }
    }

    /// The most room the editor and Visual Fix can each have. When both want more than the
    /// window has, they share it in proportion.
    private func panelLimits(in total: CGFloat) -> (editor: CGFloat, visualFix: CGFloat) {
        let sidebar = visible && ghostty.readiness == .ready ? CGFloat(width) + 1 : 0
        let history: CGFloat = commandBlocks.isVisible(controller) ? 400 : 0
        let available = max(0, total - sidebar - history - minTerminalWidth - 2)
        let editor = editorPanel.isVisible(controller) ? CGFloat(editorWidth) : 0
        let fix = visualFix.isVisible(controller) ? CGFloat(visualFixWidth) : 0
        guard editor + fix > available, editor + fix > 0 else { return (max(240, available), max(360, available)) }
        let scale = available / (editor + fix)
        return (max(240, editor * scale), max(300, fix * scale))
    }

    private func layout(maxEditorWidth: CGFloat, maxVisualFixWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            if visible && ghostty.readiness == .ready {
                VerticalTabsSidebar(model: model, owner: controller, config: ghostty.config)
                    .frame(width: width)
                    .environmentObject(overlay)
                VerticalTabsResizeHandle(width: $width)
            }
            // A Hermes tab shows Hermes's own app over its (hidden, idle) terminal.
            ZStack {
                content
                if hermes.isHermes(controller) {
                    HermesSessionView(controller: controller)
                }
                // Light behind the terminal that follows the tab's agents.
                if aurora, !hermes.isHermes(controller) {
                    AgentAurora(controller: controller)
                }
                // "Your app is live" when a localhost session starts listening.
                LocalhostToastLayer(controller: controller)
                // Branding: pixel corner brackets (a traveling light while an agent works)
                // and the sigil assembling when the tab opens.
                TerminalFrameOverlay(controller: controller)
                NewTabSplash()
            }
            // Each tab has its own editor.
            if editorPanel.isVisible(controller) {
                EditorPanelColumn(controller: controller, maxWidth: maxEditorWidth)
            }
            // Point at the running app and have the agent change it.
            if visualFix.isVisible(controller) {
                VisualFixColumn(controller: controller, maxWidth: maxVisualFixWidth)
            }
            if commandBlocks.isVisible(controller) {
                CommandBlocksColumn(controller: controller)
            }
        }
        .coordinateSpace(name: verticalTabsSpace)
        .overlay {
            if visible && ghostty.readiness == .ready {
                VerticalTabsOverlayLayer(
                    state: overlay,
                    palette: VerticalTabsPalette(config: ghostty.config),
                    sidebarWidth: width)
            }
        }
        .onChange(of: visible) { _ in overlay.dismissAll() }
        .onAppear {
            VerticalTabsMenu.shared.installIfNeeded()
            ExtremeLaunch.start()
            ReviewInbox.start()
            TurnCheckpoints.start()
            VerticalTabsTestSupport.openTestTabsIfRequested(from: controller)
        }
    }
}

/// Test-only: `GHOSTTY_EXTREME_TEST_TABS=N` (set by a test launch, never in normal use)
/// opens N tabs at startup so the sidebar can be exercised without UI scripting.
enum VerticalTabsTestSupport {
    private static var didOpen = false

    /// `GHOSTTY_EXTREME_TEST_OVERLAY=hover|menu|git`: the selected row opens its hover card,
    /// ⋮ menu or Git panel shortly after launch.
    static let overlayMode = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_OVERLAY"]
    static let showOverlay = Notification.Name("com.steventsvik.ghostty-extreme.testShowOverlay")

    static func openTestTabsIfRequested(from controller: TerminalController) {
        guard !didOpen else { return }
        didOpen = true
        MainActor.assumeIsolated { DemoDirector.startIfRequested(from: controller) }
        if overlayMode != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                NotificationCenter.default.post(name: showOverlay, object: nil)
            }
        }
        if let name = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_COLOR"],
           let color = TerminalTabColor.allCases.first(where: { $0.localizedName.lowercased() == name }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { (controller.window as? TerminalWindow)?.tabColor = color }
        }
        if ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_SESSION"] == "hermes" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NewSessionKind.hermes.open(from: controller) }
        }
        // `GHOSTTY_EXTREME_TEST_SESSION=docker:<kind>`: open an isolated Docker session.
        if let value = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_SESSION"], value.hasPrefix("docker:"),
           let kind = DockerSessionKind(rawValue: String(value.dropFirst("docker:".count))) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { DockerSessions.open(kind, from: controller) }
        }
        // `GHOSTTY_EXTREME_TEST_EDITOR_DELAY`: seconds before opening it (default 1.5).
        if let file = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_EDITOR"] {
            let delay = Double(ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_EDITOR_DELAY"] ?? "") ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // A folder (trailing slash) opens the editor the way a user does, with no file.
                if file.hasSuffix("/") {
                    EditorPanel.shared.show(from: controller)
                } else {
                    EditorPanel.shared.show(from: controller, folder: (file as NSString).deletingLastPathComponent)
                    EditorPanel.shared.session(for: controller).webView.openFile(file, line: 20)
                }
                // `GHOSTTY_EXTREME_TEST_EDITOR_JS`: script run in the editor once it's loaded.
                if let script = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_EDITOR_JS"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        EditorPanel.shared.session(for: controller).webView.evaluateJavaScript(script)
                    }
                }
            }
        }
        // `GHOSTTY_EXTREME_TEST_BACKGROUND=<seconds>`: open the Background window then.
        if let value = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_BACKGROUND"], let delay = Double(value) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { HousekeepingWindow.show() }
        }
        // `GHOSTTY_EXTREME_TEST_VISUAL=<seconds>`: open Visual Fix on the best running app then.
        if let value = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_VISUAL"], let delay = Double(value) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { VisualFixPanel.shared.show(from: controller) }
        }
        // `GHOSTTY_EXTREME_TEST_PALETTE=1`: open the command palette in the visible tab after 11s.
        if ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_PALETTE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
                let window = controller.window?.tabGroup?.selectedWindow ?? controller.window
                (window?.windowController as? BaseTerminalController)?.toggleCommandPalette(nil)
            }
        }
        let env = ProcessInfo.processInfo.environment
        // `GHOSTTY_EXTREME_TEST_TYPE=<command>`: types it (plus Enter) into the first tab after 3s.
        if let command = env["GHOSTTY_EXTREME_TEST_TYPE"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let model = controller.focusedSurface?.surfaceModel else { return }
                model.sendText(command)
                model.sendKeyEvent(.init(key: .enter, action: .press, text: "\r"))
                model.sendKeyEvent(.init(key: .enter, action: .release))
            }
        }
        // `GHOSTTY_EXTREME_TEST_REVIEW=comment,send,undo,commit`: acts on the first review item,
        // one step every 3s starting at 24s, logging to `GHOSTTY_EXTREME_TEST_LOG`.
        if let steps = env["GHOSTTY_EXTREME_TEST_REVIEW"] {
            let log: (String) -> Void = { line in
                guard let path = env["GHOSTTY_EXTREME_TEST_LOG"] else { return }
                let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                try? (old + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 24_000_000_000)
                let inbox = ReviewInbox.shared
                for step in steps.split(separator: ",") {
                    guard let item = inbox.items.first else { log("\(step): no review item"); break }
                    switch step {
                    case "comment":
                        if let file = item.files.first, let line = file.hunks.first?.lines.first(where: { $0.kind == .added }) {
                            inbox.addComment("Use Decimal for money; floats round badly.", on: line, file: file, in: item)
                        }
                        log("comment: \(inbox.items.first?.comments.count ?? 0) comments")
                    case "send":
                        log("send: \(inbox.sendFeedback(item))")
                    case "undo":
                        if let file = item.files.first(where: { $0.status == .added }) { inbox.undo(file, in: item) }
                        log("undo: requested")
                    case "commit":
                        inbox.commit(item, message: "Add discount codes") { error in log("commit: \(error ?? "ok")") }
                    default:
                        break
                    }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                log("files now: \(inbox.items.first?.files.map(\.path) ?? [])")
            }
        }
        // `GHOSTTY_EXTREME_TEST_OPEN=localhost,review,activity,blocks,setup,welcome,settings,shortcuts`: open those after
        // `GHOSTTY_EXTREME_TEST_OPEN_DELAY` seconds (default 10).
        if let windows = env["GHOSTTY_EXTREME_TEST_OPEN"] {
            let delay = Double(env["GHOSTTY_EXTREME_TEST_OPEN_DELAY"] ?? "") ?? 10
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for name in windows.split(separator: ",") {
                    switch name {
                    case "localhost": LocalhostManager.show()
                    case "review": ReviewInbox.show()
                    case "activity": ActivityDashboard.toggle()
                    case "blocks": CommandBlocksPanel.shared.show(controller)
                    case "setup": SetupCheckWindow.show()
                    case "welcome": WelcomeWindow.show()
                    case "settings": ExtremeSettingsWindow.show()
                    case "shortcuts":
                        ShortcutSheet.shared.show(sticky: true)
                        if let path = env["GHOSTTY_EXTREME_TEST_LOG"] {
                            let lines = ShortcutSheet.collect().map { "\($0.id): " + $0.shortcuts.map { "\($0.keys) \($0.title)" }.joined(separator: ", ") }
                            let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                            try? (old + lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                        }
                    default: break
                    }
                }
            }
        }
        // `GHOSTTY_EXTREME_TEST_SETUP=1` (with `GHOSTTY_EXTREME_TEST_HOME=<scratch folder>`): after 4s,
        // do what the welcome window's "Set up" does, logging the result.
        if env["GHOSTTY_EXTREME_TEST_SETUP"] == "1", env["GHOSTTY_EXTREME_TEST_HOME"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let result: String
                do { result = try HookInstaller.setUp(claude: true, codex: true, shell: true).joined(separator: ", ") } catch { result = "error: \(error)" }
                if let path = env["GHOSTTY_EXTREME_TEST_LOG"] {
                    let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                    try? (old + "setup: " + result + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                }
                SetupChecks.shared.refresh()
            }
        }
        // `GHOSTTY_EXTREME_TEST_STOP_PORT=<port>`: after 12s, Stop whatever listens there (as the
        // Ports section's Stop does), logging what was listening before and after.
        if let value = env["GHOSTTY_EXTREME_TEST_STOP_PORT"], let port = Int(value) {
            let log: (String) -> Void = { line in
                guard let path = env["GHOSTTY_EXTREME_TEST_LOG"] else { return }
                let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                try? (old + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                let monitor = PortsMonitor.shared
                log("ports: " + monitor.entries.map { ":\($0.port) \($0.kind) \($0.title) [\($0.command)]" }.joined(separator: ", "))
                log("conflict: \(monitor.conflict.map { String($0.port) } ?? "none")")
                guard let entry = monitor.entries.first(where: { $0.port == port }) else { log("stop: nothing on \(port)"); return }
                monitor.stop(entry)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    log("after stop: \(port) " + (monitor.entries.contains { $0.port == port } ? "still listening" : "free")
                        + ", pid \(entry.pid) " + (ProcessProbe.isAlive(entry.pid) ? "alive" : "gone"))
                }
            }
        }
        // `GHOSTTY_EXTREME_TEST_DUMP_SCREEN=<seconds>`: write the focused pane's screen to
        // `<GHOSTTY_EXTREME_TEST_LOG>.screen` then (to see exactly what an agent's idle screen looks like).
        if let value = env["GHOSTTY_EXTREME_TEST_DUMP_SCREEN"], let delay = Double(value),
           let path = env["GHOSTTY_EXTREME_TEST_LOG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let surface = controller.focusedSurface else { return }
                let info = VerticalTabsAgents.shared.info(for: surface)
                let screen = surface.cachedVisibleContents.get()
                // Its own file: other test logging rewrites the log as it goes.
                try? ("agent: \(info.map { "\($0.kind) \($0.activity)" } ?? "none")\n----\n\(screen)\n----\n")
                    .write(toFile: path + ".screen", atomically: true, encoding: .utf8)
            }
        }
        // `GHOSTTY_EXTREME_TEST_PRESENT=1`: after 8s, present the first tab's pane the way
        // Mission Control's Open does (while a later tab is selected).
        if env["GHOSTTY_EXTREME_TEST_PRESENT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard let surface = controller.surfaceTree.first else { return }
                NotificationCenter.default.post(name: Ghostty.Notification.ghosttyPresentTerminal, object: surface)
            }
        }
        // `GHOSTTY_EXTREME_TEST_MISSION=1`: open Mission Control after 12s.
        if env["GHOSTTY_EXTREME_TEST_MISSION"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { MissionControl.show() }
        }
        // `GHOSTTY_EXTREME_TEST_HANDOFF=review|continue`: hand the first pane off to Claude Code after 6s.
        if let mode = env["GHOSTTY_EXTREME_TEST_HANDOFF"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                guard let surface = controller.focusedSurface else { return }
                AgentHandoff.handOff(from: surface, in: controller, to: .claude, mode: mode == "continue" ? .continue : .review)
            }
        }
        // `GHOSTTY_EXTREME_TEST_RACE=<task>`: race one Claude and one Codex after 4s; with
        // `GHOSTTY_EXTREME_TEST_RACE_KEEP=1`, keep claude-1's changes at 30s and clean up at 36s,
        // logging to `GHOSTTY_EXTREME_TEST_LOG`.
        if let task = env["GHOSTTY_EXTREME_TEST_RACE"], let folder = env["GHOSTTY_EXTREME_TEST_RACE_FOLDER"] {
            let log: (String) -> Void = { line in
                guard let path = env["GHOSTTY_EXTREME_TEST_LOG"] else { return }
                let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                try? (old + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                AgentRaces.shared.start(task: task, folder: folder, counts: [.claude: 1, .codex: 1],
                                        includeChanges: true, from: controller) { result in
                    switch result {
                    case .failure(let error): log("race failed: \(error.message)")
                    case .success(let race):
                        log("race \(race.id) " + race.contestants.map { "\($0.id)=\($0.worktree)" }.joined(separator: " "))
                        AgentRaces.show(race, from: controller)
                        guard env["GHOSTTY_EXTREME_TEST_RACE_KEEP"] == "1" else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 26) {
                            AgentRaces.shared.keep(race.contestants[0], of: race) { error in
                                log("keep: \(error ?? "ok")")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                                    AgentRaces.shared.cleanUp(race)
                                    log("cleaned up")
                                }
                            }
                        }
                    }
                }
            }
        }
        // Report which window is the visible tab so a test can capture that one.
        if let path = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_WINDOW_FILE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                let window = controller.window?.tabGroup?.selectedWindow ?? controller.window
                try? String(window?.windowNumber ?? 0).write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // `GHOSTTY_EXTREME_TEST_RESELECT=1`: switch back to the first tab after 9s and
        // report its window in <window file>.2.
        if ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_RESELECT"] == "1",
           let path = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_WINDOW_FILE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                VerticalTabsActions.select(controller)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    try? String(controller.window?.windowNumber ?? 0).write(toFile: path + ".2", atomically: true, encoding: .utf8)
                }
            }
        }
        guard let value = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_TABS"],
              let count = Int(value), count > 1 else { return }
        for i in 1..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * Double(i)) {
                controller.newTab(nil)
            }
        }
    }
}

/// A thin draggable divider that resizes the sidebar.
private struct VerticalTabsResizeHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double?
    @State private var cursorPushed = false

    var body: some View {
        Rectangle()
            .fill(Extreme.line)
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        // Keep push/pop balanced so the cursor stack never leaks.
                        if inside, !cursorPushed {
                            NSCursor.resizeLeftRight.push()
                            cursorPushed = true
                        } else if !inside, cursorPushed {
                            NSCursor.pop()
                            cursorPushed = false
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                let proposed = start + value.translation.width
                                width = min(max(proposed, VerticalTabs.widthRange.lowerBound),
                                            VerticalTabs.widthRange.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            )
    }
}

/// Which tab groups are collapsed. Shared so every window's sidebar agrees.
final class VerticalTabsCollapse: ObservableObject {
    static let shared = VerticalTabsCollapse()
    @Published var collapsed: Set<ObjectIdentifier> = []

    func toggle(_ id: ObjectIdentifier) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}

struct VerticalTabsSidebar: View {
    @ObservedObject var model: VerticalTabsModel
    let owner: TerminalController
    let config: Ghostty.Config

    @AppStorage(VerticalTabs.condensedKey) private var condensed = false
    @ObservedObject private var collapse = VerticalTabsCollapse.shared
    @ObservedObject private var workspaces = VerticalTabsWorkspaces.shared
    @ObservedObject private var settings = ExtremeSettings.shared
    /// Scrolls the list when a row is dragged to one of its ends. Held here rather than by the
    /// drag state, because what it scrolls is this sidebar's list. It publishes nothing, so
    /// having it on this view costs it no redraws.
    @StateObject private var autoScroll: VerticalTabAutoScroll
    /// The row drag in progress.
    ///
    /// Deliberately not view state here. The list below is a plain, non-lazy stack, and a
    /// property wrapper on this view invalidates it whatever the body reads — so a drag,
    /// which reports a new position on nearly every mouse move, would rebuild every tab's
    /// panes. The sidebar only hands the object to the rows, which watch it themselves.
    private var drag: VerticalTabDragState { .shared }

    init(model: VerticalTabsModel, owner: TerminalController, config: Ghostty.Config) {
        self.model = model
        self.owner = owner
        self.config = config
        self._autoScroll = StateObject(wrappedValue: VerticalTabAutoScroll(owner: ObjectIdentifier(owner)))
    }

    var body: some View {
        let palette = VerticalTabsPalette(config: config)

        VStack(spacing: 0) {
            // The list, and everything above it. A row dropped anywhere up here goes to the
            // front: there is no row to aim at, and the top of the list is what the whole
            // run of sidebar above the list names.
            VStack(spacing: 0) {
                header
                Rectangle().fill(Extreme.line).frame(height: 1)
                if let updates = (NSApp.delegate as? AppDelegate)?.updateViewModel {
                    UpdateCard(model: updates)
                }

                // The list is told how much room it has so that it can fill it. With only a
                // few sessions there would otherwise be a slab of sidebar below the last row
                // belonging to nothing, and a row dropped there would fly back.
                GeometryReader { space in
                    ScrollView {
                        // Not lazy: a lazy stack estimates the height of rows scrolled out of
                        // view, so when agent rows change height it loses the scroll position
                        // and jumps.
                        //
                        // No spacing either: each row carries half the gap between rows in
                        // its own padding (see `rowGutter`), so no strip of the list belongs
                        // to no row.
                        VStack(alignment: .leading, spacing: 0) {
                            ExtremeSectionLabel("Sessions") {
                                Text("\(model.tabs.count)")
                                    .font(Extreme.font(10)).foregroundColor(Extreme.dim)
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, rowGutter)
                            // The one part of the list no row covers, and it stands for the
                            // top of the list: a row dropped on it goes first, and — like
                            // every other place that names no workspace — leaves the one it
                            // was in.
                            .onDrop(of: [VerticalTabDragState.pasteboardType],
                                    delegate: VerticalTabEdgeDropDelegate(drag: drag,
                                                                          owner: ObjectIdentifier(owner),
                                                                          toFront: true,
                                                                          count: model.tabs.count,
                                                                          drop: pullDraggedTab))
                            ForEach(items()) { item in
                                switch item {
                                case .tab(let index, let entry):
                                    if let controller = entry.controller {
                                        // A tab the user pulled out of its workspace is drawn
                                        // here, between the sections; it still wears the
                                        // workspace's colour, since it is still one of its
                                        // tabs and its menu offers to put it back.
                                        tabGroup(controller, entry: entry, index: index, palette: palette,
                                                 sectionColor: workspaces.section(for: controller)?.color)
                                            .transition(.opacity)
                                    }
                                case .section(let section, let members):
                                    // A drop on a workspace's header merges the workspace the
                                    // tab comes from into this one, which is the one thing a
                                    // drop on the name can name. "Other" is not a workspace,
                                    // so a drop on its name is an ordinary move to the top of
                                    // it.
                                    let block: (ObjectIdentifier, Int) -> Void = section.isImplicit
                                        ? moveDraggedTab
                                        : { [section] id, index in
                                            dropOnBlock(id, onto: section.id, at: index)
                                        }
                                    // Where the block's tabs start in the tab order, which is
                                    // the place a drop on the block names, counting from 1 the
                                    // way the rest of this list does.
                                    let first = members.first?.0 ?? 1
                                    // Read once for the whole section rather than in each
                                    // row: it walks the folder up to its repository.
                                    let sectionColor = section.color
                                    // A drop on one of the rows names that row rather than the
                                    // block: the tab joins the workspace on its own, and the
                                    // one it came from is left where it is. "Other" is not a
                                    // workspace to join, so its rows move tabs as every other
                                    // row does.
                                    let rowDrop: ((ObjectIdentifier, Int) -> Void)? = section.isImplicit ? nil : { [section] id, index in
                                        dropInSection(id, onto: section.id, at: index)
                                    }
                                    VerticalTabsWorkspaceSectionView(
                                        section: section,
                                        controllers: members.compactMap(\.1.controller),
                                        owner: owner,
                                        block: block,
                                        first: first
                                    ) {
                                        VStack(spacing: 0) {
                                            ForEach(members, id: \.1.id) { index, entry in
                                                if let controller = entry.controller {
                                                    tabGroup(controller, entry: entry, index: index, palette: palette, inSection: true,
                                                             sectionColor: sectionColor,
                                                             drop: rowDrop)
                                                }
                                            }
                                        }
                                    }
                                    // The block's frame, and everything inside it that no row
                                    // and no header covers: the room its own inset leaves, the
                                    // gaps between its rows, and the space it keeps above and
                                    // below itself. None of that names a workspace, so a
                                    // session dropped there leaves the one it was in and is
                                    // drawn on its own — which is how a session is taken back
                                    // out of a workspace at all, since every other place a
                                    // drop can land names one.
                                    //
                                    // It is a shape of the block's own making, so those places
                                    // are reached at all: without it a drop in the gap between
                                    // two blocks falls to the list below, which only knows how
                                    // to move a tab in the tab order.
                                    .contentShape(Rectangle())
                                    // The line at the top of the block, which is where a drop
                                    // on the block puts the tab.
                                    .overlay(alignment: .top) {
                                        VerticalTabBlockLine(drag: drag,
                                                             owner: ObjectIdentifier(owner),
                                                             block: section.id)
                                    }
                                    .onDrop(of: [VerticalTabDragState.pasteboardType],
                                            delegate: VerticalTabBlockDropDelegate(drag: drag,
                                                                                   owner: ObjectIdentifier(owner),
                                                                                   block: section.id,
                                                                                   top: first - 1,
                                                                                   drop: pullDraggedTab))
                                    .transition(.asymmetric(insertion: .scale(scale: 0.97, anchor: .top).combined(with: .opacity),
                                                            removal: .opacity))
                                }
                            }
                        }
                        .frame(minHeight: space.size.height, alignment: .topLeading)
                        .padding(.bottom, 10 - rowGutter)
                        // The scroll view the list is drawn in, so that a drag to either end
                        // of it can scroll it (see `VerticalTabAutoScroll`).
                        .background(SidebarScrollFinder { autoScroll.scrollView = $0 })
                        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: groupLayout)
                        // A dropped row slides into its new place instead of jumping there.
                        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: model.tabs)
                        // Catches a drop in the room the list fills below its last row, and in
                        // whatever strip of it no row covers. Everything else in the sidebar
                        // has a drop target of its own: the rows and the blocks are deeper
                        // than this one, and so take the drop when the pointer is over them.
                        // What is left is the room around the last block, which names no
                        // workspace, so a session dropped there leaves the one it was in.
                        .onDrop(of: [VerticalTabDragState.pasteboardType],
                                delegate: VerticalTabListDropDelegate(drag: drag,
                                                                      owner: ObjectIdentifier(owner),
                                                                      drop: pullDraggedTab))
                    }
                }
            }
            // Everything above the list, which names no workspace either: the tab goes to the
            // front, and comes out of the workspace it was in.
            .onDrop(of: [VerticalTabDragState.pasteboardType],
                    delegate: VerticalTabEdgeDropDelegate(drag: drag,
                                                          owner: ObjectIdentifier(owner),
                                                          toFront: true,
                                                          count: model.tabs.count,
                                                          drop: pullDraggedTab))

            // Everything below the list. A row dropped here goes last, and comes out of the
            // workspace it was in.
            VStack(spacing: 0) {
                // What's listening on which port (only when something is).
                if settings.isOn(.ports) {
                    PortsSidebarSection(owner: owner)
                }

                // Agent status needs setting up, or a live test just passed (only then).
                SetupSidebarChip().padding(.horizontal, 8).padding(.bottom, 6)

                // Things left running in the background that look finished (only when there are some).
                if settings.isOn(.background) {
                    HousekeepingChip().padding(.horizontal, 8).padding(.bottom, 6)
                }

                // Bottom left: live usage of the user's AI subscriptions.
                if settings.isOn(.usage) {
                    Rectangle().fill(Extreme.line).frame(height: 1)
                    UsagePanel(palette: palette)
                }
            }
            .onDrop(of: [VerticalTabDragState.pasteboardType],
                    delegate: VerticalTabEdgeDropDelegate(drag: drag,
                                                          owner: ObjectIdentifier(owner),
                                                          toFront: false,
                                                          count: model.tabs.count,
                                                          drop: pullDraggedTab))
        }
        .background(sidebarBackground)
        .onAppear { Extreme.registerFonts() }
    }

    /// What the list's layout depends on: which workspaces exist and how many tabs each holds.
    private var groupLayout: [String] {
        guard settings.isOn(.workspaces) else { return [] }
        return workspaces.sections.map { "\($0.id):\($0.members.count)" }.sorted()
    }

    /// One sidebar entry: a tab on its own, or a workspace's tabs gathered together.
    private enum Item: Identifiable {
        case tab(Int, VerticalTabEntry)
        case section(VerticalTabsWorkspaces.Section, [(Int, VerticalTabEntry)])

        var id: String {
            switch self {
            case .tab(_, let entry): return "tab-\(entry.id.hashValue)"
            case .section(let section, _): return "section-" + section.id
            }
        }
    }

    /// Tabs in order, with each workspace's tabs gathered where its first tab is and the tabs
    /// that belong to no workspace collected last.
    private func items() -> [Item] {
        // Off, the sidebar is the plain list of tabs it used to be.
        guard settings.isOn(.workspaces) else {
            return model.tabs.enumerated().map { .tab($0.offset + 1, $0.element) }
        }

        var result: [Item] = []
        var placed: Set<String> = []
        // The tabs that belong to no workspace, kept back so their section can be drawn last.
        var other: [(Int, VerticalTabEntry)] = []
        var otherSection: VerticalTabsWorkspaces.Section?
        // A tab the user dragged away from its workspace's tabs is an ordinary row, and no
        // longer counts as one of the workspace's — otherwise the section would gather it
        // straight back to where it was dragged from. See
        // `VerticalTabsWorkspaces.leavesSection`.
        let loose = model.tabs.enumerated().filter { _, entry in
            entry.controller.map { !workspaces.isDetached($0) } ?? false
        }
        for (offset, entry) in model.tabs.enumerated() {
            guard let controller = entry.controller,
                  !workspaces.isDetached(controller),
                  let section = workspaces.section(for: controller) else {
                result.append(.tab(offset + 1, entry))
                continue
            }
            // "Other" holds whatever is left, and is drawn after every workspace.
            if section.isImplicit {
                otherSection = section
                other.append((offset + 1, entry))
                continue
            }
            guard placed.insert(section.id).inserted else { continue }
            let members = loose.filter {
                $0.element.controller.map { section.members.contains(ObjectIdentifier($0)) } ?? false
            }
            result.append(.section(section, members.map { ($0.offset + 1, $0.element) }))
        }
        // With no workspace made yet there is nothing for them to be left out of, so they
        // stand on their own under the Sessions label rather than under a heading that says
        // nothing about them.
        if let otherSection, !placed.isEmpty {
            result.append(.section(otherSection, other))
        } else {
            result.append(contentsOf: other.map { .tab($0.0, $0.1) })
        }
        return result
    }

    private func tabGroup(_ controller: TerminalController, entry: VerticalTabEntry, index: Int,
                          palette: VerticalTabsPalette, inSection: Bool = false,
                          sectionColor: Color? = nil,
                          drop: ((ObjectIdentifier, Int) -> Void)? = nil) -> some View {
        // Only looked up for a tab the user has pulled out of its workspace, so the
        // row can offer to put it back. Both calls are lookups; nothing is computed unless
        // the tab is actually out.
        let section = workspaces.section(for: controller)
        // Where a tab the user filed by hand would be drawn otherwise: the row's menu offers
        // to put it back there. Nil for a tab that is drawn where its folder puts it.
        let moveTo = workspaces.isFiled(controller)
            ? workspaces.folderWorkspace(for: controller)?.name ?? VerticalTabsWorkspaces.otherName
            : nil
        // Whether this tab's folder is one no workspace owns yet, which is the one thing
        // "New Workspace" needs.
        let newWorkspace = workspaces.canCreateWorkspace(for: controller)
        return VerticalTabDragRow(
            drag: drag,
            // Which window's sidebar this is: every window in a tab group shows the same
            // tabs, and only the one the drag started in should react to it.
            owner: ObjectIdentifier(owner),
            // The row's place in the tab order, which is what a drop moves the tab to.
            index: index - 1,
            id: entry.id,
            // A row inside a workspace takes a tab from somewhere else into it, which is
            // what `dropInSection` is for; every other row moves the tab in the tab order.
            drop: drop ?? moveDraggedTab
        ) {
            VerticalTabGroup(
                controller: controller,
                owner: owner,
                index: index,
                tabColor: entry.tabColor,
                condensed: condensed,
                collapsed: collapse.collapsed.contains(entry.id),
                palette: palette,
                inSection: inSection,
                sectionColor: sectionColor,
                putBackWorkspace: workspaces.isDetached(controller) ? section?.name : nil,
                moveTo: moveTo,
                newWorkspace: newWorkspace,
                onToggleCollapse: { collapse.toggle(entry.id) })
        }
    }

    /// Puts the dragged tab where the row it was dropped on sits.
    private func moveDraggedTab(_ id: ObjectIdentifier, at index: Int) {
        // The drag ends here, where the move is made, rather than at the drop: the gold line
        // stays where it is until the tab has actually moved to it, so the row lands under the
        // line rather than the line going out a moment before the row arrives.
        defer { drag.end() }
        let tabs = model.tabs
        guard let controller = tabs.first(where: { $0.id == id })?.controller else { return }
        // Picked up and put straight back where it already was. Every drop that means only a
        // move refuses this before it gets here; a drop on a workspace's block has to ask,
        // because the same drop is also how a workspace is merged into another, and settling
        // the tab's place over a move that never happened would be a change it didn't ask for.
        guard tabs.firstIndex(where: { $0.id == id }) != index else { return }
        // Where a tab lands also settles the two things a tab carries beyond its place: the
        // run of pinned tabs at the top of the list, and the workspace section it may have
        // been dragged out of. Both are read off the order as it stands, before the move.
        VerticalTabsPins.shared.dragged(controller, to: index, among: tabs)
        if workspaces.leavesSection(controller, movingTo: index, in: tabs.map(\.id)) {
            workspaces.detach(controller)
        }
        // A tab dropped on one of its own workspace's tabs changes places with it inside the
        // section rather than moving in the tab order, which would take the whole section
        // with it. See `VerticalTabsWorkspaces.reorderWithinSection`.
        let order = tabs.map(\.id)
        if let onto = tabs[safe: index]?.id,
           let want = workspaces.reorderWithinSection(dragged: id, onto: onto, in: order) {
            for move in moves(from: order, to: want) {
                guard let moved = tabs.first(where: { $0.id == move.id })?.controller else { continue }
                VerticalTabsActions.reorder(moved, to: move.to)
            }
        } else {
            VerticalTabsActions.reorder(controller, to: index)
        }
        // The new order is handed to the rows here, by hand, so that it reaches them in the
        // same turn the drag is ended in. The notification below is debounced, and a frame
        // between the drag ending and the row moving is exactly the second move that this is
        // meant to avoid. It is still posted for the other windows sharing the tab group, whose
        // sidebars have models of their own.
        model.refresh()
        VerticalTabs.setNeedsRefresh()
    }

    /// Puts the dragged tab in a workspace by hand, without the workspace it came from coming
    /// along, and moves it to the place the drop named. The tab stays there whatever folder it
    /// is in; its row's menu puts it back. See `VerticalTabsWorkspaces.assign`.
    private func fileDraggedTab(_ id: ObjectIdentifier, in workspace: String, at index: Int) {
        defer { drag.end() }
        guard let controller = model.tabs.first(where: { $0.id == id })?.controller else { return }
        VerticalTabsWorkspaces.shared.assign(controller, to: workspace)
        VerticalTabsActions.reorder(controller, to: index)
        model.refresh()
        VerticalTabs.setNeedsRefresh()
    }

    /// A drop on a workspace's header: its name, the controls beside it, and the status line
    /// under it — everything the header view covers. This is the one place a workspace can be
    /// named; the rest of the block is the space around it, which names none and so lets a tab
    /// out rather than taking one in.
    ///
    /// A tab drawn in another workspace brings that workspace with it, which is the one thing a
    /// drop here can name, and the two become one under this workspace's name. A tab drawn in
    /// this one is moving within it and moves as it always has. One drawn on its own belongs to
    /// no workspace, so it has nothing to bring and joins this one by itself.
    private func dropOnBlock(_ id: ObjectIdentifier, onto workspace: String, at index: Int) {
        guard let controller = model.tabs.first(where: { $0.id == id })?.controller else {
            drag.end()
            return
        }
        let workspaces = VerticalTabsWorkspaces.shared
        let from = workspaces.section(for: controller)?.id
        guard from != workspace, from != nil else {
            moveDraggedTab(id, at: index)
            return
        }
        guard from != VerticalTabsWorkspaces.otherID,
              workspaces.mergeWorkspace(of: controller, into: workspace) else {
            fileDraggedTab(id, in: workspace, at: index)
            return
        }
        defer { drag.end() }
        VerticalTabsActions.reorder(controller, to: index)
        model.refresh()
        VerticalTabs.setNeedsRefresh()
    }

    /// A drop on a row inside a workspace. A tab that is already drawn in that workspace is
    /// moving within it, and moves as it always has; one drawn anywhere else — in another
    /// workspace, or on its own outside every one — joins this workspace by itself, leaving
    /// whatever it came from where it is.
    private func dropInSection(_ id: ObjectIdentifier, onto workspace: String, at index: Int) {
        guard let controller = model.tabs.first(where: { $0.id == id })?.controller,
              workspaces.section(for: controller)?.id != workspace else {
            moveDraggedTab(id, at: index)
            return
        }
        fileDraggedTab(id, in: workspace, at: index)
    }

    /// Takes the dragged tab out of its workspace and puts it where it was dropped, drawn on
    /// its own rather than gathered back in among the workspace's other tabs.
    ///
    /// This is what a drop in the space around a block means, and it has to be said out loud
    /// rather than left to where the tab lands: a workspace's tabs are drawn gathered together
    /// at the earliest place one of them holds, so a tab put down anywhere near its own is
    /// drawn as one of them again. Pulling it out is a thing the drop does, not a place it
    /// lands on.
    ///
    /// A tab that belongs to no workspace is left where the sidebar already draws it: **Other**
    /// is the one place such a tab has, and pulling it out of there would only carry it up
    /// among the workspaces, which says nothing true about it.
    private func pullDraggedTab(_ id: ObjectIdentifier, at index: Int) {
        if let controller = model.tabs.first(where: { $0.id == id })?.controller,
           workspaces.section(for: controller)?.id != VerticalTabsWorkspaces.otherID {
            workspaces.detach(controller)
        }
        moveDraggedTab(id, at: index)
    }

    /// The tabs to move, and where, to leave the tab order as `want` reads: the tabs already
    /// in place stay where they are, and each move is one tab to one place.
    private func moves(from current: [ObjectIdentifier],
                       to want: [ObjectIdentifier]) -> [(id: ObjectIdentifier, to: Int)] {
        var order = current
        var result: [(id: ObjectIdentifier, to: Int)] = []
        for position in want.indices where order[safe: position] != want[position] {
            guard let from = order.firstIndex(of: want[position]) else { continue }
            result.append((want[position], position))
            // Keep step with the move about to be made, so the next one is read off the
            // order the tab group is in by then.
            order.remove(at: from)
            order.insert(want[position], at: position)
        }
        return result
    }

    /// The terminal's own background, a shade deeper.
    private var sidebarBackground: some View {
        ZStack {
            config.backgroundColor.opacity(config.backgroundOpacity)
            Color.black.opacity(0.28)
        }
    }

    /// The sigil and wordmark, then the tools.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                LivingSigil(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("GHOSTTY·EXTREME")
                        .font(Extreme.font(11.5))
                        .kerning(2.2)
                        .foregroundColor(Extreme.gold)
                        .extremeGlint()
                    Text("Α Ι · ΣΥΣΤΗΜΑ")
                        .font(Extreme.font(9))
                        .kerning(2.4)
                        .foregroundColor(Extreme.dim)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                NewSessionMenu(owner: owner, compact: true)
                Spacer(minLength: 0)
                if settings.isOn(.editor) { EditorHeaderButton(owner: owner) }
                ExtremeIconButton(icon: condensed ? .expand : .condense,
                                  help: condensed ? "Expand view" : "Condense view") { condensed.toggle() }
                if settings.isOn(.localhost) { LocalhostHeaderButton() }
                if settings.isOn(.review) { ReviewHeaderButton() }
                if settings.isOn(.activity) {
                    ExtremeIconButton(icon: .chart, help: "Agent activity and usage graphs (⌃⌘A)", action: ActivityDashboard.toggle)
                }
                if settings.isOn(.missionControl) { MissionControlButton() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

/// The row being dragged in the sidebar, and where it would land.
///
/// Shared, not per-window state: only one row can be under the mouse at a time. See
/// `VerticalTabsSidebar.drag` for why the sidebar does not hold this itself.
final class VerticalTabDragState: ObservableObject {
    static let shared = VerticalTabDragState()

    /// GhosttyEXTREME's own pasteboard type for a dragged row, so a row dropped on the
    /// terminal or the editor isn't taken as text to type. Built once: every row's body
    /// names it when it registers its drop target.
    static let pasteboardType = UTType("com.steventsvik.ghostty-extreme.sidebar-tab") ?? .data

    /// The sidebar the drag started in.
    @Published private(set) var owner: ObjectIdentifier?
    /// The tab being carried.
    @Published private(set) var dragging: ObjectIdentifier?
    /// The row the drag is over, by place in the tab order (0-based).
    @Published private(set) var target: Int?
    /// Whether the tab lands after that row rather than before it.
    @Published private(set) var after = false
    /// The project whose block the drag is over, when it is over a block and not one of the
    /// rows inside it. A drop there puts the tab at the top of that project's tabs, and the
    /// block draws the line at its top edge where the tab would go.
    @Published private(set) var block: String?

    /// Where the dragged tab sits in the tab order. Every drop update needs it, so it is
    /// remembered here rather than searched for each time.
    private(set) var origin: Int?

    func begin(_ id: ObjectIdentifier, in owner: ObjectIdentifier, at index: Int) {
        self.owner = owner
        dragging = id
        origin = index
        target = nil
        after = false
        block = nil
    }

    func hover(_ index: Int, after: Bool) {
        guard target != index || self.after != after || block != nil else { return }
        target = index
        self.after = after
        block = nil
    }

    /// The drag is over a project's block rather than one of the rows in it, which no row
    /// can report: nothing there says where the tab would land but the top of the block.
    func hover(block: String) {
        guard target != nil || self.block != block else { return }
        target = nil
        after = false
        self.block = block
    }

    func clearHover() {
        guard target != nil || block != nil else { return }
        target = nil
        after = false
        block = nil
    }

    func end() {
        owner = nil
        dragging = nil
        origin = nil
        target = nil
        after = false
        block = nil
    }

    /// The drop has been taken: the row is no longer lifted, but the gold line stays where it
    /// is until the tab has moved to it, which is what `moveDraggedTab` ends the drag for. The
    /// line going out here, a turn before the row arrives under it, reads as the drop having
    /// missed.
    func land() {
        dragging = nil
        origin = nil
    }

    /// A drag that ends anywhere but on another row — dropped on the terminal, or cancelled
    /// with Escape — reports nothing, so the row would stay dimmed. The mouse button coming
    /// up ends the drag whatever became of it, so that clears it.
    ///
    /// The drag session keeps the mouse-up to itself, so the button has to be asked for rather
    /// than listened for, and asked often: at a fifth of a second the row was still seen
    /// waiting after the drag had gone. A drag is short and the question is one read of the
    /// hardware's state, so asking twenty times a second costs nothing after it.
    func watchForEnd() {
        guard dragging != nil else { return }
        guard NSEvent.pressedMouseButtons == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.watchForEnd()
            }
            return
        }
        end()
    }
}

/// Scrolls the sessions list while a row is dragged near either end of it.
///
/// macOS scrolls for its own drags by asking whatever the drag is over to autoscroll, and
/// SwiftUI's drop targets don't answer, so a tab can't be carried past the end of a long list
/// here. This does the same job by hand: the strip at each end scrolls the list at a speed that
/// grows with how far into the strip the pointer is, and the timer behind it runs only while a
/// drag is in flight, so nothing is running while nothing is being dragged.
///
/// What it does not do is move the line. The list slides under a pointer that is holding still,
/// and a row only reports that the drag is over it when the pointer moves again; dragging to
/// the end of a list is done with the hand moving, which is what the line answers.
final class VerticalTabAutoScroll: ObservableObject {
    /// The list's scroll view, found by the view placed inside it (see `SidebarScrollFinder`).
    weak var scrollView: NSScrollView?

    /// The sidebar this scrolls for: a drag in another window's sidebar is nowhere near this
    /// list, and the pointer would be read as being off the end of it.
    private let owner: ObjectIdentifier

    /// The strip at each end of the list that scrolls it, and the slowest and fastest a tick
    /// moves it. A tick is a sixtieth of a second, so the slowest is a crawl and the fastest
    /// crosses the list in about a second and a half: fast enough to reach the end of a long
    /// list with the pointer held at the edge, slow enough to let go of the row you are aiming
    /// at as it goes past.
    private static let strip: CGFloat = 46
    private static let minStep: CGFloat = 1.25
    private static let maxStep: CGFloat = 10

    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(owner: ObjectIdentifier) {
        self.owner = owner
        // The drag state is the only thing that says a row is in the air, and it says so at the
        // start and the end of a drag rather than on every mouse move. The main queue and not
        // the run loop: a drag runs in a nested loop that a run-loop scheduler isn't promised
        // to reach, and the drag is what starts this.
        VerticalTabDragState.shared.$dragging
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dragging in
                guard let self, VerticalTabDragState.shared.owner == self.owner else { return }
                if dragging == nil { self.stop() } else { self.start() }
            }
            .store(in: &cancellables)
    }

    deinit { timer?.invalidate() }

    private func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        // The common modes, so that it keeps firing while the drag holds the run loop in event
        // tracking, which is the whole time it is wanted for.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let scrollView, let document = scrollView.documentView,
              let window = scrollView.window else { return }
        let clip = scrollView.contentView
        // The content is taller than the list, so there is something to scroll.
        let room = document.frame.height - clip.bounds.height
        guard room > 0 else { return }

        // How far the list is scrolled from the top of the content, and where the pointer is
        // against the top and the bottom of the list. SwiftUI's own views are flipped, so this
        // is the coordinate they are drawn in; anything else is read the other way up rather
        // than scrolled backwards.
        let flipped = document.isFlipped
        let fromTop = flipped ? clip.bounds.origin.y : room - clip.bounds.origin.y
        let point = clip.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let againstTop = flipped ? point.y : clip.bounds.height - point.y
        let againstBottom = clip.bounds.height - againstTop

        let step: CGFloat
        if againstTop < Self.strip {
            step = -Self.speed(into: againstTop)
        } else if againstBottom < Self.strip {
            step = Self.speed(into: againstBottom)
        } else {
            return
        }

        let wanted = min(max(fromTop + step, 0), room)
        guard wanted != fromTop else { return }
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: flipped ? wanted : room - wanted))
        scrollView.reflectScrolledClipView(clip)
    }

    /// How fast to scroll with the pointer `distance` points inside one of the strips.
    private static func speed(into distance: CGFloat) -> CGFloat {
        let depth = min(max((strip - distance) / strip, 0), 1)
        return minStep + (maxStep - minStep) * depth
    }
}

/// Hands back the scroll view the sessions list is drawn in, which is what a drag near either
/// end of the list has to scroll. It goes inside the list, because a view knows its own.
private struct SidebarScrollFinder: NSViewRepresentable {
    let found: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // The scroll view isn't in place on the first pass and the list can be handed about
        // between passes, so this is asked again every time the list is laid out.
        DispatchQueue.main.async { found(view.enclosingScrollView) }
    }
}

/// Half the gap between two rows of the sessions list.
///
/// The list itself has no spacing: each row carries its share of the gap in its own padding,
/// so that no strip of the list belongs to no row. A pointer in a gap left the drop target on
/// whichever row it had last been over, and the tab then landed a row away from where the gold
/// line said it would.
private let rowGutter: CGFloat = 3

/// One draggable row: the tab's card, plus the drag image, the lifted look, and the gold line
/// showing where the tab would land.
private struct VerticalTabDragRow<Content: View>: View {
    @ObservedObject var drag: VerticalTabDragState
    /// The sidebar this row belongs to; see `VerticalTabDragState.owner`.
    let owner: ObjectIdentifier
    /// The row's place in the tab order (0-based).
    let index: Int
    let id: ObjectIdentifier
    /// Called with the tab and the place it was dropped on.
    let drop: (ObjectIdentifier, Int) -> Void
    /// Built by the sidebar and passed as a value: re-rendering this wrapper for a change in
    /// the drag must not rebuild the tab's panes.
    let content: Content

    private var mine: Bool { drag.owner == owner }
    private var isDragged: Bool { mine && drag.dragging == id }
    private var isTarget: Bool { mine && drag.target == index && !isDragged }
    private var landsAbove: Bool { isTarget && !drag.after }
    private var landsBelow: Bool { isTarget && drag.after }

    init(drag: VerticalTabDragState, owner: ObjectIdentifier, index: Int, id: ObjectIdentifier,
         drop: @escaping (ObjectIdentifier, Int) -> Void,
         @ViewBuilder content: () -> Content) {
        self.drag = drag
        self.owner = owner
        self.index = index
        self.id = id
        self.drop = drop
        self.content = content()
    }

    var body: some View {
        // Nothing here moves for a drag. The place the tab will land is told by the gold line
        // and nothing else, and the row keeps the room it had, so the list is still while a
        // row is carried across it.
        //
        // The row used to open a slot — an extra 16 points of padding on the landing side —
        // and the list had to be laid out again for it on nearly every mouse move. What the
        // rows sit in pays for that: a workspace's block, its header and the bracket down its
        // side are all drawn around them, so a slot opening anywhere inside a workspace grew
        // the block, moved its name, and put everything below it 16 points further down, and
        // closing it put them all back. Crossing from a row to the header and back did it
        // again, several times a second, which is what made the sidebar jump.
        content
            .padding(.vertical, rowGutter)
            .overlay(alignment: .top) { line.opacity(landsAbove ? 1 : 0) }
            .overlay(alignment: .bottom) { line.opacity(landsBelow ? 1 : 0) }
            .opacity(isDragged ? 0.45 : 1)
            .scaleEffect(isDragged ? 0.98 : 1)
            // Each of these names something only this row does, so a drag over another row
            // leaves this one out of it. With the drag's own `target` as the value instead,
            // every row in the list has its animation read again on every mouse move that
            // changes it, which is most of them.
            .animation(.easeOut(duration: 0.1), value: landsAbove)
            .animation(.easeOut(duration: 0.1), value: landsBelow)
            .animation(.easeOut(duration: 0.12), value: isDragged)
            .onDrag {
                drag.begin(id, in: owner, at: index)
                drag.watchForEnd()
                return NSItemProvider(item: Data() as NSData,
                                      typeIdentifier: VerticalTabDragState.pasteboardType.identifier)
            }
            .onDrop(of: [VerticalTabDragState.pasteboardType],
                    delegate: VerticalTabDropDelegate(drag: drag, owner: owner, index: index, drop: drop))
    }

    /// The gold line across the edge the tab will land on. It sits in the gutter the two rows
    /// share rather than in room made for it, so it falls exactly where the tab goes.
    private var line: some View {
        VerticalTabDropLine()
    }
}

/// The gold line marking where the dragged tab would land.
private struct VerticalTabDropLine: View {
    var body: some View {
        Capsule()
            .fill(Extreme.gold)
            .frame(height: 2)
            .padding(.horizontal, 8)
            .allowsHitTesting(false)
    }
}

/// The line at the top of a project's block, while a tab is dragged over the block itself:
/// the header, the status line, or the whole of it while it's folded.
private struct VerticalTabBlockLine: View {
    @ObservedObject var drag: VerticalTabDragState
    /// The sidebar this block belongs to. Every window showing the same project draws the
    /// same block, and only the sidebar the drag started in should mark it.
    let owner: ObjectIdentifier
    /// The project whose block this is.
    let block: String

    var body: some View {
        if drag.owner == owner, drag.block == block { VerticalTabDropLine() }
    }
}

/// Reorders tabs when a row is dragged onto another row. The tab takes the dropped-on row's
/// place and lands on the side the drag came from, which is the side the gold line is drawn on.
private struct VerticalTabDropDelegate: DropDelegate {
    let drag: VerticalTabDragState
    let owner: ObjectIdentifier
    /// The row's place in the tab order (0-based).
    let index: Int
    let drop: (ObjectIdentifier, Int) -> Void

    /// Whether this row is a candidate for the drag in flight.
    private var source: Int? { drag.owner == owner ? drag.origin : nil }

    /// Every row of the sidebar the drag started in takes the drop, the one it started on
    /// included. Refusing a drop is what makes macOS bounce the drag image back to where it
    /// came from, and picking a row up only to put it straight back is the commonest thing
    /// you do with one — it should settle, not fly home.
    func validateDrop(info: DropInfo) -> Bool { source != nil }

    func dropEntered(info: DropInfo) { update() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update()
        return DropProposal(operation: .move)
    }

    // There is no dropExited: the target is left where it was so the line keeps pointing at
    // the place the tab would land while the pointer crosses the gap between two rows.

    func performDrop(info: DropInfo) -> Bool {
        guard let id = drag.dragging, let from = source else { drag.end(); return false }
        guard from != index else { drag.end(); return true }  // put back where it started
        // The drag is ended where the move is made, not here, so the line stays over the place
        // the tab is going until it has actually gone there.
        drag.land()
        // Reordering a tab group makes AppKit re-parent the window's views, which takes long
        // enough to hold up the drag's own teardown if it runs here, inside the drag
        // session's event loop. The row lands now; the window reorders on the next turn.
        DispatchQueue.main.async { drop(id, index) }
        return true
    }

    private func update() {
        guard let from = source else { return }
        guard from != index else {
            drag.clearHover()  // back over the row being dragged: nowhere to land
            return
        }
        drag.hover(index, after: from < index)
    }
}

/// Takes the drops in the list that no row and no block claims — the room below the last row,
/// and the strips beside a row — and puts the tab where the line was pointing, which is the
/// last row the pointer was over. None of this space belongs to a workspace, which is the
/// point of it: it is where a tab is carried to be taken out of the one it was in. Without
/// this those drops have no target and macOS bounces the drag image back instead.
private struct VerticalTabListDropDelegate: DropDelegate {
    let drag: VerticalTabDragState
    let owner: ObjectIdentifier
    let drop: (ObjectIdentifier, Int) -> Void

    private var isOurs: Bool { drag.owner == owner && drag.origin != nil }

    func validateDrop(info: DropInfo) -> Bool { isOurs }

    func performDrop(info: DropInfo) -> Bool {
        guard let id = drag.dragging, let from = drag.origin else { drag.end(); return false }
        guard let to = drag.target, to != from else { drag.end(); return true }  // nowhere to land
        drag.land()  // the line stays over that row until the tab is there: see `VerticalTabDragState`
        DispatchQueue.main.async { drop(id, to) }
        return true
    }
}

/// Takes a drop that lands off the list altogether: above it the tab goes to the front, below
/// it the tab goes last. There is no row to say where the tab should sit, so the whole run of
/// sidebar either side of the list names one end of it, and refusing those drops is what
/// leaves the drag image flying back to where it was picked up.
///
/// Neither end names a workspace, so the sidebar takes the tab out of the one it was in —
/// which here is not a matter of where it lands: the ends of the list are beside a block as
/// often as not, and a tab put down beside its own is drawn as one of them again.
private struct VerticalTabEdgeDropDelegate: DropDelegate {
    let drag: VerticalTabDragState
    let owner: ObjectIdentifier
    /// The end of the tab order this region stands for.
    let toFront: Bool
    /// How many tabs there are; the order itself is only known to the sidebar.
    let count: Int
    let drop: (ObjectIdentifier, Int) -> Void

    private var ours: Bool { drag.owner == owner && drag.origin != nil }

    /// Nowhere to drop when the sidebar has no tabs, which it doesn't while the first is
    /// still opening.
    private var destination: Int? {
        guard count > 0 else { return nil }
        return toFront ? 0 : count - 1
    }

    func validateDrop(info: DropInfo) -> Bool { ours && destination != nil }

    func performDrop(info: DropInfo) -> Bool {
        guard let id = drag.dragging, let from = drag.origin, let to = destination else {
            drag.end()
            return false
        }
        guard to != from else { drag.end(); return true }  // already at that end: nothing to do
        // Nothing here drew the place this drop names, so there is no line left hanging over it.
        drag.end()
        DispatchQueue.main.async { drop(id, to) }
        return true
    }
}

/// Takes a drop that lands on a workspace's block rather than on one of the rows inside it:
/// the strip the block's inset leaves on the left, and the gaps between its rows. The tab goes
/// to the top of that workspace's tabs, which is the one place in the block a drop can name —
/// the block is drawn as one thing, wherever its earliest tab sits in the tab order. What the
/// drop means is the caller's to say: this space names no workspace, and the block's surround
/// is where a tab is carried to leave one.
///
/// The block's header carries one of these of its own, deeper than the block's: a target a
/// whole block carries is not reached over a header. The header's is the target a drop on a
/// workspace's name reaches — the one place a workspace can be named — and the second of the
/// two to be told about a drop finds the drag already over.
struct VerticalTabBlockDropDelegate: DropDelegate {
    let drag: VerticalTabDragState
    let owner: ObjectIdentifier
    /// The workspace whose block this is.
    let block: String
    /// The place in the tab order the workspace's earliest tab holds, which is where the block
    /// is drawn: the drop puts the tab at the top of it.
    let top: Int
    let drop: (ObjectIdentifier, Int) -> Void

    private var ours: Bool { drag.owner == owner && drag.origin != nil }

    func validateDrop(info: DropInfo) -> Bool { ours }

    func dropEntered(info: DropInfo) { drag.hover(block: block) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        drag.hover(block: block)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let id = drag.dragging, let from = drag.origin else { drag.end(); return false }
        // The tab is taken out of the list before it goes back in, so a tab above the block
        // takes the room it leaves with it: the block's top is one place nearer the front by
        // the time the tab lands. The tab being at that place already is a tab already at the
        // top of the block, and one just above it has nowhere nearer to go.
        let to = top - (from < top ? 1 : 0)
        // Where an ordinary move has nowhere to go, the drop is still taken: on a workspace's
        // block it is how one workspace is merged into another, and the tab that sits right
        // above the block — the last of the workspace above it — is the one a user picks up
        // to do that. `moveDraggedTab` sorts out the case where there really is nothing to do.
        drag.land()  // the line at the top of the block stays up while the tab moves there
        DispatchQueue.main.async { drop(id, to) }
        return true
    }
}

/// A small action icon in the row's hover chip, lit on hover.
private struct ChipIcon: View {
    let icon: PixelIcon
    @State private var hovering = false

    var body: some View {
        PixelIconView(icon: icon, color: hovering ? Extreme.gold : Extreme.muted, pixel: 1.1)
            .frame(width: 24, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? Extreme.raised : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// The pane's "Review N" chip when its agent's work is waiting, otherwise `diff`. Watches the
/// inbox itself, so the chip appears the moment a review is ready.
private struct ReviewOrDiffChip<Diff: View>: View {
    let surface: Ghostty.SurfaceView?
    @ViewBuilder let diff: () -> Diff
    @ObservedObject private var inbox = ReviewInbox.shared

    var body: some View {
        if let surface, inbox.item(for: surface)?.stage == .ready {
            ReviewPaneChip(surface: surface)
        } else {
            diff()
        }
    }
}

/// Opens this tab's code editor; while it's open, the same button closes it.
private struct EditorHeaderButton: View {
    let owner: TerminalController
    @ObservedObject private var panel = EditorPanel.shared

    var body: some View {
        let open = panel.isVisible(owner)
        ExtremeIconButton(icon: open ? .close : .code,
                          help: open ? "Close the code editor (⌃⌘E)" : "Open the code editor: watch the agent live (⌃⌘E)",
                          active: open) {
            panel.toggle(from: owner)
        }
        .disabled(HermesSessions.shared.isHermes(owner))
    }
}

/// Opens Mission Control (⌃⌘M); a dot shows when an agent is waiting.
private struct MissionControlButton: View {
    var body: some View {
        ExtremeIconButton(icon: .grid, help: "Mission Control (⌃⌘M)", action: MissionControl.toggle)
    }
}

// MARK: - Icon with status

/// A pane's icon: the agent's logo on its brand-colored circle (or a neutral terminal
/// circle), with a status badge cut into the bottom-right corner. Proportions follow
/// Warp's `render_icon_with_status` (circle 76%, glyph 43%, badge 57% of the box).
struct VerticalTabAvatar: View {
    let agent: VerticalTabAgentKind?
    var mood: AgentMood = .idle
    let badge: VerticalTabBadge
    let palette: VerticalTabsPalette
    /// Extra highlight on the row behind the avatar, so the badge ring matches it.
    var rowHighlight: Double = 0
    var size: CGFloat = 22

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MoodSprite(kind: agent, mood: mood, pixel: size >= 22 ? 2 : 1.5)
                .frame(width: size, height: size)
                .background(Extreme.ink.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.line, lineWidth: 1))
            switch badge {
            case .none:
                EmptyView()
            case .working:
                PixelSpinner(color: Extreme.core, pixel: size >= 22 ? 3 : 2.5)
                    .padding(2)
                    .background(Extreme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.core.opacity(0.4), lineWidth: 1))
                    .offset(x: 6, y: 6)
            default:
                // Waiting on you blinks fast; finished or failed stays lit.
                let urgent = badge == .permission || badge == .input || badge == .bell
                PixelDot(color: badge.color(palette), blinking: urgent, size: size >= 22 ? 7 : 5,
                         interval: urgent ? 0.3 : 0.5)
                    .padding(2)
                    .background(Extreme.ink)
                    .offset(x: 3, y: 3)
            }
        }
        .frame(width: size, height: size)
        .help(badge.helpText)
    }
}

/// An agent's logo in its brand color, or the terminal glyph, for the label line.
private struct VerticalTabKindLabel: View {
    let agent: VerticalTabAgentInfo?
    let palette: VerticalTabsPalette

    var body: some View {
        HStack(spacing: 5) {
            if let agent {
                Text(agent.kind.displayName)
                    .foregroundColor(agent.kind == .claude ? Extreme.claude : Extreme.text.opacity(0.8))
                    .fixedSize()
                if agent.activity != .ready {
                    Text("·").fixedSize()
                    Text(agent.activity.label)
                        .foregroundColor(agent.activity.badge == .none
                            ? Extreme.muted : agent.activity.badge.color(palette))
                        .fixedSize()
                }
                if let detail = agent.detail {
                    Text("·").fixedSize()
                    Text(detail)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
            } else {
                Text("Terminal")
            }
        }
        .font(Extreme.font(10.5))
        .foregroundColor(Extreme.muted)
        .lineLimit(1)
    }
}

// MARK: - Tab group

private struct VerticalTabGroup: View {
    let controller: TerminalController
    let owner: TerminalController
    let index: Int
    let tabColor: TerminalTabColor
    let condensed: Bool
    let collapsed: Bool
    let palette: VerticalTabsPalette
    /// Inside a workspace section, which already provides the side margin.
    var inSection = false
    /// The colour of the workspace this row is drawn in, which the row wears unless it has been
    /// given a colour of its own. Nil outside a section, and for "Other", which owns no folder.
    var sectionColor: Color?
    /// The workspace this tab was dragged out of, if it was: the row's menu then offers to put
    /// it back. See `VerticalTabsWorkspaces.detached`.
    var putBackWorkspace: String?
    /// Where this tab would be drawn if the user hadn't filed it in a workspace by hand. Set
    /// only for a tab that was, so the row's menu can offer to put it back with its folder.
    var moveTo: String?
    /// Whether the tab works in a folder no workspace owns, so its menu can offer to make one
    /// out of it. This is how a workspace comes to exist; nothing else makes one.
    var newWorkspace = false
    let onToggleCollapse: () -> Void

    @State private var snapshot: VerticalTabSnapshot = .empty
    @ObservedObject private var pins = VerticalTabsPins.shared

    private var isSelected: Bool { controller === owner }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                VStack(spacing: condensed ? 2 : 6) {
                    ForEach(snapshot.panes) { pane in
                        VerticalTabPaneRow(
                            pane: pane,
                            controller: controller,
                            tabTitle: snapshot.title,
                            tabColor: tabColor,
                            isSelected: isSelected && pane.isFocused,
                            condensed: condensed,
                            palette: palette)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .extremePanel(active: isSelected, fill: isSelected ? Extreme.panel : Color.clear)
        .overlay(alignment: .leading) { colorCard }
        .padding(.leading, inSection ? 0 : 8)
        .padding(.trailing, 8)
        .onAppear(perform: update)
        .onReceive(VerticalTabsTicker.shared.publisher) {
            // Every tab window carries a sidebar, but only the one on screen needs
            // to stay current; the others refresh when their tab is selected.
            guard owner.window?.occlusionState.contains(.visible) == true else { return }
            update()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if pins.isPinned(controller) {
                PixelIconView(icon: .pin, color: Extreme.bronze, pixel: 1)
            }
            Text(displayTitle)
                .font(Extreme.font(12, weight: .semibold))
                .foregroundColor(isSelected ? Extreme.gold : Extreme.text.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(snapshot.title)
            if snapshot.hasUnseen {
                PixelDot(color: Extreme.live, blinking: true, size: 6)
                    .help("Agent finished while you were away")
            }
            Spacer(minLength: 4)
            if snapshot.panes.count > 1 {
                Text("\(snapshot.panes.count) panes")
                    .font(Extreme.font(10))
                    .foregroundColor(Extreme.dim)
                    .fixedSize()
            }
            if index <= 9 {
                Text("⌘\(index)")
                    .font(Extreme.font(10, weight: .semibold))
                    .foregroundColor(Extreme.dim)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Extreme.raised))
                    .fixedSize()
            }
            Button(action: onToggleCollapse) {
                PixelIconView(icon: collapsed ? .chevronRight : .chevronDown, color: Extreme.muted, pixel: 1.25)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, collapsed ? 8 : 5)
        .contentShape(Rectangle())
        .onTapGesture { select() }
        .contextMenu { contextMenu }
    }

    /// A custom tab title, or else the project folder the tab is in.
    private var displayTitle: String {
        if let override = controller.titleOverride, !override.isEmpty { return override }
        if let pwd = snapshot.representative?.pwd {
            return pwd == NSHomeDirectory() ? "Home" : ProjectPath.displayName(LocalhostProject(folder: pwd).root)
        }
        return Self.cleanTitle(snapshot.title)
    }

    /// The bar down the row's left edge. A tab given a colour keeps it — that is what the
    /// menu's Tab Color is for — and any other tab in a workspace wears the workspace's colour,
    /// so the rows under a section read as that workspace's.
    @ViewBuilder
    private var colorCard: some View {
        if let color = tabColor.displayColor.map({ Color(nsColor: $0) }) ?? sectionColor {
            Rectangle().fill(color).frame(width: 2).padding(.vertical, 1)
        }
    }

    /// Samples the tab and redraws only if something visible changed.
    private func update() {
        let next = VerticalTabSnapshot(controller: controller)
        if next != snapshot { snapshot = next }
    }

    private func select() {
        guard let window = controller.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Agents prefix titles with activity glyphs (e.g. "✳ "); drop them for the header.
    static func cleanTitle(_ title: String) -> String {
        let trimmed = title.drop { !$0.isLetter && !$0.isNumber && $0 != "~" && $0 != "/" }
        let result = String(trimmed).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "Terminal" : result
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let putBackWorkspace {
            Button("Put Back in \(putBackWorkspace)") {
                VerticalTabsWorkspaces.shared.reattach(controller)
            }
            Divider()
        }
        if let moveTo {
            Button("Move to \(moveTo)") {
                VerticalTabsWorkspaces.shared.unassign(controller)
            }
            Divider()
        }
        if newWorkspace {
            Button("New Workspace") {
                VerticalTabsWorkspaces.shared.createWorkspace(for: controller)
            }
            Divider()
        }
        Button("Rename Tab…") {
            select()
            controller.promptTabTitle()
        }
        if let window = controller.window as? TerminalWindow {
            Menu("Tab Color") {
                ForEach(TerminalTabColor.allCases, id: \.self) { color in
                    Button {
                        window.tabColor = color
                    } label: {
                        if tabColor == color {
                            Label(color.localizedName, systemImage: "checkmark")
                        } else {
                            Text(color.localizedName)
                        }
                    }
                }
            }
        }
        Divider()
        Button("Close Tab") { controller.closeTab(nil) }
    }
}

// MARK: - Pane row

private struct VerticalTabPaneRow: View {
    let pane: VerticalTabPaneSnapshot
    let controller: TerminalController
    let tabTitle: String
    let tabColor: TerminalTabColor
    let isSelected: Bool
    let condensed: Bool
    let palette: VerticalTabsPalette

    @ObservedObject private var git = VerticalTabsGit.shared
    @ObservedObject private var pulls = GitHubPulls.shared
    @ObservedObject private var settings = ExtremeSettings.shared
    @State private var trackedPwd: String?
    @State private var hovering = false
    @State private var frame: CGRect = .zero
    @EnvironmentObject private var overlay: VerticalTabsOverlayState

    private var gitInfo: VerticalTabsGitInfo? { git.info(for: pane.pwd) }

    var body: some View {
        Group {
            if condensed { condensedBody } else { expandedBody }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, condensed ? 5 : 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Extreme.raised : (hovering ? Extreme.raised.opacity(0.6) : Color.clear)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Extreme.gold.opacity(0.35) : Color.clear, lineWidth: 1))
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule().fill(Extreme.gold).frame(width: 3).padding(.vertical, 8).offset(x: -1)
                    .shadow(color: Extreme.gold.opacity(0.6), radius: 3)
            }
        }
        .overlay(alignment: .bottom) {
            if pane.badge == .working {
                PixelActivityBar(color: Extreme.core).padding(.horizontal, 10).padding(.bottom, 2)
            } else if pane.badge == .permission || pane.badge == .input {
                Capsule().fill(Extreme.warn).frame(height: 2).padding(.horizontal, 10).padding(.bottom, 2)
                    .shadow(color: Extreme.warn.opacity(0.6), radius: 3)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .overlay(alignment: .topTrailing) {
            if hovering || overlay.menu?.pane.id == pane.id { hoverChip.padding(.top, 4).padding(.trailing, 4) }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { frame = geometry.frame(in: .named(verticalTabsSpace)) }
                    .onChange(of: geometry.frame(in: .named(verticalTabsSpace))) { frame = $0 }
            })
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside {
                overlay.hoverBegan(.init(pane: pane, tabTitle: tabTitle, frame: frame))
            } else {
                overlay.hoverEnded(pane.id)
            }
        }
        .onTapGesture(perform: focus)
        .onReceive(NotificationCenter.default.publisher(for: VerticalTabsTestSupport.showOverlay)) { _ in
            guard isSelected else { return }
            if VerticalTabsTestSupport.overlayMode == "git", let pwd = pane.pwd, let root = git.root(for: pwd) {
                overlay.git = .init(controller: controller, pwd: pwd, root: root,
                                    anchor: CGRect(x: frame.minX + 30, y: frame.minY + 4, width: 0, height: 18))
            } else if VerticalTabsTestSupport.overlayMode == "menu" {
                overlay.menu = .init(
                    controller: controller, pane: pane, tabColor: tabColor,
                    anchor: CGRect(x: frame.maxX - 56, y: frame.minY + 4, width: 26, height: 26))
            } else {
                hovering = true
                overlay.hoverBegan(.init(pane: pane, tabTitle: tabTitle, frame: frame))
            }
        }
        .onAppear {
            trackedPwd = pane.pwd
            git.track(pane.pwd)
        }
        .onDisappear {
            git.untrack(trackedPwd)
            trackedPwd = nil
        }
        .onChange(of: pane.pwd) { newValue in
            git.untrack(trackedPwd)
            trackedPwd = newValue
            git.track(newValue)
        }
    }

    /// Warp's floating ⋮ / × controls shown on the hovered row.
    private var hoverChip: some View {
        HStack(spacing: 0) {
            chipButton(.code, help: "Open this folder in the code editor") {
                overlay.dismissAll()
                EditorPanel.shared.show(from: controller, folder: pane.pwd)
            }
            chipButton(.more, help: "More") {
                overlay.dismissAll()
                overlay.menu = .init(
                    controller: controller,
                    pane: pane,
                    tabColor: tabColor,
                    anchor: CGRect(x: frame.maxX - 56, y: frame.minY + 4, width: 26, height: 26))
            }
            chipButton(.close, help: controller.surfaceTree.count > 1 ? "Close Pane" : "Close Tab") {
                overlay.dismissAll()
                if controller.surfaceTree.count > 1, let surface = pane.surface {
                    controller.closeSurface(surface)
                } else {
                    controller.closeTab(nil)
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Extreme.ink))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Extreme.lineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
    }

    private func chipButton(_ icon: PixelIcon, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ChipIcon(icon: icon)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var avatar: some View {
        VerticalTabAvatar(
            agent: pane.agent?.kind,
            mood: AgentMood(pane.agent),
            badge: pane.badge,
            palette: palette,
            rowHighlight: isSelected ? 0.09 : (hovering ? 0.05 : 0),
            size: condensed ? 18 : 22)
    }

    private var expandedBody: some View {
        HStack(alignment: .top, spacing: 9) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                locationLine
                primaryLine
                HStack(spacing: 6) {
                    VerticalTabKindLabel(agent: pane.agent, palette: palette)
                    Spacer(minLength: 4)
                    // A pending review already counts the changes.
                    ReviewOrDiffChip(surface: pane.surface) { diffChip }
                }
                // Always there for an agent (dimmed while it's ready), so rows don't change
                // height between turns and push the list around.
                if let agent = pane.agent { detailLine(agent).opacity(agent.activity == .ready ? 0.55 : 1) }
                // Answer a permission prompt without switching to the pane.
                if pane.agent?.activity == .needsPermission, let surface = pane.surface,
                   let prompt = AgentPermissions.prompt(on: surface) {
                    AgentPermissionButtons(surface: surface, prompt: prompt, compact: true).padding(.top, 3)
                }
                // A review loop it's in, and messages waiting to be typed into it.
                if let surface = pane.surface { AgentMessagesLine(surface: surface, compact: true) }
            }
        }
    }

    private var condensedBody: some View {
        HStack(spacing: 8) {
            avatar
            primaryLine
            Spacer(minLength: 4)
            diffChip
        }
    }

    /// How long the agent has been at it, and the last thing it did: "2m · Edit: cart.py".
    private func detailLine(_ agent: VerticalTabAgentInfo) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "clock").font(.system(size: 9, weight: .semibold))
            Text(Self.elapsed(since: agent.since))
            if let action = agent.lastAction, !action.isEmpty {
                Text("·")
                Text(action)
                    .font(Extreme.mono(10))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(Extreme.font(10))
        .foregroundColor(Extreme.dim)
        .lineLimit(1)
    }

    static func elapsed(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(max(1, seconds))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    /// "~/project • ⎇ branch"
    private var locationLine: some View {
        HStack(spacing: 5) {
            Text(pane.pwd.map(Self.abbreviate) ?? "~")
                .lineLimit(1)
                .truncationMode(.head)
            if let gitInfo {
                if settings.isOn(.git), let pwd = pane.pwd, let root = git.root(for: pwd) {
                    // Opens the Git panel.
                    Button {
                        overlay.dismissAll()
                        overlay.git = .init(controller: controller, pwd: pwd, root: root,
                                            anchor: CGRect(x: frame.minX + 30, y: frame.minY + 4, width: 0, height: 18))
                    } label: {
                        HStack(spacing: 5) {
                            branchLabel(gitInfo)
                            AheadBehindLabel(info: gitInfo)
                            if let pull = pulls.pull(root: root, branch: gitInfo.branch) {
                                PullRequestBadge(pull: pull)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Branches, stashes, commits and pull request")
                    .onAppear { pulls.fetch(root: root, branch: gitInfo.branch) }
                    .onChange(of: gitInfo.branch) { pulls.fetch(root: root, branch: $0) }
                } else {
                    branchLabel(gitInfo)
                }
            }
        }
        .font(Extreme.font(11.5))
        .foregroundColor(Extreme.text)
    }

    private func branchLabel(_ info: VerticalTabsGitInfo) -> some View {
        HStack(spacing: 5) {
            PixelIconView(icon: .branch, color: Extreme.bronze, pixel: 1)
            Text(info.branch)
                .foregroundColor(Extreme.bronze)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .layoutPriority(1)
    }

    /// What the pane is doing: the agent's task, or the terminal's title/command.
    @ViewBuilder
    private var primaryLine: some View {
        if let agent = pane.agent {
            Text(agent.task ?? VerticalTabGroup.cleanTitle(pane.title))
                .font(Extreme.font(11))
                .foregroundColor(Extreme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(pane.title.isEmpty ? "Terminal" : pane.title)
                .font(Extreme.font(11))
                .foregroundColor(Extreme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var diffChip: some View {
        if let gitInfo, gitInfo.added > 0 || gitInfo.removed > 0 {
            HStack(spacing: 3) {
                if gitInfo.added > 0 { Text("+\(gitInfo.added)").foregroundColor(Extreme.live) }
                if gitInfo.removed > 0 { Text("-\(gitInfo.removed)").foregroundColor(Extreme.danger) }
            }
            .font(Extreme.mono(10.5))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Extreme.ink))
            .overlay(Capsule().strokeBorder(Extreme.line, lineWidth: 1))
            .fixedSize()
        }
    }

    private func focus() {
        guard let window = controller.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        if let surface = pane.surface { Ghostty.moveFocus(to: surface) }
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
#endif
