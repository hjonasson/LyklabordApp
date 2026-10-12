//
//  KeyTouchTracker.swift
//  KeyboardKit
//
//  Lyklaborð fork. The one authority for touches on the key grid: given
//  the keys that are live right now and a stream of raw touches, it decides
//  press, release, long press, repeat, double tap, drag and cancel.
//
//  It replaces the per-key SwiftUI gesture state machine for the main grid
//  (`GestureButton` still serves the emoji keyboard, the suggestion bar and
//  the input callout). Before it, a frame table sat beside SwiftUI's own
//  hit-testing and every disagreement between the two was a bug found on a
//  device: letters typed under the emoji keyboard, a touch delivered to a
//  key and the suggestion bar at once, a press left open when its key was
//  hidden under the finger. Here "which keys are live" is one input,
//  `setKeys`, and the rest follows from it.
//
//  No SwiftUI or UIKit state and no wall clock: time comes from the
//  scheduler, effects go to the output, so the whole thing is driven by
//  synthetic touches in `KeyTouchTrackerTests`.
//

#if os(iOS) || os(macOS) || os(watchOS) || os(visionOS)
import CoreGraphics
import Foundation

/// Where a ``KeyTouchTracker`` sends what it decides.
public protocol KeyTouchOutput: AnyObject {

    /// A key started or stopped being held.
    func keyTouchSetPressed(_ isPressed: Bool, key: UUID)

    /// A gesture happened on a key's action.
    func keyTouchHandle(_ gesture: Keyboard.Gesture, on action: KeyboardAction)

    /// The finger moved on a held key. Points are in the key's own space.
    func keyTouchHandleDrag(on action: KeyboardAction, from start: CGPoint, to current: CGPoint)

    /// Show the input callout (the key preview) for a key.
    func keyTouchShowInputCallout(for action: KeyboardAction, frame: CGRect)

    /// Open the long-press menu for a key, if it has one.
    func keyTouchOpenActionCallout(for action: KeyboardAction, frame: CGRect)

    /// The finger moved while a long-press menu may be open.
    func keyTouchUpdateCalloutSelection(with value: GestureButtonDragValue)

    /// Commit the selected long-press menu item, if any. Returns whether
    /// one was committed; if so the key's own release must not fire.
    func keyTouchCommitCalloutSelection() -> Bool

    /// The touch is over: dismiss the key preview and any open menu.
    func keyTouchEndCallouts()

    /// Where in the key the finger was lifted, normalized to −0.5…+0.5 at
    /// the key's edges. Sent before the release it belongs to.
    func keyTouchNoteRelease(action: KeyboardAction, dxNorm: Double, dyNorm: Double)

    /// Start calling `tick` at the repeat rate until ``keyTouchStopRepeat()``.
    func keyTouchStartRepeat(_ tick: @escaping () -> Void)

    func keyTouchStopRepeat()
}

/// The tracker's clock.
public protocol KeyTouchScheduler: AnyObject {

    /// Monotonic time in seconds.
    var now: TimeInterval { get }

    /// Run `work` after `delay` seconds.
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void)
}

/// Turns raw touches on the key grid into keyboard gestures.
///
/// Main thread only. Hand it the live keys with ``setKeys(_:)`` (an empty
/// list while the grid is hidden) and every touch with `touchBegan`,
/// `touchMoved`, `touchEnded` and `touchCancelled`.
public final class KeyTouchTracker {

    /// One live key.
    public struct Key: Equatable {

        public init(
            id: UUID,
            hitFrame: CGRect,
            calloutFrame: CGRect,
            action: KeyboardAction,
            releaseOutsideTolerance: Double = 1
        ) {
            self.id = id
            self.hitFrame = hitFrame
            self.calloutFrame = calloutFrame
            self.action = action
            self.releaseOutsideTolerance = releaseOutsideTolerance
        }

        /// Stable for as long as the key's view is.
        public var id: UUID
        /// The key's full cell, in the space touch points arrive in.
        public var hitFrame: CGRect
        /// The same cell in the callout overlay's space.
        public var calloutFrame: CGRect
        public var action: KeyboardAction
        /// How far outside the key a lift still counts as a release, as a
        /// multiple of the key's size.
        public var releaseOutsideTolerance: Double
    }

