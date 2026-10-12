//
//  KeyTouchSurface.swift
//  KeyboardKit
//
//  Lyklaborð fork. The UIKit side of key touches.
//
//  Measured on device (research/tap-delay.md): a touch reaches the keyboard
//  process ~25 ms after it happens, but a SwiftUI gesture on a key is not
//  allowed to start until the system gesture gate on the keyboard window
//  gives up, ~100 ms on any key and ~780 ms for a finger held on an edge
//  key. The gate cannot be disabled; iOS re-arms it before every touch. A
//  UIKit gesture recognizer is handed touches directly, so the surface
//  reads them there and feeds a `KeyTouchTracker`, which owns every
//  decision about them.
//

#if os(iOS)
import Combine
import SwiftUI
import UIKit.UIGestureRecognizerSubclass

/// Reads raw touches for the key grid and turns the tracker's decisions
/// into calls on the keyboard's action handler and callout context.
///
/// Add ``recognizer`` to the view that hosts the keyboard and pass the
/// surface to the keyboard view with `keyTouchSurface(_:)`. `KeyboardView`
/// tells it which keys are live. Main thread only.
public final class KeyTouchSurface {

    public init() {
        tracker = KeyTouchTracker(scheduler: MainQueueScheduler())
        tracker.output = self
    }

    /// The recognizer to add to the keyboard's hosting view.
    public private(set) lazy var recognizer: UIGestureRecognizer = Recognizer(surface: self)

    /// Which key started or stopped being held. Each key view filters for
    /// its own id, so a press re-renders one key, not the grid.
    let pressEvents = PassthroughSubject<(key: UUID, isPressed: Bool), Never>()

    private let tracker: KeyTouchTracker
    private var actionHandler: KeyboardActionHandler?
    private var calloutContext: CalloutContext?
    private var repeatTimer: GestureButtonTimer?
    private var calloutActions: Callouts.ActionsBuilder?
    private var reportedKeys: [KeyTouchTracker.Key] = []
    private var isGridLive = false
}

// MARK: - Fed by KeyboardView

extension KeyTouchSurface {

    /// What the surface drives. Called by the keyboard view that owns the
    /// grid; cheap enough to call on every update.
    func bind(
        actionHandler: KeyboardActionHandler,
        calloutContext: CalloutContext,
        repeatTimer: GestureButtonTimer?,
        calloutActions: @escaping Callouts.ActionsBuilder,
        configuration: GestureButtonConfiguration
    ) {
        self.actionHandler = actionHandler
        self.calloutContext = calloutContext
        self.repeatTimer = repeatTimer
        self.calloutActions = calloutActions
        tracker.configuration = .init(
            longPressDelay: configuration.longPressDelay,
            repeatDelay: configuration.repeatDelay,
            doubleTapTimeout: configuration.doubleTapTimeout,
            longPressMaxDragDistance: configuration.longPressMaxDragDistance
        )
    }

    /// The keys the grid laid out. They only take touches while the grid
    /// is live.
    func setKeys(_ keys: [KeyTouchTracker.Key]) {
        reportedKeys = keys
        tracker.setKeys(isGridLive ? keys : [])
    }

    /// Whether the grid is on screen and uncovered. The grid stays in the
    /// view hierarchy, laid out, under the emoji keyboard and the number
    /// pad; frames alone cannot tell.
    func setGridLive(_ isLive: Bool) {
        guard isGridLive != isLive else { return }
        isGridLive = isLive
        tracker.setKeys(isLive ? reportedKeys : [])
    }
}

// MARK: - KeyTouchOutput

extension KeyTouchSurface: KeyTouchOutput {

    public func keyTouchSetPressed(_ isPressed: Bool, key: UUID) {
        pressEvents.send((key, isPressed))
    }

    public func keyTouchHandle(_ gesture: Keyboard.Gesture, on action: KeyboardAction) {
        actionHandler?.handle(gesture, on: action)
    }

    public func keyTouchHandleDrag(on action: KeyboardAction, from start: CGPoint, to current: CGPoint) {
        actionHandler?.handleDrag(on: action, from: start, to: current)
    }

    public func keyTouchShowInputCallout(for action: KeyboardAction, frame: CGRect) {
        calloutContext?.updateInputAction(action, frame: frame)
    }

    public func keyTouchOpenActionCallout(for action: KeyboardAction, frame: CGRect) {
        guard let calloutContext else { return }
        let actions = calloutActions?(.init(action: action))
        calloutContext.updateSecondaryActions(actions, for: action, frame: frame)
        if calloutContext.secondaryActions.isEmpty { return }
        calloutContext.resetInputAction()
    }

    public func keyTouchUpdateCalloutSelection(with value: GestureButtonDragValue) {
        calloutContext?.updateSecondaryActionsSelection(with: value)
    }

    public func keyTouchCommitCalloutSelection() -> Bool {
        calloutContext?.handleSelectedSecondaryAction() ?? false
    }

