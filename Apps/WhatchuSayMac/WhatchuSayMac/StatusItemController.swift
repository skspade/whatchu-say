import AppKit
import Observation

/// Owns the app's `NSStatusItem` and its `NSMenu`. Replaces SwiftUI's
/// `MenuBarExtra`, which has a long catalog of unfixed lifecycle bugs and
/// no public handle to the underlying status item — see
/// `docs/PLAN_NSSTATUSITEM_MIGRATION.md`.
///
/// Lifecycle:
/// - `install()` creates the status item, configures the button, attaches
///   an empty `NSMenu` whose contents are rebuilt on every open via
///   `NSMenuDelegate.menuWillOpen`, and starts an observation loop that
///   keeps the button image/tint in sync with `AppState`.
/// - `uninstall()` reverses everything; safe to call multiple times.
///
/// Recovery: subscribes to `NSWorkspace.didWakeNotification` and
/// `NSApplication.didChangeScreenParametersNotification` and rebuilds the
/// status item from scratch on either. Cheap (sub-ms) and a defensive
/// hedge against the symptom that drove this migration: the menu-bar icon
/// silently disappearing after sleep/wake or display reconfiguration.
@MainActor
final class StatusItemController: NSObject {
    struct Handlers {
        let onSetKey: () -> Void
        let onCopyTranscript: (TranscriptEntry) -> Void
        let onClearTranscripts: () -> Void
        let onCopyErrorEntry: (ErrorLogEntry) -> Void
        let onClearErrorLog: () -> Void
        let onDismissError: () -> Void
        let onOpenPermission: (PermissionDeepLink) -> Void
        let onOpenSettings: () -> Void
    }

    private let state: AppState
    private let recentTranscripts: RecentTranscriptsStore
    private let errorLog: ErrorLogStore
    private let handlers: Handlers
    var meetingsCoordinator: MeetingsCoordinator?

    private var statusItem: NSStatusItem?
    private var workspaceWakeToken: NSObjectProtocol?
    private var screenChangeToken: NSObjectProtocol?

    init(
        state: AppState,
        recentTranscripts: RecentTranscriptsStore,
        errorLog: ErrorLogStore,
        handlers: Handlers
    ) {
        self.state = state
        self.recentTranscripts = recentTranscripts
        self.errorLog = errorLog
        self.handlers = handlers
        super.init()
    }

