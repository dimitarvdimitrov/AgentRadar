import AppKit
import XCTest
@testable import AgentRadarPopoverLifecycle

final class PopoverContentLifecycleTests: XCTestCase {
    func testContentExistsOnlyWhilePopoverIsOpen() {
        let popover = NSPopover()
        var creations = 0
        let lifecycle = PopoverContentLifecycle(popover: popover) {
            creations += 1
            return NSViewController()
        }

        XCTAssertTrue(popover.delegate === lifecycle)
        XCTAssertNil(popover.contentViewController)

        XCTAssertTrue(lifecycle.prepareToOpen())
        XCTAssertNotNil(popover.contentViewController)
        XCTAssertEqual(creations, 1)

        lifecycle.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: popover))
        XCTAssertNil(popover.contentViewController)

        XCTAssertTrue(lifecycle.prepareToOpen())
        XCTAssertNotNil(popover.contentViewController)
        XCTAssertEqual(creations, 2)
    }

    func testUnavailableContentDoesNotOpenPopover() {
        let popover = NSPopover()
        let lifecycle = PopoverContentLifecycle(popover: popover) { nil }

        XCTAssertFalse(lifecycle.prepareToOpen())
        XCTAssertNil(popover.contentViewController)
    }
}
