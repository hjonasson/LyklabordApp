//
//  KeyTouchTrackerTests.swift
//  KeyboardKit
//
//  Lyklaborð fork. Drives the key-grid touch tracker with synthetic
//  touches and a manual clock. The first group pins the regressions that
//  were found on a device in October 2026.
//

import KeyboardKit
import XCTest

final class KeyTouchTrackerTests: XCTestCase {

    private var scheduler: ManualScheduler!
    private var output: RecordingOutput!
    private var tracker: KeyTouchTracker!

    private let a = KeyTouchTracker.Key(
        id: UUID(), hitFrame: CGRect(x: 0, y: 100, width: 40, height: 50),
        calloutFrame: CGRect(x: 0, y: 100, width: 40, height: 50), action: .character("a"))
    private let s = KeyTouchTracker.Key(
        id: UUID(), hitFrame: CGRect(x: 40, y: 100, width: 40, height: 50),
        calloutFrame: CGRect(x: 40, y: 100, width: 40, height: 50), action: .character("s"))
    private let backspace = KeyTouchTracker.Key(
        id: UUID(), hitFrame: CGRect(x: 80, y: 100, width: 40, height: 50),
        calloutFrame: CGRect(x: 80, y: 100, width: 40, height: 50), action: .backspace)
    private let emoji = KeyTouchTracker.Key(
        id: UUID(), hitFrame: CGRect(x: 120, y: 100, width: 40, height: 50),
        calloutFrame: CGRect(x: 120, y: 100, width: 40, height: 50), action: .keyboardType(.emojis))
    private let shift = KeyTouchTracker.Key(
        id: UUID(), hitFrame: CGRect(x: 160, y: 100, width: 40, height: 50),
        calloutFrame: CGRect(x: 160, y: 100, width: 40, height: 50), action: .shift(.lowercased))

    private var allKeys: [KeyTouchTracker.Key] { [a, s, backspace, emoji, shift] }

    override func setUp() {
        scheduler = ManualScheduler()
        output = RecordingOutput()
        tracker = KeyTouchTracker(
            scheduler: scheduler,
            configuration: .init(longPressDelay: 0.4, repeatDelay: 0.5, doubleTapTimeout: 0.2, longPressMaxDragDistance: 50))
        tracker.output = output
        tracker.setKeys(allKeys)
    }

    private func center(_ key: KeyTouchTracker.Key) -> CGPoint {
        CGPoint(x: key.hitFrame.midX, y: key.hitFrame.midY)
    }

    private func tap(_ key: KeyTouchTracker.Key, touch: Int = 1) {
        tracker.touchBegan(touch, at: center(key))
        scheduler.advance(by: 0.05)
        tracker.touchEnded(touch, at: center(key))
    }


    // MARK: - Regressions found on device

    /// 1.3 (25): letters were typed from the hidden grid under the emoji
    /// keyboard.
    func testNoLiveKeysMeansEveryTouchIsAMiss() {
        tracker.setKeys([])
        XCTAssertFalse(tracker.touchBegan(1, at: center(a)))
        tracker.touchEnded(1, at: center(a))
        XCTAssertEqual(output.events, [])
    }

    /// 1.3 (26): the emoji key switches keyboards on press, which hides
    /// the grid under the finger. The press stayed open and its long-press
    /// menu opened over the emoji keyboard.
    func testPressOnAKeyThatStopsBeingLiveIsCancelledAndNeverLongPresses() {
        tracker.touchBegan(1, at: center(emoji))
        tracker.setKeys([])
        scheduler.advance(by: 1)
        tracker.touchEnded(1, at: center(emoji))

        XCTAssertEqual(output.gestures(on: emoji.action), [.press, .end])
        XCTAssertFalse(output.events.contains("openActionCallout keyboardType(emojis)"))
        XCTAssertEqual(output.pressed[emoji.id], false)
        XCTAssertFalse(tracker.hasActivePresses)
    }

