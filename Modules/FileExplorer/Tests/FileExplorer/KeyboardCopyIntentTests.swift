import Testing
import SwiftUI
import Sync
@testable import FileExplorer

/// Pins the pure chord → copy/move decision behind the Differences table's directional keyboard
/// shortcuts: ⌘→/⌘← copy right/left, adding ⇧ moves, and any chord without ⌘ (or on a non-arrow
/// key) yields nil so the Table's own row navigation is left alone.
@Suite struct KeyboardCopyIntentTests {

    @Test func testCommandRightArrowCopiesToRight() {
        let intent = KeyboardCopyIntent.from(key: .rightArrow, modifiers: [.command])
        #expect(intent?.direction == .copyToRight)
        #expect(intent?.isMove == false)
    }

    @Test func testCommandLeftArrowCopiesToLeft() {
        let intent = KeyboardCopyIntent.from(key: .leftArrow, modifiers: [.command])
        #expect(intent?.direction == .copyToLeft)
        #expect(intent?.isMove == false)
    }

    @Test func testShiftCommandRightArrowMovesToRight() {
        let intent = KeyboardCopyIntent.from(key: .rightArrow, modifiers: [.command, .shift])
        #expect(intent?.direction == .copyToRight)
        #expect(intent?.isMove == true)
    }

    @Test func testShiftCommandLeftArrowMovesToLeft() {
        let intent = KeyboardCopyIntent.from(key: .leftArrow, modifiers: [.command, .shift])
        #expect(intent?.direction == .copyToLeft)
        #expect(intent?.isMove == true)
    }

    @Test func testArrowsWithoutCommandYieldNil() {
        // Bare arrows (and ⇧ alone) must pass through so the Table can navigate rows.
        #expect(KeyboardCopyIntent.from(key: .rightArrow, modifiers: []) == nil)
        #expect(KeyboardCopyIntent.from(key: .leftArrow, modifiers: [.shift]) == nil)
    }

    @Test func testCommandWithNonArrowKeyYieldsNil() {
        #expect(KeyboardCopyIntent.from(key: .upArrow, modifiers: [.command]) == nil)
        #expect(KeyboardCopyIntent.from(key: .downArrow, modifiers: [.command, .shift]) == nil)
        #expect(KeyboardCopyIntent.from(key: "a", modifiers: [.command]) == nil)
    }
}
