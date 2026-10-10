#if os(macOS)
import AppKit
import Combine

/// Tabs pinned to the top of the sidebar (for this app session).
final class VerticalTabsPins: ObservableObject {
    static let shared = VerticalTabsPins()
    @Published private(set) var pinned: Set<ObjectIdentifier> = []

    func isPinned(_ controller: TerminalController) -> Bool {
        pinned.contains(ObjectIdentifier(controller))
    }

    /// Pinning moves the tab up to join the other pinned tabs, like Warp.
    func togglePin(_ controller: TerminalController) {
        let id = ObjectIdentifier(controller)
        if pinned.contains(id) {
            pinned.remove(id)
        } else {
            pinned.insert(id)
            guard let window = controller.window, let group = window.tabGroup else { return }
            let pinnedBefore = group.windows.filter {
                $0 !== window && ($0.windowController as? TerminalController).map(isPinned) == true
            }.count
            VerticalTabsActions.move(controller, to: pinnedBefore)
        }
        VerticalTabs.setNeedsRefresh()
    }
}

/// Tab operations offered by the sidebar's ⋮ menu.
enum VerticalTabsActions {
    static func index(of controller: TerminalController) -> (index: Int, count: Int)? {
        guard let window = controller.window else { return nil }
        let windows = window.tabGroup?.windows ?? [window]
        guard let index = windows.firstIndex(of: window) else { return nil }
        return (index, windows.count)
    }

    /// Moves a tab to a position in its tab group, keeping it selected.
    ///
    /// `selecting` is false when the moved tab is not the one you are looking at, as when a
    /// sidebar row is dropped: making it key only to put the selection back leaves the
    /// selection changed twice, and the window ordering either side of that is the most
    /// expensive part of a reorder.
    static func move(_ controller: TerminalController, to newIndex: Int, selecting: Bool = true) {
        guard let window = controller.window, let group = window.tabGroup,
              let current = group.windows.firstIndex(of: window) else { return }
        let target = max(0, min(newIndex, group.windows.count - 1))
        guard target != current else { return }
        let anchor = group.windows[target]

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        group.removeWindow(window)
        anchor.addTabbedWindowSafely(window, ordered: target < current ? .below : .above)
        NSAnimationContext.endGrouping()

        if selecting { window.makeKeyAndOrderFront(nil) }
        controller.relabelTabs()
    }

    static func moveBy(_ controller: TerminalController, _ delta: Int) {
        guard let position = index(of: controller) else { return }
        move(controller, to: position.index + delta)
    }

    /// Moves a tab to a place in its tab group without switching to it, for dragging a row
    /// in the sidebar. The tab you were on stays selected.
    static func reorder(_ controller: TerminalController, to newIndex: Int) {
        guard let window = controller.window, let group = window.tabGroup,
              let current = group.windows.firstIndex(of: window) else { return }
        let target = max(0, min(newIndex, group.windows.count - 1))
        guard target != current else { return }
        let selected = group.selectedWindow

        move(controller, to: target, selecting: false)

        // Taking a window out of a tab group can move the selection, so put it back — but
        // only if it actually moved, since selecting a window is the slow part.
        if let selected, selected !== window, group.selectedWindow !== selected {
            group.selectedWindow = selected
            selected.makeKey()
        }
    }

    /// Detaches the tab into its own window.
    static func moveToNewWindow(_ controller: TerminalController) {
        guard let window = controller.window, (window.tabGroup?.windows.count ?? 1) > 1 else { return }
        window.moveTabToNewWindow(nil)
        window.makeKeyAndOrderFront(nil)
        VerticalTabs.setNeedsRefresh()
    }

    static func closeOtherTabs(_ controller: TerminalController) {
        select(controller)
        controller.closeOtherTabs(nil)
    }

    static func select(_ controller: TerminalController) {
        guard let window = controller.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
#endif