    /// October 2026: a timer left over from an earlier tap ended a later
    /// press and closed its long-press menu.
    func testTimersOfAnEarlierTapCannotTouchALaterPress() {
        tap(a)
        scheduler.advance(by: 0.3)
        output.events.removeAll()

        tracker.touchBegan(1, at: center(a))
        scheduler.advance(by: 0.45)
        XCTAssertEqual(output.count("openActionCallout character(a)"), 1)
        scheduler.advance(by: 5)
        XCTAssertEqual(output.count("endCallouts"), 0, "menu must stay open while the finger is down")
        XCTAssertEqual(output.pressed[a.id], true)
    }

    /// One touch belongs to one key.
    func testOverlappingFramesResolveToTheNearestCentre() {
        var wide = s
        wide.hitFrame = CGRect(x: 30, y: 100, width: 50, height: 50)
        tracker.setKeys([a, wide])
        tracker.touchBegan(1, at: CGPoint(x: 35, y: 125))
        XCTAssertEqual(output.gestures(on: a.action), [.press])
        XCTAssertEqual(output.gestures(on: s.action), [])
    }


    // MARK: - Tap

    func testTapPressesShowsPreviewNotesTouchReleasesAndEndsInOrder() {
        tap(a)
        XCTAssertEqual(output.events, [
            "pressed true",
            "press character(a)",
            "showInputCallout character(a)",
            "stopRepeat",
            "pressed false",
            "noteRelease character(a) +0.00 +0.00",
            "commitCalloutSelection",
            "release character(a)",
            "endCallouts",
            "end character(a)",
        ])
    }

    func testReleasePointIsNormalizedWithinTheKey() {
        tracker.touchBegan(1, at: center(a))
        tracker.touchEnded(1, at: CGPoint(x: a.hitFrame.minX + 10, y: a.hitFrame.minY + 37.5))
        XCTAssertTrue(output.events.contains("noteRelease character(a) -0.25 +0.25"))
    }

    func testTouchOutsideEveryKeyDoesNothing() {
        XCTAssertFalse(tracker.touchBegan(1, at: CGPoint(x: 300, y: 10)))
        tracker.touchMoved(1, to: center(a))
        tracker.touchEnded(1, at: center(a))
        XCTAssertEqual(output.events, [])
    }


    // MARK: - Release outside

    func testLiftJustOutsideTheKeyStillReleases() {
        tracker.touchBegan(1, at: center(a))
        tracker.touchEnded(1, at: CGPoint(x: a.hitFrame.midX, y: a.hitFrame.minY - 30))
        XCTAssertEqual(output.gestures(on: a.action), [.press, .release, .end])
    }

    func testLiftFarOutsideTheKeyDoesNotRelease() {
        tracker.touchBegan(1, at: center(a))
        tracker.touchEnded(1, at: CGPoint(x: a.hitFrame.midX, y: a.hitFrame.minY - 80))
        XCTAssertEqual(output.gestures(on: a.action), [.press, .end])
    }

    func testCancelEndsWithoutReleasing() {
        tracker.touchBegan(1, at: center(a))
        tracker.touchCancelled(1)
        XCTAssertEqual(output.gestures(on: a.action), [.press, .end])
        XCTAssertEqual(output.pressed[a.id], false)
        scheduler.advance(by: 2)
        XCTAssertEqual(output.gestures(on: a.action), [.press, .end])
    }


    // MARK: - Long press

    func testLongPressOpensTheMenuAfterTheDelay() {
        tracker.touchBegan(1, at: center(a))
        scheduler.advance(by: 0.39)
        XCTAssertEqual(output.count("openActionCallout character(a)"), 0)
        scheduler.advance(by: 0.02)
        XCTAssertEqual(output.count("openActionCallout character(a)"), 1)
        XCTAssertEqual(output.gestures(on: a.action), [.press, .longPress])
    }

    func testLongPressDoesNotFireAfterAQuickTap() {
        tap(a)
        scheduler.advance(by: 1)
        XCTAssertEqual(output.count("openActionCallout character(a)"), 0)
    }

    func testLongPressDoesNotFireIfTheFingerTravelledTooFar() {
        tracker.touchBegan(1, at: center(a))
        tracker.touchMoved(1, to: CGPoint(x: a.hitFrame.midX + 60, y: a.hitFrame.midY))
        scheduler.advance(by: 1)
        XCTAssertEqual(output.count("openActionCallout character(a)"), 0)
    }