    public func keyTouchEndCallouts() {
        calloutContext?.resetInputActionWithDelay()
        calloutContext?.resetSecondaryActions()
    }

    public func keyTouchNoteRelease(action: KeyboardAction, dxNorm: Double, dyNorm: Double) {
        Keyboard.TouchEvidence.noteRelease(action: action, dxNorm: dxNorm, dyNorm: dyNorm)
    }

    /// Uses the shared repeat timer, the same one the keyboard behavior
    /// reads to decide when a held backspace starts deleting words.
    public func keyTouchStartRepeat(_ tick: @escaping () -> Void) {
        guard let repeatTimer, !repeatTimer.isActive else { return }
        let box = UncheckedSendable(tick)
        repeatTimer.start { box.value() }
    }

    public func keyTouchStopRepeat() {
        repeatTimer?.stop()
    }
}

// MARK: - Touch input

private extension KeyTouchSurface {

    func touchBegan(_ touch: UITouch) {
        let start = KeyLatencyProbe.now
        let landed = tracker.touchBegan(ObjectIdentifier(touch), at: touch.location(in: nil))
        guard landed else { return KeyLatencyProbe.count("surface.miss") }
        guard KeyLatencyProbe.isEnabled else { return }
        KeyLatencyProbe.count("surface.hit")
        KeyLatencyProbe.record("press.1-touchToCallback", ms: (start - touch.timestamp) * 1000)
        KeyLatencyProbe.record("press.2-handler", ms: (KeyLatencyProbe.now - start) * 1000)
        DispatchQueue.main.async {
            KeyLatencyProbe.record("press.3-untilMainFree", ms: (KeyLatencyProbe.now - start) * 1000)
            KeyLatencyProbe.notePress()
        }
    }

    func touchMoved(_ touch: UITouch) {
        tracker.touchMoved(ObjectIdentifier(touch), to: touch.location(in: nil))
    }

    func touchEnded(_ touch: UITouch) {
        let start = KeyLatencyProbe.now
        tracker.touchEnded(ObjectIdentifier(touch), at: touch.location(in: nil))
        guard KeyLatencyProbe.isEnabled else { return }
        KeyLatencyProbe.record("release.1-touchToCallback", ms: (start - touch.timestamp) * 1000)
        KeyLatencyProbe.record("release.2-handler", ms: (KeyLatencyProbe.now - start) * 1000)
        DispatchQueue.main.async {
            KeyLatencyProbe.record("release.3-untilMainFree", ms: (KeyLatencyProbe.now - start) * 1000)
        }
    }

    func touchCancelled(_ touch: UITouch) {
        tracker.touchCancelled(ObjectIdentifier(touch))
    }

    var hasActivePresses: Bool { tracker.hasActivePresses }

    /// Never recognizes: it only observes touches and forwards them. It
    /// must neither block nor be blocked by SwiftUI's own recognizers,
    /// which still serve everything that is not a grid key.
    final class Recognizer: UIGestureRecognizer {

        init(surface: KeyTouchSurface) {
            self.surface = surface
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        private weak var surface: KeyTouchSurface?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            touches.forEach { surface?.touchBegan($0) }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            touches.forEach { surface?.touchMoved($0) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            touches.forEach { surface?.touchEnded($0) }
            failIfIdle(event)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            touches.forEach { surface?.touchCancelled($0) }
            failIfIdle(event)
        }

        /// Let UIKit reset the recognizer once every finger is up.
        private func failIfIdle(_ event: UIEvent) {
            let remaining = event.allTouches?.contains {
                $0.phase != .ended && $0.phase != .cancelled
            } ?? false
            if !remaining, surface?.hasActivePresses != true { state = .failed }
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}

private final class MainQueueScheduler: KeyTouchScheduler {

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// The repeat timer wants a `@Sendable` closure; it fires on the main run
/// loop, where the tick is used.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - SwiftUI plumbing

/// The live keys of a tracked grid, gathered from the key views.
struct KeyTouchKeysPreference: PreferenceKey {

    static var defaultValue: [KeyTouchTracker.Key] { [] }

    static func reduce(value: inout [KeyTouchTracker.Key], nextValue: () -> [KeyTouchTracker.Key]) {
        value.append(contentsOf: nextValue())
    }
}

public extension EnvironmentValues {

    /// The surface a keyboard view should hand its key grid to, if any.
    @Entry var keyTouchSurface: KeyTouchSurface?
}

extension EnvironmentValues {

    /// Set by `KeyboardView` on the key grid only: keys under it report to
    /// this surface instead of installing a gesture of their own.
    @Entry var trackingKeyTouchSurface: KeyTouchSurface?
}

public extension View {

    /// Let the keyboard view below take key touches from a surface instead
    /// of SwiftUI gestures.
    func keyTouchSurface(_ surface: KeyTouchSurface?) -> some View {
        environment(\.keyTouchSurface, surface)
    }
}
#endif
