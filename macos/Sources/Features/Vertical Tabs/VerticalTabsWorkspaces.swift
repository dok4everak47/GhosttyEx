#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// The sidebar's top level: named workspaces, each owning the folders it works in, with the
/// tabs that work there gathered inside them.
///
/// A tab belongs to the workspace that owns the folder its agent — or, failing that, its
/// focused pane — is in, and joins it the moment it works there. A workspace itself is made by
/// hand, though, from a tab that works in the folder it should own: nothing is grouped on its
/// own, and a tab whose folder belongs to no workspace is drawn on its own. Tabs with no folder
/// of their own — the home folder, the disk, a Hermes tab — are never made into one, since a
/// workspace is a place to work.
///
/// Which tabs a section holds is worked out across every window's tabs, since one workspace is
/// usually open in more than one; a window's sidebar still only draws its own tab group's tabs.
final class VerticalTabsWorkspaces: ObservableObject {
    static let shared = VerticalTabsWorkspaces()

    /// The id of the implicit section holding the tabs that belong to no workspace.
    static let otherID = "__other__"
    static let otherName = "Other"

    /// UserDefaults key for the sections that are folded shut.
    static let collapsedKey = "VerticalTabsCollapsedWorkspaces"
    /// What that key replaced. Section ids are folder paths, so a folded section mostly keeps
    /// the id it had as a project bracket: the old value is carried over once.
    private static let legacyCollapsedKey = "VerticalTabsCollapsedProjects"

    /// A workspace: a name, and the folders it owns.
    struct Workspace: Codable, Equatable, Identifiable {
        /// The folder it was made from, which is also how it is found: one folder belongs to
        /// one workspace.
        let id: String
        var name: String
        /// The folder as it is spelled on disk, for naming and showing.
        let root: String
        /// The canonical folders this workspace owns. `roots[0]` is the folder it was made
        /// from.
        var roots: [String]
    }

    /// A workspace with the tabs it holds right now, as the sidebar draws it.
    struct Section: Equatable, Identifiable {
        let id: String
        let name: String
        /// The workspace's folder, or nil for the implicit "Other" section.
        let root: String?
        /// Its tabs, in no particular order (the sidebar orders them).
        let members: Set<ObjectIdentifier>
        /// Agent sessions working in it (a tab can hold several, in splits).
        let agents: Int

        var isImplicit: Bool { id == VerticalTabsWorkspaces.otherID }

        /// The workspace's colour, taken from its folder. The section's header and the tabs
        /// inside it are both drawn in it, so a tab carries its workspace's colour. "Other"
        /// owns no folder and so has none.
        ///
        /// The root has already been through `LocalhostProject(folder:)` when the workspace was
        /// seeded, so this colours it without another walk of the file system — it is asked for
        /// once per row the sidebar draws.
        var color: Color? { root.map { LocalhostProject.color(forRoot: $0) } }
    }

    /// The sections to draw, in no particular order: the sidebar places each one where its
    /// earliest tab sits.
    @Published private(set) var sections: [Section] = []
    /// Tabs the user pulled out of their workspace by dragging them away from the workspace's
    /// other tabs. Kept for this app session, like the pinned tabs: the tab is still one of the
    /// workspace's, it just isn't drawn inside it any more.
    @Published private(set) var detached: Set<ObjectIdentifier> = []
    /// Tabs the user filed in a workspace by hand, by dragging them onto it. The folder a tab
    /// is in decides which workspace it belongs to; this overrides that for the one tab, so a
    /// session that works nowhere in particular — a shell sitting in the home folder, say — can
    /// be kept with a workspace all the same. Kept for this app session, like the pinned tabs:
    /// the next launch works the folder out again.
    @Published private(set) var assigned: [ObjectIdentifier: String] = [:]

    /// The folder each open tab works in, as of the last pass, for the tabs that have one. The
    /// sidebar asks this of every row it draws — the row's menu offers to make a workspace out
    /// of a folder no workspace owns — and working a folder out means walking up to a dozen
    /// folders looking for a repository. The pass that worked out the sections has done that
    /// walk already, so its answers are kept here rather than made again per row.
    private var folders: [ObjectIdentifier: (root: String, canonical: String)] = [:]
    /// The workspaces, by id.
    private(set) var workspaces: [String: Workspace] = [:]
    private var tabSection: [ObjectIdentifier: String] = [:]
    /// Canonical root -> workspace id, for membership.
    private var byRoot: [String: String] = [:]
    private var cancellables: Set<AnyCancellable> = []
    /// What was last written, so an unchanged file is not written again.
    private var saved: Data?