    public struct Configuration: Equatable {

        public init(
            longPressDelay: TimeInterval = 0.5,
            repeatDelay: TimeInterval = 0.5,
            doubleTapTimeout: TimeInterval = 0.2,
            longPressMaxDragDistance: Double = 50
        ) {
            self.longPressDelay = longPressDelay
            self.repeatDelay = repeatDelay
            self.doubleTapTimeout = doubleTapTimeout
            self.longPressMaxDragDistance = longPressMaxDragDistance
        }

        public var longPressDelay: TimeInterval
        public var repeatDelay: TimeInterval
        public var doubleTapTimeout: TimeInterval
        public var longPressMaxDragDistance: Double
    }

    public init(
        scheduler: KeyTouchScheduler,
        configuration: Configuration = .init()
    ) {
        self.scheduler = scheduler
        self.configuration = configuration
    }

    public weak var output: KeyTouchOutput?
    public var configuration: Configuration

    private let scheduler: KeyTouchScheduler
    private var keys: [UUID: Key] = [:]
    private var presses: [AnyHashable: Press] = [:]
    private var lastRelease: [UUID: TimeInterval] = [:]
    private var serial = 0

    fileprivate struct Press {
        var keyID: UUID
        var serial: Int
        var start: CGPoint
        var last: CGPoint
        var maxDragDistance: CGFloat
    }
}

// MARK: - Input

public extension KeyTouchTracker {

    /// Replace the live keys. A press on a key that is no longer live is
    /// cancelled: it ends without releasing, and its timers die with it.
    func setKeys(_ newKeys: [Key]) {
        let oldKeys = keys
        keys = Dictionary(newKeys.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for (touch, press) in presses where keys[press.keyID] == nil {
            presses[touch] = nil
            output?.keyTouchStopRepeat()
            output?.keyTouchSetPressed(false, key: press.keyID)
            output?.keyTouchEndCallouts()
            if let action = oldKeys[press.keyID]?.action {
                output?.keyTouchHandle(.end, on: action)
            }
        }
        lastRelease = lastRelease.filter { keys[$0.key] != nil }
    }

    /// Whether any finger is down on a key.
    var hasActivePresses: Bool { !presses.isEmpty }

    /// A finger came down. Returns whether it landed on a live key.
    @discardableResult
    func touchBegan(_ touch: AnyHashable, at point: CGPoint) -> Bool {
        guard let key = key(at: point) else { return false }
        // One finger per key; a second finger on a held key is ignored.
        guard !presses.values.contains(where: { $0.keyID == key.id }) else { return true }
        serial += 1
        let press = Press(keyID: key.id, serial: serial, start: point, last: point, maxDragDistance: 0)
        presses[touch] = press
        output?.keyTouchSetPressed(true, key: key.id)
        output?.keyTouchHandle(.press, on: key.action)
        output?.keyTouchShowInputCallout(for: key.action, frame: key.calloutFrame)
        scheduleLongPress(touch, serial: press.serial)
        scheduleRepeat(touch, serial: press.serial)
        return true
    }

    func touchMoved(_ touch: AnyHashable, to point: CGPoint) {
        guard var press = presses[touch], let key = keys[press.keyID] else { return }
        press.last = point
        press.maxDragDistance = max(press.maxDragDistance, distance(press.start, point))
        presses[touch] = press
        let value = dragValue(press, in: key)
        output?.keyTouchUpdateCalloutSelection(with: value)
        output?.keyTouchHandleDrag(on: key.action, from: value.startLocation, to: value.location)
    }

    func touchEnded(_ touch: AnyHashable, at point: CGPoint) {
        guard var press = presses.removeValue(forKey: touch), let key = keys[press.keyID] else { return }
        press.last = point
        output?.keyTouchStopRepeat()
        output?.keyTouchSetPressed(false, key: key.id)

        let now = scheduler.now
        if let previous = lastRelease[key.id], now - previous < configuration.doubleTapTimeout {
            output?.keyTouchHandle(.doubleTap, on: key.action)
            lastRelease[key.id] = nil
        } else {
            lastRelease[key.id] = now
        }

        let value = dragValue(press, in: key)
        let size = key.hitFrame.size
        if size.width > 0, size.height > 0 {
            output?.keyTouchNoteRelease(
                action: key.action,
                dxNorm: Double(value.location.x / size.width) - 0.5,
                dyNorm: Double(value.location.y / size.height) - 0.5
            )
        }

        let committedCallout = output?.keyTouchCommitCalloutSelection() ?? false
        if !committedCallout, isRelease(at: value.location, in: key) {
            output?.keyTouchHandle(.release, on: key.action)
        }
        output?.keyTouchEndCallouts()
        output?.keyTouchHandle(.end, on: key.action)
    }

    /// The system took the touch away. The press ends without releasing.
    func touchCancelled(_ touch: AnyHashable) {
        guard let press = presses.removeValue(forKey: touch) else { return }
        output?.keyTouchStopRepeat()
        output?.keyTouchSetPressed(false, key: press.keyID)
        output?.keyTouchEndCallouts()
        if let key = keys[press.keyID] {
            output?.keyTouchHandle(.end, on: key.action)
        }
    }
}

// MARK: - Internals

private extension KeyTouchTracker {