    func testCommittingAMenuItemSuppressesTheKeysOwnRelease() {
        tracker.touchBegan(1, at: center(a))
        scheduler.advance(by: 0.5)
        output.calloutSelectionToCommit = true
        tracker.touchEnded(1, at: center(a))
        XCTAssertEqual(output.gestures(on: a.action), [.press, .longPress, .end])
        XCTAssertEqual(output.count("commitCalloutSelection"), 1)
    }

    func testMovesUpdateTheMenuSelectionAndReportTheDragInKeySpace() {
        tracker.touchBegan(1, at: center(a))
        tracker.touchMoved(1, to: CGPoint(x: a.hitFrame.midX + 12, y: a.hitFrame.midY - 4))
        XCTAssertTrue(output.events.contains("updateCalloutSelection (32.0, 21.0)"))
        XCTAssertTrue(output.events.contains("drag character(a) (20.0, 25.0) -> (32.0, 21.0)"))
    }


    // MARK: - Repeat

    func testHeldKeyStartsRepeatingAfterTheDelayAndStopsOnRelease() {
        tracker.touchBegan(1, at: center(backspace))
        scheduler.advance(by: 0.49)
        XCTAssertNil(output.repeatTick)
        scheduler.advance(by: 0.02)
        XCTAssertNotNil(output.repeatTick)

        output.repeatTick?()
        output.repeatTick?()
        XCTAssertEqual(output.gestures(on: .backspace).filter { $0 == .repeatPress }.count, 2)

        let tick = output.repeatTick
        tracker.touchEnded(1, at: center(backspace))
        XCTAssertEqual(output.count("stopRepeat"), 1)
        tick?()
        XCTAssertEqual(output.gestures(on: .backspace).filter { $0 == .repeatPress }.count, 2,
                       "a tick that arrives after the lift must do nothing")
    }

    func testRepeatDoesNotStartAfterAQuickTap() {
        tap(backspace)
        scheduler.advance(by: 1)
        XCTAssertNil(output.repeatTick)
    }


    // MARK: - Double tap

    func testSecondTapWithinTheTimeoutIsADoubleTap() {
        tap(shift)
        scheduler.advance(by: 0.1)
        tap(shift)
        XCTAssertEqual(output.gestures(on: shift.action),
                       [.press, .release, .end, .press, .doubleTap, .release, .end])
    }

    func testSecondTapAfterTheTimeoutIsNotADoubleTap() {
        tap(shift)
        scheduler.advance(by: 0.3)
        tap(shift)
        XCTAssertFalse(output.gestures(on: shift.action).contains(.doubleTap))
    }

    func testThirdQuickTapStartsOver() {
        tap(shift)
        scheduler.advance(by: 0.05)
        tap(shift)
        scheduler.advance(by: 0.05)
        tap(shift)
        XCTAssertEqual(output.gestures(on: shift.action).filter { $0 == .doubleTap }.count, 1)
    }


    // MARK: - Several fingers

    func testTwoFingersOnTwoKeysAreIndependent() {
        tracker.touchBegan(1, at: center(a))
        tracker.touchBegan(2, at: center(s))
        tracker.touchEnded(2, at: center(s))
        tracker.touchEnded(1, at: center(a))
        XCTAssertEqual(output.gestures(on: a.action), [.press, .release, .end])
        XCTAssertEqual(output.gestures(on: s.action), [.press, .release, .end])
        XCTAssertEqual(
            output.events.filter { $0.hasPrefix("release ") },
            ["release character(s)", "release character(a)"])
    }

    func testSecondFingerOnAHeldKeyIsIgnored() {
        tracker.touchBegan(1, at: center(a))
        tracker.touchBegan(2, at: center(a))
        tracker.touchEnded(2, at: center(a))
        XCTAssertEqual(output.gestures(on: a.action), [.press])
        tracker.touchEnded(1, at: center(a))
        XCTAssertEqual(output.gestures(on: a.action), [.press, .release, .end])
    }


