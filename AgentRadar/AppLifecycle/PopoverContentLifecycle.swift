import AppKit

/// Keeps the SwiftUI popover hierarchy alive only while the popover is open.
/// A hidden hosting view can continue running repeat-forever animations.
final class PopoverContentLifecycle: NSObject, NSPopoverDelegate {
    let popover: NSPopover
    private let makeContent: () -> NSViewController?

    init(popover: NSPopover, makeContent: @escaping () -> NSViewController?) {
        self.popover = popover
        self.makeContent = makeContent
        super.init()
        popover.delegate = self
    }

    @discardableResult
    func prepareToOpen() -> Bool {
        guard let content = makeContent() else { return false }
        popover.contentViewController = content
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === popover else { return }
        popover.contentViewController = nil
    }
}