    /// The key under a point: of those whose frame contains it, the one
    /// whose centre is nearest (frames may overlap by a few points).
    func key(at point: CGPoint) -> Key? {
        var best: (key: Key, distance: CGFloat)?
        for key in keys.values where key.hitFrame.contains(point) {
            let d = distance(CGPoint(x: key.hitFrame.midX, y: key.hitFrame.midY), point)
            if best == nil || d < best!.distance { best = (key, d) }
        }
        return best?.key
    }

    func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The touch in the key's own coordinate space.
    func dragValue(_ press: Press, in key: Key) -> GestureButtonDragValue {
        let origin = key.hitFrame.origin
        return GestureButtonDragValue(
            time: Date(timeIntervalSinceReferenceDate: scheduler.now),
            location: CGPoint(x: press.last.x - origin.x, y: press.last.y - origin.y),
            startLocation: CGPoint(x: press.start.x - origin.x, y: press.start.y - origin.y)
        )
    }

    /// A lift releases the key when it is inside the key, or outside but
    /// within the key's tolerance.
    func isRelease(at location: CGPoint, in key: Key) -> Bool {
        let size = key.hitFrame.size
        let tolerance = key.releaseOutsideTolerance
        let area = CGRect(origin: .zero, size: size)
            .insetBy(dx: -size.width * tolerance, dy: -size.height * tolerance)
        return area.contains(location)
    }

    /// The press this timer was armed for, if it is still down.
    func livePress(_ touch: AnyHashable, serial: Int) -> (press: Press, key: Key)? {
        guard let press = presses[touch], press.serial == serial,
              let key = keys[press.keyID] else { return nil }
        return (press, key)
    }

    func scheduleLongPress(_ touch: AnyHashable, serial: Int) {
        scheduler.schedule(after: configuration.longPressDelay) { [weak self] in
            guard let self, let live = self.livePress(touch, serial: serial) else { return }
            guard Double(live.press.maxDragDistance) <= self.configuration.longPressMaxDragDistance else { return }
            self.output?.keyTouchOpenActionCallout(for: live.key.action, frame: live.key.calloutFrame)
            self.output?.keyTouchHandle(.longPress, on: live.key.action)
        }
    }

    func scheduleRepeat(_ touch: AnyHashable, serial: Int) {
        scheduler.schedule(after: configuration.repeatDelay) { [weak self] in
            guard let self, self.livePress(touch, serial: serial) != nil else { return }
            self.output?.keyTouchStartRepeat { [weak self] in
                guard let self, let live = self.livePress(touch, serial: serial) else { return }
                self.output?.keyTouchHandle(.repeatPress, on: live.key.action)
            }
        }
    }
}
#endif
