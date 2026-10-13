//
//  ProxyStalenessProbeTests.swift
//  ReplayRigUITests — does the keyboard's view of the text match the field?
//
//  Bug report 2026-10-13 (1.3 (27), Messages): while rewording the middle of
//  a draft, the suggestion bar's literal slot was one character ahead of the
//  field, and the next autocorrect replace over-deleted. The keyboard takes
//  its text from `documentContextBeforeInput`, so the proxy was stale.
//
//  Cause, found with this probe: deleting a SELECTED word makes UIKit also
//  remove an adjacent space (smart delete), and iOS does not report that
//  second removal to the keyboard until the next selection change.
//  `KeyboardViewController.resyncProxyAfterSelectionDelete` forces one.
//  `testDeleteSelectedWordThenType` fails without it.
//
//  The probe host (ReplayHost, PROXY_PROBE=1) is a real UITextView that
//  publishes the text before its caret. Each step here compares the last
//  word of that with the bar's quoted literal slot — the keyboard's current
//  word. They must agree once the keyboard has settled.
//
//  Requires Lyklaborð enabled in the simulator
//  (ScreenshotUITests/testEnableKeyboardInSettings).
//

import XCTest

final class ProxyStalenessProbeTests: XCTestCase {

    private static let draft =
        "Ég held að hann hafi kannski ekki undirbúið mikið þetta samtal og smá klúðrað "
        + "opnuninni, en hann hlýtur að hafa sagt eitthvað svaraði með að væri móttekið"

    override func setUpWithError() throws { continueAfterFailure = true }

    /// Tap into the middle of the draft with a finger, press backspace at
    /// once, then type a letter — the reporter's sequence.
    func testTapMidTextThenImmediateBackspace() throws {
        let app = try launchProbe(environment: [:])
        let field = app.textViews["probe-input"]
        let delete = center(of: key("delete", in: app))
        let eth = center(of: key("ð", in: app))
        var mismatches: [String] = []

        // Tap points across the lower lines of the wrapped draft.
        let points: [CGVector] = [
            .init(dx: 0.30, dy: 0.30), .init(dx: 0.55, dy: 0.42), .init(dx: 0.72, dy: 0.42),
            .init(dx: 0.20, dy: 0.55), .init(dx: 0.48, dy: 0.55), .init(dx: 0.80, dy: 0.30),
            .init(dx: 0.62, dy: 0.18), .init(dx: 0.35, dy: 0.42),
        ]
        for (index, point) in points.enumerated() {
            let started = Date()
            field.coordinate(withNormalizedOffset: point).tap()
            let tapped = Date()
            tap(delete, in: app)
            let deleted = Date()
            NSLog("PROBE trial \(index): tap→backspace gap %.0f ms (tap took %.0f ms)",
                  deleted.timeIntervalSince(tapped) * 1000, tapped.timeIntervalSince(started) * 1000)
            check("trial \(index) after backspace", app, into: &mismatches)
            tap(eth, in: app)
            check("trial \(index) after ð", app, into: &mismatches)
            tap(delete, in: app)
            check("trial \(index) after second backspace", app, into: &mismatches)
        }
        XCTAssertTrue(mismatches.isEmpty, "stale proxy:\n" + mismatches.joined(separator: "\n"))
    }

    /// Double-tap selects a word; one backspace deletes the selection, and
    /// UIKit's smart delete also removes an adjacent space. Then type.
    func testDeleteSelectedWordThenType() throws {
        let app = try launchProbe(environment: [:])
        let field = app.textViews["probe-input"]
        let delete = center(of: key("delete", in: app))
        let eth = center(of: key("ð", in: app))
        var mismatches: [String] = []
        let points: [CGVector] = [
            .init(dx: 0.55, dy: 0.42), .init(dx: 0.30, dy: 0.30), .init(dx: 0.62, dy: 0.18),
        ]
        for (index, point) in points.enumerated() {
            field.coordinate(withNormalizedOffset: point).doubleTap()
            usleep(600_000)
            NSLog("PROBE select \(index): full=[\(app.staticTexts["probe-full"].label.suffix(60))]")
            tap(delete, in: app)
            check("select \(index) after deleting the selection", app, into: &mismatches)
            tap(eth, in: app)
            check("select \(index) after ð", app, into: &mismatches)
            tap(delete, in: app)
            check("select \(index) after a further backspace", app, into: &mismatches)
        }
        XCTAssertTrue(mismatches.isEmpty, "stale proxy:\n" + mismatches.joined(separator: "\n"))
    }

    /// The resync steps the caret back and forward. At the very start of
    /// the text there is nothing to step back over, so it must not run: the
    /// next letter has to land at offset 0.
    func testDeletingTheFirstWordLeavesTheCaretAtTheStart() throws {
        let app = try launchProbe(environment: [:])
        let field = app.textViews["probe-input"]
        let delete = center(of: key("delete", in: app))
        let eth = center(of: key("ð", in: app))
        field.coordinate(withNormalizedOffset: .init(dx: 0.04, dy: 0.07)).doubleTap()
        usleep(600_000)
        tap(delete, in: app)
        usleep(800_000)
        XCTAssertEqual(app.staticTexts["probe-before"].label, " ", "caret is at the start after the delete")
        let remainder = app.staticTexts["probe-full"].label
        XCTAssertFalse(remainder.hasPrefix("Ég"), "the first word was deleted")
        tap(eth, in: app)
        usleep(800_000)
        // Sentence start: autocapitalisation makes it "Ð".
        XCTAssertEqual(app.staticTexts["probe-before"].label.lowercased(), "ð", "the letter landed at offset 0")
        XCTAssertEqual(app.staticTexts["probe-full"].label.lowercased(), "ð" + remainder.lowercased())
    }

