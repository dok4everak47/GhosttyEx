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

    /// Settles a dragged tab's pin against where it was dropped: a tab dropped among the
    /// pinned tabs is pinned, and one dropped below them is not. Pinned tabs are held at the
    /// top of the list by nothing but this, which is what lets `togglePin` work out where the
    /// next pinned tab goes by counting them.
    ///
    /// `index` is the place the tab is going to, counted in the tab order without the tab
    /// itself, so the run of pinned tabs is the one the tab is about to join or leave.
    func dragged(_ controller: TerminalController, to index: Int, among tabs: [VerticalTabEntry]) {
        let id = ObjectIdentifier(controller)
        let others = tabs.filter { $0.id != id }
        let run = others.prefix { $0.controller.map { self.isPinned($0) } == true }.count
        let target = max(0, min(index, max(tabs.count - 1, 0)))
        let wanted = target < run
        guard wanted != pinned.contains(id) else { return }
        if wanted { pinned.insert(id) } else { pinned.remove(id) }
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

        // Where the window is on screen, and which tab is showing it.
        //
        // Taking a tab out of a tab group and putting it back can carry a frame with it: the
        // one the window had on its own, which is not where the window is, since a tab that
        // isn't the one on screen is somewhere else (see `newWindow`, which cascades and then
        // widens a window before tabbing it). AppKit gives the group that frame, and the
        // whole window moves. This is the same trouble `windowWillClose` keeps and restores a
        // frame for. Fullscreen windows are left alone: their frame is not theirs to set.
        let frame = group.selectedWindow?.frame
        let shown = group.selectedWindow
        let fullscreen = window.styleMask.contains(.fullScreen)

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        group.removeWindow(window)
        anchor.addTabbedWindowSafely(window, ordered: target < current ? .below : .above)
        if !fullscreen, let frame {
            for tab in [window, shown] where tab != nil && tab?.frame != frame {
                tab?.setFrame(frame, display: true)
            }
        }
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

        // Taking a window out of a tab group moves the selection, and that includes taking
        // out the selected window itself: AppKit picks another tab to be current, and
        // re-adding the window doesn't take it back (see `onMoveTab`, which puts the
        // selection back by hand for the same reason). So put it back here too, whichever
        // tab was dragged — but only when it actually moved, since setting `selectedWindow`
        // is the slow part of a reorder.
        if let selected, group.selectedWindow !== selected {
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