    // MARK: - Lifecycle

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton(on: item)
        attachMenu(to: item)
        statusItem = item
        registerSystemObservers()
        startStateObservation()
    }

    func uninstall() {
        if let token = workspaceWakeToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            workspaceWakeToken = nil
        }
        if let token = screenChangeToken {
            NotificationCenter.default.removeObserver(token)
            screenChangeToken = nil
        }
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Button configuration

    private func configureButton(on item: NSStatusItem) {
        guard let button = item.button else { return }
        applyButtonAppearance(button)
    }

    /// Re-apply the icon and tint to the status-bar button. Reads
    /// `AppState`, so wrapped in `withObservationTracking` by
    /// `startStateObservation()` to drive updates on every state mutation.
    private func applyButtonAppearance(_ button: NSStatusBarButton) {
        let image = NSImage(
            systemSymbolName: iconName(for: state),
            accessibilityDescription: nil
        )
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = iconTintColor(for: state)
    }

    private func startStateObservation() {
        withObservationTracking { [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            self.applyButtonAppearance(button)
        } onChange: { [weak self] in
            // `onChange` fires once per tracking session, on whatever
            // isolation context performed the mutation. Hop back to
            // MainActor and re-arm: re-reading state inside the next
            // `withObservationTracking` re-establishes the dependency set.
            Task { @MainActor in
                self?.startStateObservation()
            }
        }
    }

    // MARK: - Menu wiring

    private func attachMenu(to item: NSStatusItem) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
    }

    /// Build the full set of menu items for the current state. Exposed at
    /// internal access so unit tests can drive it without a live status
    /// bar. Pure: depends only on injected state and the handlers struct;
    /// no side effects beyond constructing `NSMenuItem`s.
    func makeMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        items.append(makeStatusHeaderItem())
        items.append(.separator())
        if let mc = meetingsCoordinator {
            items.append(contentsOf: makeMeetingSection(mc))
            items.append(.separator())
        }
        items.append(makeSetKeyItem())
        items.append(.separator())
        items.append(contentsOf: makeRecentTranscriptsSection())
        items.append(.separator())
        items.append(contentsOf: makeErrorLogSection())

        if let error = state.lastError {
            items.append(.separator())
            items.append(makeErrorLineItem(error))
            if let permission = state.permissionIssue {
                items.append(makePermissionFixItItem(permission))
            }
            items.append(makeDismissErrorItem())
        }

        items.append(.separator())
        items.append(makeSettingsItem())
        items.append(makeQuitItem())
        return items
    }

    // MARK: - Menu-item factories

    private func makeStatusHeaderItem() -> NSMenuItem {
        let item = NSMenuItem(title: statusLabel(for: state), action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeSetKeyItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: setKeyMenuTitle(for: state),
            action: #selector(handleSetKey),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    private func makeRecentTranscriptsSection() -> [NSMenuItem] {
        var items: [NSMenuItem] = [sectionHeader("Recent Transcripts")]
        let entries = recentTranscripts.entries
        if entries.isEmpty {
            items.append(disabledItem(title: "No recent transcripts"))
            return items
        }
        for entry in RecentTranscriptsMenu.visibleEntries(from: entries) {
            items.append(makeTranscriptItem(entry))
        }
        let overflow = RecentTranscriptsMenu.overflowEntries(from: entries)
        if !overflow.isEmpty {
            items.append(makeTranscriptOverflowItem(overflow))
        }
        items.append(.separator())
        items.append(makeClearTranscriptsItem())
        return items
    }

    private func makeTranscriptItem(_ entry: TranscriptEntry) -> NSMenuItem {
        let title = RecentTranscriptsMenu.label(
            for: entry.text,
            maxLength: RecentTranscriptsMenu.labelMaxLength
        )
        let item = NSMenuItem(
            title: title,
            action: #selector(handleCopyTranscript(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = entry
        item.toolTip = entry.text
        return item
    }

    private func makeTranscriptOverflowItem(_ entries: [TranscriptEntry]) -> NSMenuItem {
        let parent = NSMenuItem(title: "Older…", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Older…")
        submenu.autoenablesItems = false
        for entry in entries {
            submenu.addItem(makeTranscriptItem(entry))
        }
        parent.submenu = submenu
        return parent
    }

    private func makeClearTranscriptsItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Clear Recent Transcripts",
            action: #selector(handleClearTranscripts),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    private func makeErrorLogSection() -> [NSMenuItem] {
        var items: [NSMenuItem] = [sectionHeader("Recent Errors")]
        let entries = errorLog.entries
        if entries.isEmpty {
            items.append(disabledItem(title: "No recent errors"))
            return items
        }
        for entry in ErrorLogMenu.visibleEntries(from: entries) {
            items.append(makeErrorEntryItem(entry))
        }
        let overflow = ErrorLogMenu.overflowEntries(from: entries)
        if !overflow.isEmpty {
            items.append(makeErrorOverflowItem(overflow))
        }
        items.append(.separator())
        items.append(makeClearErrorsItem())
        return items
    }

    private func makeErrorEntryItem(_ entry: ErrorLogEntry) -> NSMenuItem {
        let title = ErrorLogMenu.label(for: entry, maxLength: ErrorLogMenu.labelMaxLength)
        let item = NSMenuItem(
            title: title,
            action: #selector(handleCopyError(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = entry
        item.toolTip = entry.text
        return item
    }

    private func makeErrorOverflowItem(_ entries: [ErrorLogEntry]) -> NSMenuItem {
        let parent = NSMenuItem(title: "Older…", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Older…")
        submenu.autoenablesItems = false
        for entry in entries {
            submenu.addItem(makeErrorEntryItem(entry))
        }
        parent.submenu = submenu
        return parent
    }

    private func makeClearErrorsItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Clear Recent Errors",
            action: #selector(handleClearErrors),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    private func makeErrorLineItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: "Error: \(text)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        let attributed = NSAttributedString(
            string: item.title,
            attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
            ]
        )
        item.attributedTitle = attributed
        return item
    }

    private func makePermissionFixItItem(_ permission: PermissionDeepLink) -> NSMenuItem {
        let item = NSMenuItem(
            title: permission.buttonLabel,
            action: #selector(handleOpenPermission(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = permission
        return item
    }

    private func makeDismissErrorItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Dismiss Error",
            action: #selector(handleDismissError),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    private func makeSettingsItem() -> NSMenuItem {
        // `keyEquivalent: ","` displays ⌘, in the menu (Mac convention for
        // Settings/Preferences). The shortcut fires only while this menu is
        // open — agent apps (`LSUIElement = YES`) have no app menu, so
        // ⌘, isn't bound globally.
        let item = NSMenuItem(
            title: "Settings…",
            action: #selector(handleOpenSettings),
            keyEquivalent: ","
        )
        item.target = self
        return item
    }

    private func makeQuitItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Quit", action: #selector(handleQuit), keyEquivalent: "q")
        item.target = self
        return item
    }

    // MARK: - Meeting section

    private func makeMeetingSection(_ mc: MeetingsCoordinator) -> [NSMenuItem] {
        if mc.isRecording {
            let elapsed = formatElapsed(mc.elapsedSeconds)
            let stop = NSMenuItem(
                title: "Stop recording (\(elapsed))",
                action: #selector(MeetingsCoordinator.stopMeetingMenuAction(_:)),
                keyEquivalent: ""
            )
            stop.target = mc
            return [stop]
        } else {
            let start = NSMenuItem(
                title: "Start meeting recording\u{2026}",
                action: #selector(MeetingsCoordinator.startMeetingMenuAction(_:)),
                keyEquivalent: ""
            )
            start.target = mc
            return [start]
        }
    }

    private func formatElapsed(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Section header / disabled-row helpers

    private func sectionHeader(_ title: String) -> NSMenuItem {
        // `NSMenuItem.sectionHeader(title:)` is the macOS 14+ way to render
        // a non-selectable section heading. Project deploys to 26.3 so this
        // is always available.
        NSMenuItem.sectionHeader(title: title)
    }

    private func disabledItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - @objc actions
    //
    // NSMenuItem requires Objective-C selectors. The menu fires these on
    // the main thread; the class is `@MainActor` so the closures execute
    // in the right isolation context.

    @objc private func handleSetKey() {
        handlers.onSetKey()
    }

    @objc private func handleClearTranscripts() {
        handlers.onClearTranscripts()
    }

    @objc private func handleClearErrors() {
        handlers.onClearErrorLog()
    }

    @objc private func handleDismissError() {
        handlers.onDismissError()
    }

    @objc private func handleCopyTranscript(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? TranscriptEntry else { return }
        handlers.onCopyTranscript(entry)
    }

    @objc private func handleCopyError(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ErrorLogEntry else { return }
        handlers.onCopyErrorEntry(entry)
    }

    @objc private func handleOpenPermission(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? PermissionDeepLink else { return }
        handlers.onOpenPermission(link)
    }

    @objc private func handleOpenSettings() {
        handlers.onOpenSettings()
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - System event recovery

    private func registerSystemObservers() {
        workspaceWakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildStatusItem() }
        }
        screenChangeToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildStatusItem() }
        }
    }

    /// Tear down the existing status item (if any) and create a fresh one.
    /// Triggered on wake / screen-change as a defensive hedge: if the
    /// system has dropped the item for any reason, this restores it
    /// without a relaunch. Cost is a barely-perceptible flicker.
    private func rebuildStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton(on: item)
        attachMenu(to: item)
        statusItem = item
        // Don't re-arm observation here: the existing chain re-arms itself
        // on every change and reads `self.statusItem?.button` each time, so
        // it already picks up the new button. Starting another chain on
        // every wake / screen change made them pile up without bound.
    }
}

extension StatusItemController: NSMenuDelegate {
    /// Rebuild the menu on every open. This is the hook
    /// `MenuBarExtra(.menu)` does not have (FB13683957) — using it here
    /// guarantees the menu always reflects current `AppState`,
    /// `RecentTranscriptsStore`, and `ErrorLogStore` without per-mutation
    /// observation plumbing.
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in makeMenuItems() {
            menu.addItem(item)
        }
    }
}