    /// Double-tap selects a word; typing a letter replaces the selection.
    func testTypeOverSelectedWord() throws {
        let app = try launchProbe(environment: [:])
        let field = app.textViews["probe-input"]
        let eth = center(of: key("ð", in: app))
        var mismatches: [String] = []
        let points: [CGVector] = [
            .init(dx: 0.55, dy: 0.42), .init(dx: 0.30, dy: 0.30), .init(dx: 0.62, dy: 0.18),
        ]
        for (index, point) in points.enumerated() {
            field.coordinate(withNormalizedOffset: point).doubleTap()
            usleep(600_000)
            tap(eth, in: app)
            check("replace \(index) after typing over the selection", app, into: &mismatches)
            tap(eth, in: app)
            check("replace \(index) after a second ð", app, into: &mismatches)
        }
        XCTAssertTrue(mismatches.isEmpty, "stale proxy:\n" + mismatches.joined(separator: "\n"))
    }

    /// The host moves its own caret on a timer while the test hammers
    /// backspace and a letter, so keystrokes land between a selection change
    /// and the proxy's refresh.
    func testKeystrokesRacingHostSelectionChanges() throws {
        var mismatches: [String] = []
        for jitter in ["60", "120", "250"] {
            let app = try launchProbe(environment: ["PROBE_JITTER_MS": jitter, "PROBE_JITTER_COUNT": "60"])
            let delete = center(of: key("delete", in: app))
            let eth = center(of: key("ð", in: app))
            for _ in 0..<12 {
                tap(delete, in: app)
                tap(eth, in: app)
            }
            sleep(4)  // jitter has ended; let the keyboard settle
            check("jitter \(jitter) ms, settled", app, into: &mismatches)
            tap(eth, in: app)
            check("jitter \(jitter) ms, after ð", app, into: &mismatches)
            app.terminate()
        }
        XCTAssertTrue(mismatches.isEmpty, "stale proxy:\n" + mismatches.joined(separator: "\n"))
    }

    // MARK: - Comparison

    /// Host truth vs keyboard belief. Polls briefly: the bar updates
    /// asynchronously, and only a disagreement that PERSISTS is the bug.
    private func check(_ step: String, _ app: XCUIApplication, into mismatches: inout [String]) {
        var host = "", bar = ""
        for attempt in 0..<8 {
            usleep(attempt == 0 ? 250_000 : 300_000)
            host = hostCurrentWord(app)
            bar = barLiteral(app) ?? ""
            if host == bar { break }
        }
        let before = app.staticTexts["probe-before"].label
        NSLog("PROBE \(step): host word=[\(host)] bar literal=[\(bar)] tail=[…\(before.suffix(28))]")
        // No literal slot is expected when the caret is not inside/after a
        // word; a non-empty host word with a different literal is the bug.
        if host != bar, !(host.isEmpty && bar.isEmpty) {
            mismatches.append("\(step): field has [\(host)], keyboard believes [\(bar)]")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = step
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    private func hostCurrentWord(_ app: XCUIApplication) -> String {
        let before = app.staticTexts["probe-before"].label
        guard before != " " else { return "" }
        var word = ""
        for ch in before.reversed() {
            if ch.isLetter || ch.isNumber { word.insert(ch, at: word.startIndex) } else { break }
        }
        return word
    }

    /// The bar's quoted literal slot: “token”.
    private func barLiteral(_ app: XCUIApplication) -> String? {
        let quoted = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\u{201C}")).firstMatch
        guard quoted.exists else { return nil }
        return quoted.label.trimmingCharacters(in: CharacterSet(charactersIn: "\u{201C}\u{201D}"))
    }

    // MARK: - Launch and keys

    private func launchProbe(environment: [String: String]) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PROXY_PROBE"] = "1"
        app.launchEnvironment["PROBE_TEXT"] = Self.draft
        for (name, value) in environment { app.launchEnvironment[name] = value }
        app.launch()
        XCTAssertTrue(app.textViews["probe-input"].waitForExistence(timeout: 10))
        // The period key is the only reliable Lyklaborð tell: Apple's
        // Icelandic keyboard has the same letter rows and no period key.
        for _ in 0..<6 {
            for _ in 0..<20 where !key(".", in: app).exists { usleep(500_000) }
            if key(".", in: app).exists { break }
            let globe = app.buttons["Next keyboard"]
            guard globe.waitForExistence(timeout: 3) else { break }
            globe.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        guard key(".", in: app).exists else {
            throw XCTSkip("Lyklaborð is not the active keyboard — run testEnableKeyboardInSettings first")
        }
        return app
    }

    private func key(_ token: String, in app: XCUIApplication) -> XCUIElement {
        let aliases: [String: [String]] = ["delete": ["delete", "Eyða", "backspace"]]
        for label in aliases[token] ?? [token] {
            let predicate = NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@", label, label)
            for query in [app.keyboards.keys, app.keyboards.buttons, app.buttons] {
                let match = query.matching(predicate).firstMatch
                if match.exists { return match }
            }
        }
        return app.buttons[token]
    }

    private func center(of element: XCUIElement) -> CGPoint {
        XCTAssertTrue(element.exists, "key not found: \(element)")
        let frame = element.frame
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Absolute-coordinate tap: no hierarchy query, so it is as fast as
    /// XCUITest allows.
    private func tap(_ point: CGPoint, in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y)).tap()
    }
}
