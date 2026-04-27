import AppKit

/// Borderless, non-activating floating panel that hosts the HUD content. Must
/// never become key — if it did, the focused text app would lose focus and
/// the injector would have no target.
final class HUDPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
    }

    // Belt-and-suspenders: even if something accidentally calls `makeKey()`,
    // the panel refuses to take key status.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