    private init() {
        Self.migrateCollapsedKey()
        load()
        pruneCollapsed()

        let center = NotificationCenter.default
        Publishers.Merge4(
            center.publisher(for: VerticalTabsAgents.didChange).map { _ in () },
            center.publisher(for: .verticalTabsNeedRefresh).map { _ in () },
            // A closed tab should leave its section right away, not on the next tick.
            center.publisher(for: NSWindow.willCloseNotification).map { _ in () },
            VerticalTabsTicker.shared.publisher)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in self?.recompute() }
            .store(in: &cancellables)
        DispatchQueue.main.async { [weak self] in self?.recompute() }
    }

    // MARK: - Sections

    /// The section a tab is drawn in, if any.
    func section(for controller: TerminalController) -> Section? {
        guard let id = tabSection[ObjectIdentifier(controller)] else { return nil }
        return sections.first { $0.id == id }
    }

    func isDetached(_ controller: TerminalController) -> Bool {
        detached.contains(ObjectIdentifier(controller))
    }

    func detach(_ controller: TerminalController) {
        let id = ObjectIdentifier(controller)
        guard tabSection[id] != nil, !detached.contains(id) else { return }
        detached.insert(id)
    }

    func reattach(_ controller: TerminalController) {
        let id = ObjectIdentifier(controller)
        guard detached.contains(id) else { return }
        detached.remove(id)
    }

    /// Whether the tab is drawn where the user put it rather than where its folder would.
    func isFiled(_ controller: TerminalController) -> Bool {
        assigned[ObjectIdentifier(controller)] != nil
    }

    /// The workspace a tab's folder belongs to, or nil for one that has no folder of its own
    /// and so would be drawn in the "Other" section.
    func folderWorkspace(for controller: TerminalController) -> Workspace? {
        guard let membership = membership(of: controller) else { return nil }
        return workspaceID(for: membership.canonical).flatMap { workspaces[$0] }
    }

    /// Files a tab in a workspace by hand, which is what dropping a row on a workspace names.
    /// A tab dropped on the workspace its folder already puts it in is an ordinary move, and
    /// one dropped elsewhere leaves the folder behind for as long as the app is running.
    ///
    /// Either way the tab is put back among the workspace's tabs. Dropping a tab on a workspace
    /// is what says it belongs there, and the one thing that has to give way to that is the tab
    /// having been pulled out of it before: left as it was, a tab whose folder puts it in the
    /// workspace would be drawn on its own the moment after it was dropped among them.
    func assign(_ controller: TerminalController, to workspace: String) {
        let id = ObjectIdentifier(controller)
        guard workspaces[workspace] != nil else { return }
        if folderWorkspace(for: controller)?.id == workspace {
            // The folder already puts it here, so a filing by hand has done its job and goes.
            assigned.removeValue(forKey: id)
            detached.remove(id)
        } else {
            // Nothing to do for a tab already filed here and already drawn among its tabs.
            guard assigned[id] != workspace || detached.contains(id) else { return }
            assigned[id] = workspace
            detached.remove(id)
        }
        recompute()
    }

    /// Draws a tab where its folder puts it again.
    func unassign(_ controller: TerminalController) {
        guard assigned.removeValue(forKey: ObjectIdentifier(controller)) != nil else { return }
        recompute()
    }

    /// Whether moving `controller` to `index` takes it out of its workspace.
    ///
    /// The sidebar draws a workspace's tabs together, at the place its earliest tab holds in
    /// the tab order, so a tab parked away from all the others would be gathered straight back
    /// and the drag would look like it had done nothing. A tab that ends up beside at least one
    /// of its workspace's tabs is taken to be staying; one that ends up away from all of them
    /// is taken to be leaving, and the sidebar draws it as an ordinary tab from then on. Put it
    /// back from the tab's menu.
    ///
    /// `order` is the tab order as it stands now, and `index` the place the tab is going to,
    /// both of which the caller reads off the sidebar's own list of tabs.
    func leavesSection(_ controller: TerminalController, movingTo index: Int, in order: [ObjectIdentifier]) -> Bool {
        let id = ObjectIdentifier(controller)
        guard !detached.contains(id), let section = section(for: controller),
              let from = order.firstIndex(of: id) else { return false }
        let mates = section.members.subtracting(detached).subtracting([id])
        guard !mates.isEmpty else { return false }

        // Where the move leaves it: a tab lands on the index it was dropped on, which is what
        // `VerticalTabsActions.move` does with it.
        var moved = order
        moved.remove(at: from)
        moved.insert(id, at: max(0, min(index, moved.count)))
        guard let to = moved.firstIndex(of: id) else { return false }

        let neighbours = [to - 1, to + 1].compactMap { moved.indices.contains($0) ? moved[$0] : nil }
        return !neighbours.contains { mates.contains($0) }
    }

    /// The tab order a drop on one of a workspace's own tabs should leave behind, or nil when
    /// the two tabs are not in one section, leaving the caller an ordinary move to make.
    ///
    /// Because a workspace's tabs are drawn together at the place its earliest tab holds in the
    /// tab order, moving one of them to another one's place can carry the whole section with
    /// it: drag the earliest tab down past the others and the earliest place changes hands, so
    /// the block jumps down there and the tab that held that place is left above it. A tab
    /// dropped on one of its own workspace's tabs is changing places with it inside the section,
    /// then, and never moving in the tab order. The section keeps the room it holds and only
    /// its own tabs change places.
    ///
    /// `order` is the tab order as it stands, and `onto` the tab the row was dropped on. The
    /// dragged tab lands on the side of `onto` the drag came from, as anywhere else in the
    /// list: dropping above a tab puts it before, dropping below puts it after.
    func reorderWithinSection(dragged: ObjectIdentifier, onto: ObjectIdentifier,
                              in order: [ObjectIdentifier]) -> [ObjectIdentifier]? {
        let section = tabSection[dragged]
        let drawn: (ObjectIdentifier) -> Bool = {
            self.tabSection[$0] != nil && self.tabSection[$0] == section && !self.detached.contains($0)
        }
        guard section != nil, drawn(dragged), drawn(onto),
              let top = order.firstIndex(where: drawn),
              let ontoAt = order.firstIndex(of: onto),
              let from = order.firstIndex(of: dragged), from != ontoAt else { return nil }

        // The workspace's tabs as the sidebar draws them, in the tab order.
        var members = order.filter(drawn)
        guard let i = members.firstIndex(of: dragged), let j = members.firstIndex(of: onto) else { return nil }
        members.remove(at: i)
        members.insert(dragged, at: j)

        // Every tab above the section is outside it, so the block keeps the room it holds and
        // the tabs inside it are the only ones that change places.
        var want = order.filter { !drawn($0) }
        want.insert(contentsOf: members, at: min(top, want.count))
        return want
    }

    // MARK: - Workspaces

    /// Tabs that are open. A closed tab's window can linger in the app's window list for a
    /// while after it closes.
    static var openControllers: [TerminalController] {
        TerminalController.all.filter { controller in
            guard let window = controller.window else { return false }
            if window.isVisible || window.isMiniaturized { return true }
            // A background tab isn't "visible", but it's still in its tab group.
            return window.tabGroup?.windows.contains(window) == true
                && window.tabGroup?.windows.contains { $0.isVisible || $0.isMiniaturized } == true
        }
    }

    /// The folder a tab works in and how many agent sessions it has there: where its agent is,
    /// or else its focused pane. Localhost tabs count their server's folder. Nil for a tab with
    /// no folder of its own — the home folder, the disk, a Hermes tab.
    func membership(of controller: TerminalController) -> (root: String, canonical: String, agents: Int)? {
        guard !HermesSessions.shared.isHermes(controller) else { return nil }
        let surfaces = Array(controller.surfaceTree)
        let agentSurfaces = surfaces.filter { surface in
            guard let kind = VerticalTabsAgents.shared.info(for: surface)?.kind else { return false }
            return kind != .hermes
        }
        // A localhost tab's shell is its dev server's, so its own folder is the one that counts.
        let folder = LocalhostSessions.shared.session(for: controller)?.cwd
            ?? (agentSurfaces.first ?? controller.focusedSurface ?? surfaces.first)?.pwd
        guard let pwd = folder, let canonical = projectID(of: pwd) else { return nil }
        let agents = agentSurfaces.filter { $0.pwd.flatMap(projectID(of:)) == canonical }.count
        return (projectRoot(of: pwd), canonical, agents)
    }

    /// The folder a tab works in, as a project: nil for a home folder or the disk, which aren't
    /// projects.
    private func projectID(of folder: String) -> String? {
        let id = ProjectPath.canonical(projectRoot(of: folder))
        let home = Self.home
        guard id != home, id != "/", !home.hasPrefix(id + "/") else { return nil }
        return id
    }

    /// The folder's home, canonicalised once. It is asked for by every tab of every pass, and
    /// the answer never changes.
    private static let home = ProjectPath.canonical(NSHomeDirectory())

    /// The repository root a folder belongs to, which `LocalhostProject` works out by walking
    /// up to a dozen folders looking for one. This is asked for several times per tab — the
    /// tab's own folder, then its agents' — and the pass that asks runs several times a second
    /// while an agent works, so the answer is kept for a few seconds: a folder that becomes a
    /// repository, or stops being one, is picked up soon enough after.
    private var projectRoots: [String: (root: String, at: Date)] = [:]
    private static let projectRootLifetime: TimeInterval = 5

    private func projectRoot(of folder: String) -> String {
        let now = Date()
        if let known = projectRoots[folder], now.timeIntervalSince(known.at) < Self.projectRootLifetime {
            return known.root
        }
        let root = LocalhostProject(folder: folder).root
        // Folders come and go with every `cd`; the answers for the ones gone are not missed.
        if projectRoots.count > 256 { projectRoots.removeAll() }
        projectRoots[folder] = (root, now)
        return root
    }

    /// The workspace that owns a folder, taking the longest match so a folder inside another
    /// one (a checkout inside a parent that is also open) lands in the nearer of the two.
    private func workspaceID(for canonical: String) -> String? {
        var bestRoot = ""
        var best: String?
        for (root, id) in byRoot where canonical == root || canonical.hasPrefix(root + "/") {
            if best == nil || root.count > bestRoot.count {
                bestRoot = root
                best = id
            }
        }
        return best
    }

    /// The workspace that owns `canonical`, made on the spot if no workspace does yet. Only
    /// "New Workspace" calls this: nothing is grouped on its own. Once a workspace is there,
    /// the tabs working in its folder join it without being filed by hand.
    private func create(root: String, canonical: String) -> String {
        if let existing = workspaceID(for: canonical) { return existing }
        workspaces[canonical] = Workspace(id: canonical, name: ProjectPath.displayName(root),
                                          root: root, roots: [canonical])
        byRoot[canonical] = canonical
        return canonical
    }

    /// Whether "New Workspace" would make one: the tab works in a folder no workspace owns.
    /// False for a tab with no folder of its own, since a workspace is a place to work.
    ///
    /// The sidebar asks this for every row it draws, and working the answer out from scratch
    /// means walking up to a repository for the tab — which the pass that drew the sections has
    /// just done for every one of them. So this reads what that pass worked out, rather than
    /// walking the folders again on the way through a redraw.
    func canCreateWorkspace(for controller: TerminalController) -> Bool {
        guard let folder = folders[ObjectIdentifier(controller)] else { return false }
        return workspaceID(for: folder.canonical) == nil
    }

    /// Makes a workspace out of the folder a tab works in and puts the tab in it.
    @discardableResult
    func createWorkspace(for controller: TerminalController) -> String? {
        guard let membership = membership(of: controller) else { return nil }
        let id = create(root: membership.root, canonical: membership.canonical)
        assign(controller, to: id)
        return id
    }

    /// Undoes `create`. The folder goes back to being owned by nobody, so the tabs working in
    /// it are drawn on their own again, and a tab filed in the workspace by hand falls back to
    /// its folder — which is now no workspace at all.
    func delete(_ id: String) {
        guard workspaces.removeValue(forKey: id) != nil else { return }
        // Without this the filing would outlive the workspace: `recompute` skips it while
        // there is nothing to file into, but a workspace made again from the same folder
        // takes the same id, and the tab would turn up in it unbidden.
        for tab in Array(assigned.filter { $0.value == id }.keys) { assigned.removeValue(forKey: tab) }
        Self.forgetCollapsed(id)
        // Before `recompute`, which looks folders up: a root left pointing at a workspace that
        // has gone would put its tabs in no section at all, and no section draws them.
        rebuildRoots()
        recompute()
    }

    /// Renames a workspace. What finds a workspace's tabs is its folders, not its name, so
    /// this changes what the sidebar calls it and nothing else.
    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var workspace = workspaces[id], !trimmed.isEmpty, trimmed != workspace.name else { return }
        workspace.name = trimmed
        workspaces[id] = workspace
        recompute()
    }

    /// What a merge took in, so that it can be given back: the workspace that went, the one
    /// that took it, and the tabs that were filed by hand in the one that went — filing is
    /// what a merge has to re-point, and undoing it has to point them back.
    private struct Merge {
        let taken: Workspace
        let into: String
        let refiled: [ObjectIdentifier]
    }

    /// The last merge, while it is still the last thing that happened. A merge is the one
    /// gesture in the sidebar that takes something away — the workspace it takes in is gone,
    /// its folders belong to another workspace from then on, and nothing offers to make it
    /// again — so the header of the workspace that took it in offers to put it back.
    private var lastMerge: Merge?

    /// The workspace whose header can offer to undo the last merge, if there is one.
    var mergeTarget: String? { lastMerge?.into }

    /// Gives back the workspace a merge took in: it is a workspace again with the folders it
    /// had, and the tabs that were filed in it by hand are filed in it again.
    @discardableResult
    func undoMerge() -> Bool {
        guard let merge = lastMerge, workspaces[merge.into] != nil else {
            lastMerge = nil
            return false
        }
        // The folders it brought go back to it. One the target had before the merge is the
        // target's own and stays — and a target is never left holding none, since it would
        // then own no folder and no tab could belong to it.
        if var target = workspaces[merge.into] {
            let kept = target.roots.filter { !merge.taken.roots.contains($0) }
            if !kept.isEmpty { target.roots = kept }
            workspaces[merge.into] = target
        }
        workspaces[merge.taken.id] = merge.taken
        for tab in merge.refiled { assigned[tab] = merge.taken.id }
        lastMerge = nil
        rebuildRoots()
        recompute()
        return true
    }

    /// Merges the workspace a tab is drawn in into another, which is what dropping the tab on
    /// a workspace's header does. The target keeps its name and takes on the other's folders,
    /// so the tabs working in them are drawn in the target from then on, and the other goes.
    ///
    /// False, with nothing merged, for a tab that is already in the target and for one that
    /// belongs to no workspace at all: there is nothing for it to bring with it.
    @discardableResult
    func mergeWorkspace(of controller: TerminalController, into workspace: String) -> Bool {
        guard let from = tabSection[ObjectIdentifier(controller)], from != Self.otherID,
              from != workspace,
              var target = workspaces[workspace], let source = workspaces[from] else { return false }
        for root in source.roots where !target.roots.contains(root) { target.roots.append(root) }
        workspaces[workspace] = target
        // A tab filed by hand in the workspace that is going belongs to the target now.
        let refiled = Array(assigned.filter { $0.value == from }.keys)
        for tab in refiled { assigned[tab] = workspace }
        workspaces.removeValue(forKey: from)
        // Kept until the next merge or a rename of the target: see `undoMerge`.
        lastMerge = Merge(taken: source, into: workspace, refiled: refiled)
        Self.forgetCollapsed(from)
        // Which folder belongs to which workspace has changed under both of them, and
        // `recompute` reads that lookup as it runs.
        rebuildRoots()
        recompute()
        return true
    }

    /// The canonical folder -> workspace lookup, rebuilt whenever the workspaces change.
    /// Sorted by id, so that two workspaces that claim the same folder — hand-edited into the
    /// file, since nothing in the app makes them — always resolve to the same one of the two.
    private func rebuildRoots() {
        byRoot = [:]
        for workspace in workspaces.values.sorted(by: { $0.id < $1.id }) {
            for root in workspace.roots where byRoot[root] == nil { byRoot[root] = workspace.id }
        }
    }

    private func recompute() {
        // A closed tab's identifier can be handed to a new object, so what is remembered per
        // tab has to be forgotten when the tab goes. What "goes" means here is a controller the
        // app no longer has at all — and not one whose window is merely off screen, which is
        // what `openControllers` says: hiding the app, or leaving a window on another Space,
        // takes its window off screen, and forgetting a tab's pull-out or its filing every time
        // that happened would undo the gesture for no reason at all.
        let live = Set(TerminalController.all.map { ObjectIdentifier($0) })
        if !detached.isSubset(of: live) { detached.formIntersection(live) }
        if assigned.keys.contains(where: { !live.contains($0) }) {
            assigned = assigned.filter { live.contains($0.key) }
        }

        var members: [String: Set<ObjectIdentifier>] = [:]
        var agents: [String: Int] = [:]
        var folders: [ObjectIdentifier: (root: String, canonical: String)] = [:]
        // Read once per pass: it filters every window the app has, and the pass runs several
        // times a second while an agent works.
        let open = Self.openControllers
        for controller in open {
            let id = ObjectIdentifier(controller)
            // A workspace is made by hand — see `create` — so a tab whose folder belongs to
            // none of them is drawn on its own, under "Other", until one is made for it.
            let membership = membership(of: controller)
            if let membership { folders[id] = (membership.root, membership.canonical) }
            let filed = assigned[id].flatMap { workspaces[$0] != nil ? $0 : nil }
            guard let section = filed ?? membership.flatMap({ workspaceID(for: $0.canonical) }) else {
                members[Self.otherID, default: []].insert(id)
                continue
            }
            members[section, default: []].insert(id)
            agents[section, default: 0] += membership?.agents ?? 0
        }

        // Sorted by id so that the list is the same from one pass to the next, and the sidebar
        // is only handed a new one when something really changed.
        var next: [Section] = []
        for workspace in workspaces.values.sorted(by: { $0.id < $1.id }) {
            guard let tabs = members[workspace.id], !tabs.isEmpty else { continue }
            next.append(Section(id: workspace.id, name: workspace.name, root: workspace.root,
                                members: tabs, agents: agents[workspace.id] ?? 0))
        }
        if let other = members[Self.otherID], !other.isEmpty {
            next.append(Section(id: Self.otherID, name: Self.otherName, root: nil,
                                members: other, agents: agents[Self.otherID] ?? 0))
        }

        // Handed over before the guard below, which is only about what is drawn: the rows are
        // asked about their folders whenever they are drawn, whether or not this pass found
        // anything new to draw.
        self.folders = folders

        guard next != sections else { return }
        tabSection = [:]
        for section in next { for tab in section.members { tabSection[tab] = section.id } }
        sections = next
        save()
    }

    // MARK: - Persistence

    /// Where the workspaces are kept.
    private static var fileURL: URL {
        AgentTools.root.appendingPathComponent("workspaces.json")
    }

    private struct Stored: Codable { var workspaces: [Workspace] }

    /// Forgets that a workspace was folded shut. A workspace's id is the folder it was made
    /// from, so a workspace made again from the same folder is made again with the same id —
    /// and would be drawn folded, with its tabs hidden and nothing to say why.
    private static func forgetCollapsed(_ id: String) {
        let defaults = UserDefaults.standard
        guard let list = defaults.string(forKey: collapsedKey) else { return }
        let folded = list.split(separator: "\n")
        guard folded.contains(where: { $0 == id }) else { return }
        defaults.set(folded.filter { $0 != id }.joined(separator: "\n"), forKey: collapsedKey)
    }

    /// The same, for a fold remembered for a workspace that is not here at all — deleted from
    /// the file by hand, or left over from a launch that never came back.
    private func pruneCollapsed() {
        let defaults = UserDefaults.standard
        guard let list = defaults.string(forKey: Self.collapsedKey), !list.isEmpty else { return }
        let live = Set(workspaces.keys).union([Self.otherID])
        defaults.set(list.split(separator: "\n").filter { live.contains(String($0)) }
            .joined(separator: "\n"), forKey: Self.collapsedKey)
    }

    private static func migrateCollapsedKey() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: collapsedKey) == nil,
              let legacy = defaults.string(forKey: legacyCollapsedKey) else { return }
        defaults.set(legacy, forKey: collapsedKey)
    }

    /// The file as it is read: one workspace at a time, so one that will not decode — an entry
    /// written by an older version of the app, or a hand-edited file — takes only itself with
    /// it. Workspaces with no folder at all are left out too: with no root, no tab can ever
    /// belong to one, so it would sit in the file for good with nothing drawn and no way to
    /// select it and delete it.
    private struct Lenient: Decodable {
        var workspaces: [Workspace] = []

        private struct One: Decodable {
            let workspace: Workspace?
            init(from decoder: Decoder) throws { workspace = try? Workspace(from: decoder) }
        }

        private enum CodingKeys: String, CodingKey { case workspaces }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let items = try container.decodeIfPresent([One].self, forKey: .workspaces) ?? []
            workspaces = items.compactMap(\.workspace).filter { !$0.roots.isEmpty }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        guard let stored = try? JSONDecoder().decode(Lenient.self, from: data) else {
            // Nothing is read from it, but the file is not written over either: the workspaces
            // are still in there somewhere, and the next `save()` — which the first change
            // after this reaches — would put the empty list in their place.
            let damaged = Self.fileURL.appendingPathExtension("damaged")
            try? FileManager.default.removeItem(at: damaged)
            try? FileManager.default.copyItem(at: Self.fileURL, to: damaged)
            return
        }
        for workspace in stored.workspaces where workspaces[workspace.id] == nil {
            workspaces[workspace.id] = workspace
            for root in workspace.roots where byRoot[root] == nil { byRoot[root] = workspace.id }
        }
    }

    /// Writes the workspaces out. One that holds no tabs is kept rather than dropped: a
    /// workspace is made by hand, so it goes when the user says so, not when its last tab
    /// closes.
    private func save() {
        rebuildRoots()

        let list = workspaces.values.sorted { $0.id < $1.id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Stored(workspaces: list)), data != saved else { return }
        saved = data
        try? FileManager.default.createDirectory(at: AgentTools.root, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

/// Comparing and naming project folders.
enum ProjectPath {
    /// A folder's path as the file system knows it, for comparing: symlinks resolved
    /// (/tmp is /private/tmp) and case ignored (macOS folders are case-insensitive, and a
    /// shell remembers the path the way it was typed).
    static func canonical(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = realpath(path, &buffer) != nil ? String(cString: buffer) : (path as NSString).standardizingPath
        return resolved.lowercased()
    }

    /// The folder's name as it's spelled on disk.
    static func displayName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.nameKey]).name) ?? url.lastPathComponent
    }
}