    // MARK: - Keys changing under a held finger

    /// Shift pressed with another finger: the held slot's action changes
    /// and the lift releases what the key says now.
    func testHeldKeyReleasesItsCurrentAction() {
        tracker.touchBegan(1, at: center(a))
        var upper = a
        upper.action = .character("A")
        tracker.setKeys([upper, s])
        tracker.touchEnded(1, at: center(a))
        XCTAssertTrue(output.events.contains("release character(A)"))
        XCTAssertFalse(output.events.contains("release character(a)"))
    }

    func testFramesMovingUnderAHeldFingerKeepThePress() {
        tracker.touchBegan(1, at: center(a))
        var moved = a
        moved.hitFrame = a.hitFrame.offsetBy(dx: 0, dy: 4)
        tracker.setKeys([moved, s])
        tracker.touchEnded(1, at: center(a))
        XCTAssertEqual(output.gestures(on: a.action), [.press, .release, .end])
    }
}


// MARK: - Fakes

private final class ManualScheduler: KeyTouchScheduler {

    private(set) var now: TimeInterval = 1000
    private var pending: [(due: TimeInterval, work: () -> Void)] = []

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        pending.append((now + delay, work))
    }

    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let index = pending.indices
            .filter({ pending[$0].due <= target })
            .min(by: { pending[$0].due < pending[$1].due }) {
            let item = pending.remove(at: index)
            now = max(now, item.due)
            item.work()
        }
        now = target
    }
}

private final class RecordingOutput: KeyTouchOutput {

    var events: [String] = []
    var pressed: [UUID: Bool] = [:]
    var repeatTick: (() -> Void)?
    var calloutSelectionToCommit = false
    private var handled: [(Keyboard.Gesture, KeyboardAction)] = []

    func gestures(on action: KeyboardAction) -> [Keyboard.Gesture] {
        handled.filter { $0.1 == action }.map(\.0)
    }

    func count(_ event: String) -> Int {
        events.filter { $0 == event }.count
    }

    private func name(_ action: KeyboardAction) -> String {
        switch action {
        case .character(let char): "character(\(char))"
        case .keyboardType(let type): "keyboardType(\(type))"
        case .backspace: "backspace"
        case .shift: "shift"
        default: "\(action)"
        }
    }

    private func point(_ point: CGPoint) -> String {
        "(\(Double(point.x)), \(Double(point.y)))"
    }

    func keyTouchSetPressed(_ isPressed: Bool, key: UUID) {
        pressed[key] = isPressed
        events.append("pressed \(isPressed)")
    }

    func keyTouchHandle(_ gesture: Keyboard.Gesture, on action: KeyboardAction) {
        handled.append((gesture, action))
        events.append("\(gesture) \(name(action))")
    }

    func keyTouchHandleDrag(on action: KeyboardAction, from start: CGPoint, to current: CGPoint) {
        events.append("drag \(name(action)) \(point(start)) -> \(point(current))")
    }

    func keyTouchShowInputCallout(for action: KeyboardAction, frame: CGRect) {
        events.append("showInputCallout \(name(action))")
    }

    func keyTouchOpenActionCallout(for action: KeyboardAction, frame: CGRect) {
        events.append("openActionCallout \(name(action))")
    }

    func keyTouchUpdateCalloutSelection(with value: GestureButtonDragValue) {
        events.append("updateCalloutSelection \(point(value.location))")
    }

    func keyTouchCommitCalloutSelection() -> Bool {
        events.append("commitCalloutSelection")
        return calloutSelectionToCommit
    }

    func keyTouchEndCallouts() {
        events.append("endCallouts")
    }

    func keyTouchNoteRelease(action: KeyboardAction, dxNorm: Double, dyNorm: Double) {
        events.append(String(format: "noteRelease \(name(action)) %+.2f %+.2f", dxNorm, dyNorm))
    }

    func keyTouchStartRepeat(_ tick: @escaping () -> Void) {
        repeatTick = tick
        events.append("startRepeat")
    }

    func keyTouchStopRepeat() {
        repeatTick = nil
        events.append("stopRepeat")
    }
}