// MARK: - Sidebar

/// A workspace in the sidebar: its tabs under a header naming it, down a bracket that carries
/// the workspace's state.
struct VerticalTabsWorkspaceSectionView<Content: View>: View {
    let section: VerticalTabsWorkspaces.Section
    let controllers: [TerminalController]
    let owner: TerminalController
    /// What a drop on this block does — the tab, and the place in the tab order the drop
    /// named. The sidebar owns it, since this view knows the block and nothing about the
    /// workspaces a drop may bring together.
    let block: (ObjectIdentifier, Int) -> Void
    /// The place in the tab order the workspace's first tab holds, counting from 1 the way the
    /// sidebar's own list does, which is where a drop on the block puts the tab.
    let first: Int
    @ViewBuilder let content: () -> Content

    @AppStorage(VerticalTabsWorkspaces.collapsedKey) private var collapsedList = ""
    @State private var summary = WorkspaceSummary()
    @State private var hovering = false
    @ObservedObject private var localhost = LocalhostSessions.shared

    private var collapsed: Bool { collapsedList.split(separator: "\n").contains { $0 == section.id } }
    private var color: Color { section.color ?? Extreme.muted }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !summary.overlaps.isEmpty { overlapWarning }
            if !collapsed {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.leading, 14)
        .padding(.vertical, 6)
        .background(
            LinearGradient(colors: [color.opacity(0.07), color.opacity(0.02)], startPoint: .leading, endPoint: .trailing)
                .padding(.leading, 10))
        .overlay(alignment: .leading) {
            SectionBracket(color: color, state: summary.state)
                .frame(width: 10)
                .padding(.leading, 6)
                .allowsHitTesting(false)
        }
        .onAppear(perform: update)
        .onReceive(VerticalTabsTicker.shared.publisher) {
            guard owner.window?.occlusionState.contains(.visible) == true else { return }
            update()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: collapsed)
        .animation(.easeOut(duration: 0.2), value: summary)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerRow
            statusLine.padding(.leading, 14)
        }
        .padding(.trailing, 10)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .contextMenu {
            if let root = section.root {
                Button("Open \(section.name) in Code Editor") { EditorPanel.shared.show(from: owner, folder: root) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)]) }
                Divider()
                Button("Rename Workspace…", action: promptRename)
                // Offered on the workspace that took another one in, and only while that is
                // still the last thing that happened to it. Merging is the one gesture here
                // that takes a workspace away, and there is nothing else that gives it back:
                // its folders belong to this one from then on, so "New Workspace" is not even
                // offered for them.
                if VerticalTabsWorkspaces.shared.mergeTarget == section.id {
                    Button("Undo Merge", action: { VerticalTabsWorkspaces.shared.undoMerge() })
                }
                Divider()
                // The tabs are not closed, and nothing else about them changes: they go back
                // to being drawn on their own. "New Workspace" can make it again.
                Button("Delete Workspace") { VerticalTabsWorkspaces.shared.delete(section.id) }
                Divider()
            }
            Button(collapsed ? "Show Tabs" : "Fold Tabs", action: toggleCollapse)
        }
        // The header's own drop target, and the one place a workspace can be named: this is
        // where the sidebar hands a drop "this workspace" rather than "this row", which is how
        // one workspace is merged into another.
        //
        // It stands on the header itself, and wraps everything the header carries, because a
        // target a whole block carries is not reached over a header: the drop went past the
        // block's own target to the list's, which knows only how to move a tab in the tab
        // order, so dropping a session on a workspace's name read as a reorder and the two
        // workspaces never came together.
        .onDrop(of: [VerticalTabDragState.pasteboardType],
                delegate: VerticalTabBlockDropDelegate(drag: .shared,
                                                       owner: ObjectIdentifier(owner),
                                                       block: section.id,
                                                       top: max(0, first - 1),
                                                       drop: block))
    }

    /// Asks for a new name for the workspace, with the one it has in the field to edit.
    private func promptRename() {
        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.informativeText = "The folders it holds stay as they are; only the name changes."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = section.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        VerticalTabsWorkspaces.shared.rename(section.id, to: field.stringValue)
    }

    /// The name, then the row's controls. A double-click folds the workspace, but only on the
    /// name: a view that answers a double-click holds a click back while it waits for the
    /// second one, so a button inside it answers late — and a double-click on the port chip
    /// would both open the server and fold the section it is in.
    private var headerRow: some View {
        HStack(spacing: 7) {
            HStack(spacing: 7) {
                Rectangle().fill(color).frame(width: 7, height: 7).shadow(color: color.opacity(0.8), radius: 3)
                Text(section.name)
                    .font(Extreme.font(12.5, weight: .semibold))
                    .foregroundColor(Extreme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if section.agents > 0 {
                    Text(section.agents == 1 ? "1 agent" : "\(section.agents) agents")
                        .font(Extreme.font(10, weight: .semibold))
                        .foregroundColor(color)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(color.opacity(0.5), lineWidth: 1))
                        .fixedSize()
                }
            }
            // The name takes the room the buttons leave, so a double-click anywhere along the
            // header short of them folds the section, as it always has.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: toggleCollapse)
            if let server = projectServer, let url = server.url {
                Button {
                    VisualFixPanel.shared.show(from: owner, url: url)
                } label: {
                    HStack(spacing: 3) {
                        PixelDot(color: Extreme.live, size: 4)
                        Text(verbatim: ":\(url.port ?? 80)").font(Extreme.font(9.5)).foregroundColor(Extreme.gold)
                        PixelIconView(icon: .target, color: Extreme.gold, pixel: 0.9)
                    }
                    .padding(.horizontal, 4).frame(height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.gold.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("\(section.name) is live at localhost:\(url.port ?? 80). Click to fix it visually")
                .fixedSize()
            }
            if hovering, let root = section.root {
                headerButton(.code, help: "Open \(section.name) in the code editor") {
                    EditorPanel.shared.show(from: owner, folder: root)
                }
                .transition(.opacity)
            }
            Button(action: toggleCollapse) {
                PixelIconView(icon: collapsed ? .chevronRight : .chevronDown, color: Extreme.muted, pixel: 1.25)
                    // As wide and as tall as the button beside it, rather than the chevron's
                    // own 14 points, so the fold is as easy to hit as anything else up here.
                    .frame(width: 20, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show the workspace's tabs" : "Fold the workspace's tabs")
        }
    }

    /// "2 working · 1 waiting", with a live marker for each.
    private var statusLine: some View {
        HStack(spacing: 8) {
            if summary.working > 0 {
                HStack(spacing: 4) {
                    PixelSpinner(color: Extreme.core, pixel: 1.5)
                    Text("\(summary.working) working").foregroundColor(Extreme.core)
                }
            }
            if summary.waiting > 0 {
                HStack(spacing: 4) {
                    PixelDot(color: Extreme.warn, blinking: true, size: 4, interval: 0.3)
                    Text("\(summary.waiting) waiting").foregroundColor(Extreme.warn)
                }
            }
            if summary.done > 0 {
                HStack(spacing: 4) {
                    PixelDot(color: Extreme.live, size: 4)
                    Text("\(summary.done) done").foregroundColor(Extreme.live)
                }
            }
            if summary.working + summary.waiting + summary.done == 0, let root = section.root {
                Text((root as NSString).abbreviatingWithTildeInPath).foregroundColor(Extreme.dim).lineLimit(1)
            }
        }
        .font(Extreme.font(9.5))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var overlapWarning: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("!").font(Extreme.font(10)).foregroundColor(Extreme.ink)
                .frame(width: 13, height: 13).background(Extreme.warn)
            Text("Both changed \(summary.overlaps.prefix(3).joined(separator: ", "))"
                 + (summary.overlaps.count > 3 ? " and \(summary.overlaps.count - 3) more" : "")
                 + ". Check they don't conflict.")
                .font(Extreme.font(9.5))
                .foregroundColor(Extreme.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.trailing, 10)
        .help("More than one agent in \(section.name) changed these files. Review before committing.")
        .onTapGesture { ReviewInbox.show() }
    }

    private func headerButton(_ icon: PixelIcon, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PixelIconView(icon: icon, color: Extreme.text.opacity(0.85), pixel: 1.1)
                .frame(width: 20, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.lineStrong, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toggleCollapse() {
        var ids = collapsedList.split(separator: "\n").map(String.init)
        if let index = ids.firstIndex(of: section.id) { ids.remove(at: index) } else { ids.append(section.id) }
        collapsedList = ids.joined(separator: "\n")
    }

    /// The workspace's running server, if one is live.
    private var projectServer: LocalhostSession? {
        guard !section.isImplicit else { return nil }
        return localhost.sessions.last { $0.state == .live && ProjectPath.canonical($0.project.root) == section.id }
    }

    // MARK: State

    private func update() {
        var next = WorkspaceSummary()
        var changedBy: [String: Set<ObjectIdentifier>] = [:]
        // Worked out once: it filters every window the app has, and this runs per block per
        // tick, over every tab in the block.
        let open = Set(VerticalTabsWorkspaces.openControllers.map(ObjectIdentifier.init))
        for controller in controllers where open.contains(ObjectIdentifier(controller)) {
            for surface in controller.surfaceTree {
                guard let info = VerticalTabsAgents.shared.info(for: surface), info.kind != .hermes else { continue }
                switch info.activity {
                case .working: next.working += 1
                case .needsPermission, .needsInput: next.waiting += 1
                case .done: next.done += 1
                default: break
                }
                for file in ReviewInbox.shared.item(for: surface)?.files ?? [] {
                    changedBy[file.path, default: []].insert(ObjectIdentifier(surface))
                }
            }
        }
        next.overlaps = changedBy.filter { $0.value.count > 1 }.map(\.key).sorted()
        if next != summary { summary = next }
    }
}

/// What a workspace's agents are up to.
struct WorkspaceSummary: Equatable {
    enum State: Equatable { case idle, working, waiting }
    var working = 0
    var waiting = 0
    var done = 0
    /// Files more than one of the workspace's agents changed.
    var overlaps: [String] = []

    var state: State { waiting > 0 ? .waiting : working > 0 ? .working : .idle }
}

/// The section's bracket: a line down its left side with corner ticks. A light runs down it
/// while an agent works; its corners blink when one needs you.
private struct SectionBracket: View {
    let color: Color
    let state: WorkspaceSummary.State
    @Environment(\.extremeMotion) private var motion

    var body: some View {
        // Core Animation layers: the falling light and the blink cost the app nothing per frame.
        BracketLights(color: color, state: motion ? state : (state == .working ? .idle : state))
    }
}
#endif
