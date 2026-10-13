# Agent-driven iOS Simulator debugging and testing — state of the art, October 2026, and what Lyklaborð should take from it

*Investigated 2026-10-13. Sources: Apple documentation and release notes (developer.apple.com, fetched today), the local Xcode 27.0 (27A266a) toolchain (`--help`, man pages, and strings in the shipped binaries; nothing was launched), the installed simulator runtimes on disk (iOS 17.0, 18.4, 26.5; no iOS 27 runtime is installed), the source of each third-party tool read at a pinned commit via `gh`, Apple Developer Forums threads, and this repo. No simulator was booted and no tool was installed, so every command below is syntax from help text or source, not an observed run.*

Evidence tags used throughout:

- **[A]** stated in an Apple document or release note (URL given).
- **[L]** read from the local Xcode 27.0 (27A266a) install: help text, man page, a file listing, or strings in a binary. Binary strings are first-party but undocumented and can change without notice.
- **[S]** read in a third-party tool's source at the commit named.
- **[R]** established by this repo's own code, notes or measurements.
- **[C]** community report (forum post, GitHub issue), not confirmed by the owner of the code.
- **[I]** my inference. Not verified anywhere.

## Verdict up front

- **XCUITest is still the only route with evidence that it works on a keyboard extension, and that evidence is ours.** No third-party tool has any documentation, source comment or issue, for or against, about driving a third-party keyboard appex. This repo already shows XCUITest reading the extension's accessibility identifiers and delivering touches that arrive in the extension as UIKit touches. Do not adopt a new driver to get what the existing rig already has.
- **Every tool's "type text" bypasses the on-screen keyboard.** idb, AXe, sim-use and argent send HID key codes; Maestro, WebDriverAgent, mobile-mcp and agent-device use XCTest's text-input event path. A keyboard extension can only be exercised by touches on its keys.
- **Xcode 27 ships a first-party agent driver.** Xcode's MCP server gained device-interaction tools: start a session on a simulator or device, build-install-run, then one call that injects a tap, swipe, drag or a multi-finger keyframe sequence and returns a screenshot, a UI hierarchy with hit points, and the app's console log. It is built on XCTest's synthesized events. Whether its hierarchy sees into a keyboard extension is untested; its own skill text warns that remote views can be opaque.
- **Apple documents one way to enable a custom keyboard: the Settings UI.** Nothing from Apple covers `simctl`, `defaults` or a profile. The Settings test is the right mechanism; what is missing is a positive identity check that Apple's keyboard cannot pass. The extension can supply one cheaply (an accessibility identifier plus a record it writes to the App Group container).
- **Apple's docs say almost nothing about `documentContextBeforeInput`.** No statement on truncation, staleness or per-host differences, and no Apple-staff forum answer. One 2022 forum post reports the same symptom as this week's iMessage bug (context one character longer than the field, in Safari), with no reply. The contract can only be learned by recording it against real hosts, and the simulator can do that for our own host fields and probably for Messages, Notes and Safari.
- **The simulator tells you nothing about the memory limit.** Apple: macOS issues no memory warnings and no out-of-memory terminations to simulator processes. Relative footprint and leak checks work there; the limit, jetsam and the fallback to the system keyboard are device-only. On device, `devicectl` in Xcode 27 can now do most of the retrieval without hands, including screenshots and screen recording.
- **Xcode 27 broke and moved things.** Simulator.app is replaced by Device Hub, the legacy HID path is gone, and several third-party tools have open Xcode 27 breakage. Anything pinned to private simulator APIs is a maintenance cost this project does not need.

## What changed recently

| When | What | Evidence |
|---|---|---|
| Xcode 26.3 | Agentic coding in Xcode (Claude Agent, Codex); Xcode's capabilities exposed over MCP; external agents connect with `xcrun mcpbridge`, and the project must be open in Xcode | [A] https://developer.apple.com/documentation/xcode-release-notes/xcode-26_3-release-notes, https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode |
| Xcode 26.1 | `xcrun devicectl device sysdiagnose` (160492448) | [A] https://developer.apple.com/documentation/xcode-release-notes/xcode-26_1-release-notes |
| Xcode 26.4 | Crashes of apps driven through `XCUIApplication(bundleIdentifier:)` reported with the crash log attached (166401942); Swift Testing image attachments | [A] https://developer.apple.com/documentation/xcode-release-notes/xcode-26_4-release-notes |
| Xcode 27.0, released 2026-09-14 | "Agents can now boot simulators, install and launch apps, synthesize touch events, and capture screenshots to verify UI behavior." (175179787) | [A] https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes (release date from https://developer.apple.com/news/releases/rss/releases.rss) |
| Xcode 27.0 | Headless MCP server preview that "runs without requiring an open Xcode workspace": `sudo xcrun mcp-server enable`, `xcrun mcp-server status`; unattended use with `--unsafe-always-allow-all-agents` (181836944) | [A] same page; [L] `xcrun mcp-server --help` |
| Xcode 27.0 | `lldb-mcp` ships with LLDB (176901842); agents can drive the run state and debugger console and switch schemes and destinations (176935844) | [A] same page |
| Xcode 27.0 | Device Hub hosts simulators and devices; `simctl reboot`; `devicectl` JSON to stdout (63583278) | [A] same page |
| Xcode 27.0 | `xctrace record` "would never start a recording for simulator device targets" fixed (183624872); `xctrace export` takes time ranges and `.logarchive` input directly | [A] same page |
| Xcode 27.0 | `devicectl device capture screenshot` and `screen-record` exist | [L] `xcrun devicectl device capture screenshot --help`, `screen-record --help`; not mentioned in the release notes |
| CoreSimulator 1155.4 (Xcode 27) | The guest drops legacy Indigo HID input; DTUHID is the default | [S] `facebook/idb@6582b37:FBSimulatorControl/HID/SimulatorHIDTransportSelection.swift` L22–55 |
| iOS 27 | MetricKit `MemoryExceptionDiagnostic` "available when your app or app extension is terminated for exceeding its memory limit" (159890067) | [A] https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes |
| Xcode 27.1 RC (2026-10-05) | "Running and debugging most app extensions is unavailable in the iPhone Duo Simulator runtime." (187708767) | [A] https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes |

This machine is on Xcode 27.0 (27A266a), not 26.x. [L]

## Tools

"Keyboard extension?" means: can it send real touches to keys in a third-party keyboard appex, and can it read that appex's elements. Nothing was run, so "unknown" is the honest answer for every third-party tool.

| Tool | What it does | How it drives the simulator | Keyboard extension? | Status / licence | Source |
|---|---|---|---|---|---|
| XCUITest (XCUIAutomation) | Element and coordinate taps, press-and-drag with velocity, snapshots, attachments, metrics; simulator and device | Test runner process "synthesizing events" (Apple's wording; not accessibility actions) [A] | **Yes for touches and for reading elements, on the iOS 18.x simulator** [R]: tests find `emoji-search-button` (set in `KeyboardExt/LyklabordEmojiKeyboard.swift`) through `app.buttons`, and `research/tap-delay.md` timed XCUITest-synthesized touches from the touch event's timestamp to the key's gesture callback inside the extension, so they arrive as touch events, not accessibility activations. No public staggered multi-touch API. | Apple, current; framework split out as XCUIAutomation in Xcode 16.3 | https://developer.apple.com/documentation/xcuiautomation, https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/testing_with_xcode/chapters/09-ui_testing.html |
| Xcode 27 MCP device interaction (`DeviceInteractionStartSession`, `…StartWorkspaceSession`, `…InstallAndRun`, `…Synthesize`, `…EndSession`) | One call = interaction + screenshot + hierarchy file with `hitPoint` per element + console log path. Tap with hold duration, double tap, swipe, drag, multi-touch keyframes, type, hardware buttons, orientation, wait. "on a physical device or simulator" | XCTest synthesized events (`XCSynthesizedEventRecordBuilder`, `XCUIElementSnapshot`, `typeText:atOffset:typingSpeed:shouldRedact:` symbols) through a live Xcode [L] | **Unknown.** Touch is coordinate-based so it should reach the keys [I]. The skill text warns: "Elements marked `isRemoteLeafPlaceholder` do not report child elements — interacting with them requires falling back to screenshot-estimated coordinates" [L]; whether a keyboard appex is such a placeholder is untested. | Apple, Xcode 27.0. Tool names and behaviour are from binary strings in `IDEDeviceInteraction.framework`; Apple's public text is the one release-note sentence above | [A] Xcode 27 release notes; [L] `/Applications/Xcode.app/Contents/PlugIns/IDEDeviceInteraction.framework` |
| `simctl` | Boot, install, launch, `io screenshot`, `io recordVideo`, `spawn`, `privacy`, `status_bar`, `get_app_container … groups`, `clone`, `diagnose` | CoreSimulator | **No touch injection at all.** `simctl ui` is appearance, contrast and content size only. [L] | Apple, Xcode 27.0 | [L] `xcrun simctl help`, `help ui`, `help io` |
| idb | Coordinate tap, swipe, two-finger events, HID keys, tree dump, screenshot, video, logs; REPL has `touchDown`/`touchMove`/`touchUp` | Private SimulatorKit HID (Indigo, DTUHID on Xcode 27). Element taps are accessibility presses: "not synthesized touches" [S] | Unknown. Coordinate tap is real HID [S]. Tree via AXPTranslator is the frontmost app; the `axbridge` backend documents following subtrees "drawn by another process" but does not name keyboards [S]. Two fingers move in one event, so no staggered rollover. | v1.7.0, 2026-10-13, MIT, 5.4k stars | https://github.com/facebook/idb at `6582b37`: `website/docs/idb/ui.mdx` L163, `website/docs/idb/accessibility.mdx` L95 and L165, `FBSimulatorControl/HID/SimulatorHIDEvent.swift` |
| AXe | Coordinate or selector tap (both HID), separate touch down/up with real hold time, swipe, HID typing, `describe-ui` | idb's `FBSimulatorHID` from a pinned fork [S] | Unknown, leaning no for inspection: tree is the frontmost app only, and #65 [C] says it cannot see WKWebView content in another process. #71 [C]: default tap "reports success but delivers nothing on Xcode 27". No multi-touch. | v1.8.0, 2026-07-20, MIT | https://github.com/cameroncooke/AXe at `30f4bfa`: `Sources/AXe/Commands/Tap.swift`, `Commands/Touch.swift`, `Utilities/AccessibilityFetcher.swift` |
| MobileBuildMCP (was XcodeBuildMCP, now under getsentry) | Build, run, log and UI tools for agents | UI tools shell out to bundled AXe 1.8.0 [S] | Same as AXe. #535 [C]: keyboard-toggle tools "silently do nothing on Xcode 27" because Device Hub cannot be scripted. | v2.7.1, 2026-09-23, MIT | https://github.com/getsentry/MobileBuildMCP at `d13ff0c`: `.axe-version`, `src/mcp/tools/ui-automation/snapshot_ui.ts` |
| ios-simulator-mcp | MCP wrapper | `idb` CLI [S] | Same as idb's default path (HID tap, frontmost-app tree) | v2.1.0, 2026-08-13, MIT | https://github.com/joshuayoes/ios-simulator-mcp at `a32f7f8`: `src/index.ts` |
| sim-use | Tap, long-press, swipe, `multi-touch` (two fingers, simultaneous), tree, video | idb's `FBSimulatorHID`, statically linked; AXPTranslator [S] | Unknown. Its source says "The simulator does not expose the keyboard as a discrete AX node" and finds Apple's keys among the frontmost app's buttons, so the system keyboard does appear in AXPTranslator dumps [S]. Says nothing about an appex. | v0.14.0, 2026-08-27, Apache-2.0; project created 2026-06-26 | https://github.com/lycorp-jp/sim-use at `30274ba`: `Sources/iOSSimBackend/A11y/SoftKeyboardDetector.swift` L4–30 |
| mobile-mcp | Coordinate tap, long-press, swipe, element list, screenshot | XCTest runner (`XCSynthesizedEventRecord`) in devicekit-ios [S] | Unknown | 1.0.10, 2026-10-11, Apache-2.0; the on-device agent is FSL-1.1 (source-available) | https://github.com/mobile-next/mobile-mcp at `0a6a38b`; devicekit-ios at `d963aab`: `DeviceKitTests/XCTest/EventRecord.swift` |
| Maestro | YAML flows; `maestro mcp` exposes run-flow, inspect-screen, screenshot (no direct tap tool) | XCTest runner (`XCSynthesizedEventRecord`) [S] | Unknown. Hierarchy has a fallback that fetches `element.keyboards.firstMatch`; nothing about custom keyboards in docs or issues. | cli-2.11.0, 2026-09-29, Apache-2.0 | https://github.com/mobile-dev-inc/Maestro at `df40dea`: `maestro-ios-xctest-runner/…/Handlers/TouchRouteHandler.swift` L35–42, `ViewHierarchyHandler.swift` L222–229 |
| Appium XCUITest driver + WebDriverAgent | W3C actions with one `XCPointerEventPath` per pointer, so independent per-finger timelines; simulator and device | XCTest runner, private synthesis [S] | Unknown, with the nearest evidence: WDA #1085 (closed 2025-12-18, fixed by a maintainer) concerned wrong offsets for "a custom keyboard from the app"; the fix is the `enforceCustomSnapshots` setting. Whether that was an appex or an in-app input view is not established. | driver v12.18.0 (2026-10-13), WDA v16.15.0 (2026-10-12); Apache-2.0 / BSD | https://github.com/appium/WebDriverAgent at `e7e2665`: `WebDriverAgentLib/Utilities/FBW3CActionsSynthesizer.m`; https://github.com/appium/appium-xcuitest-driver at `f34584d`: `docs/reference/settings.md` L179 |
| agent-device | CLI for agents; taps, gestures, two-finger pan/pinch | XCTest runner; both `XCUICoordinate` and private synthesis [S] | Unknown | v0.21.27, 2026-10-12, MIT | https://github.com/callstack/agent-device at `a95d2d5` |
| argent | `gesture-custom` with explicit down/move/up events and delays; `describe` claims to read "whatever is currently visible — including system dialogs" | Closed binaries; mechanism unverifiable | Unknown | v0.28.0, 2026-10-09; Apache-2.0 source, proprietary `simulator-server` and `ax-service` | https://github.com/software-mansion/argent at `2b67970` |
| Claude Code computer use (CLI) | Mouse and screenshots on the Mac, names "the iOS Simulator" as a target | macOS events on the simulator window | Single-pointer clicks would land on keys [I]; screenshots are the only inspection. | Research preview, macOS, interactive sessions only | https://code.claude.com/docs/en/computer-use |
| Claude Desktop simulator pane | "drives the simulator directly"; tap, type, launch, screenshot | Not documented | Unknown | Public beta | https://code.claude.com/docs/en/desktop-ios-simulator |
| `devicectl` | Device: install, launch with env, list and terminate processes, copy from app and App Group containers, crash logs, sysdiagnose, screenshot, screen recording, memory warning | CoreDevice | No touch injection. Lists and terminates the extension process on a device [R: `tools/cold-start/run-cohort.sh`] | Apple, Xcode 27.0 | [L] `xcrun devicectl device --help`; https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line |

Searched for and found nothing: issues mentioning "custom keyboard", "keyboard extension", "third-party keyboard" or "remote view" in idb, AXe, MobileBuildMCP, ios-simulator-mcp, mobile-mcp, Maestro, appium-xcuitest-driver, agent-device, argent and sim-use (WDA #1085 is the one near-hit).

## Gap 1 — enabling the extension and proving which keyboard is on screen

**Enabling**

- Apple's only documented path is Settings > General > Keyboard > Keyboards > Add New Keyboard, for simulator and device alike. [A] https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard
- Nothing from Apple (docs, release notes, staff posts) covers enabling by `simctl`, by `defaults write … AppleKeyboards`, or by a configuration profile. [A, by absence]
- This repo already established that seeding `AppleKeyboards` and rebooting does not activate the extension on its own (`capture.sh`, commit `3046793`). [R]
- Two other projects' scripts disagree with each other on the same point: Clipbara's says a UI test "still has to switch it on in Settings… because reinstalling the app turns it off again"; Funput's relies on the defaults write plus a reboot. [C] `mobrava/Clipbara@feaca5d:scripts/ios-sim-enable-keyboard.sh`, `Funput/Funput@6b0029a:platforms/ios/Scripts/uitest-enable-keyboard.sh`
- `capture.sh` uninstalls the app before every run to defeat the stale-appex cache. If Clipbara's comment is right, that uninstall is what forces the Settings test to run every time. Untested here. [I]
- `docs/WAVES.md` (2026-10-12) records that the enablement test does not run on the iOS 26.5 simulator. The cause is not investigated; Apple's iOS 26 and Xcode 26–27 release notes say nothing about the Settings keyboard path or its accessibility tree. [R] [A, by absence]
- `pluginkit` is present inside all three installed runtimes (`RuntimeRoot/usr/bin/pluginkit`), with usage `pluginkit -m [-ADv] [-p protocol] [-i identifier]` and `pluginkit -e election`. [L] So `xcrun simctl spawn <udid> pluginkit -m -v -p com.apple.keyboard-service` should list registered keyboard extensions with their election state [I]. Whether `-e use` has any effect on keyboard enablement is undocumented and untested; the macOS man page (2014) mentions neither iOS nor keyboards.
- `simctl clone` exists [L]. A simulator enabled once could be cloned as a base for later runs instead of re-running Settings automation; whether the enabled-keyboard state survives a clone is untested [I].

**Proving identity**

- A host app cannot tell which third-party keyboard is active through public API: `UITextInputMode` exposes `primaryLanguage` and `activeInputModes` only, and Apple's Icelandic keyboard reports the same language. [A] https://developer.apple.com/documentation/uikit/uitextinputmode
- XCUITest documents `XCUIApplication(bundleIdentifier:)` for applications only; nothing about addressing an extension process. [A] https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/init(bundleidentifier:)
- What works today: the extension's accessibility identifiers are visible to the test through the host app's tree (iOS 18.x simulator). [R] An identifier only Lyklaborð sets is a positive marker; the period key is a negative one (Apple's keyboard lacks it today).
- The extension already writes a record to the App Group container at `viewDidLoad` (`Documents/diagnostics/cold-start.jsonl`, with `isSimulator` and a run id). [R] `xcrun simctl get_app_container <udid> is.solberg.lyklabord groups` returns the host path of that container. [L] A harness can therefore require "a new record from this build appeared during this run", which Apple's keyboard cannot produce.
- Process check: the iOS 26.5 runtime ships `launchctl` (`RuntimeRoot/bin/launchctl`) and all three ship `log` [L], so `simctl spawn <udid> launchctl list` and `log stream --predicate 'process == "<appex executable>"'` are available; that the appex shows up there by a recognisable label is unverified [I]. On a device the equivalent, `devicectl device info processes`, is already used by `run-cohort.sh`. [R]
- A process existing is weaker than the record above: the extension process can outlive the keyboard being on screen. Apple: "dismissing the keyboard won't necessarily terminate the keyboard extension process." [A] https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard
- `kbdebug` ships in the iOS 26.5 runtime's `usr/bin` (the other two were not checked for it); its strings show it queries the keyboard arbiter for debug info (active process, keyboard focus). [L] Undocumented and not run; a lead, nothing more.

## Gap 2 — driving keys inside the extension

**Possible**

- XCUITest element taps and `XCUICoordinate` taps deliver touches the extension handles as UIKit touches; `research/tap-delay.md` timed them from touch timestamp to gesture callback on the SwiftUI path (iOS 18.3 simulator). [R] The same has not been re-measured on the `KeyTouchSurface` path that replaced it on 2026-10-12; the 1.3 (27) simulator pass on iOS 18.4 is recorded in `docs/WAVES.md` without saying how it was driven. Apple describes the mechanism as the test process "synthesizing events that UI in your app responds to". [A]
- XCUITest reads the extension's elements (labels and identifiers) in the host app's tree. [R]
- Off-centre taps: `XCUICoordinate` takes a normalized or point offset inside an element, so a test can land anywhere on a key rather than dead centre. [A] https://developer.apple.com/documentation/xcuiautomation/xcuicoordinate This addresses the two known harness artefacts (dead-centre taps read as deliberate; the 3 s stuck-gesture cancel at an identical point). [R: `research/tap-delay.md`]
- Long-press and slide: `press(forDuration:thenDragTo:withVelocity:thenHoldForDuration:)`. [A]
- Staggered multi-touch (rollover: second finger down before the first lifts) is expressible in two places:
  - Xcode 27's multi-touch command: keyframes of finger positions with a duration between them; "A finger that reappears in a later keyframe after lifting starts a new tap." [L]
  - WebDriverAgent's W3C actions, one pointer path per finger with independent timing. [S]
- Real HID at a coordinate, outside XCTest: idb, AXe, sim-use. [S] That such a touch reaches an out-of-process appex is not stated in any source [I]; it would be surprising if it did not, since the system routes it like a finger.

**Not possible or not established**

- `simctl` cannot inject touches. [L]
- No tool can type into the extension by "type text"; all of them bypass the on-screen keyboard. [S] XCUITest's `typeText` is documented only as needing keyboard focus [A]; this repo's tests already tap keys instead.
- Element-targeted actions in idb (`ui tap <marker>`, `--api ax`) are accessibility presses and skip gesture recognizers. [S]
- Public XCUITest has no API for two fingers with different timing. [A, by absence]
- Whether AXPTranslator-based dumps (idb, AXe, sim-use) or Xcode 27's hierarchy include a third-party keyboard's keys: unknown. The one source statement is that Apple's keyboard keys appear among the frontmost app's buttons. [S]
- Device Hub's GUI cannot send a two-finger touch (known issue 169537162). [A] That is the window, not the automation path.
- XCUITest's own accessibility snapshots dominated the keyboard's main-thread time in our UI-test runs (about 72%). [R] Any XCTest-runner tool will distort timing the same way [I]; simulator typing is for behaviour, not latency.

## Gap 3 — the real `UITextDocumentProxy` contract across real hosts

**What Apple says**

- `documentContextBeforeInput`: "Textual context before the insertion point in the current text input object." No word on length, truncation or freshness. [A] https://developer.apple.com/documentation/uikit/uitextdocumentproxy/documentcontextbeforeinput
- `adjustTextPosition(byCharacterOffset:)`: "The number of characters to adjust the insertion point by." The unit is not specified. [A] https://developer.apple.com/documentation/uikit/uitextdocumentproxy/adjusttextposition(bycharacteroffset:)
- "Custom keyboards run in an isolated process that doesn't have direct access to the text input view." [A] https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard
- `textWillChange`/`textDidChange`: the controller "can automatically be informed"; no ordering or delivery guarantee. [A] https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards
- No Apple document and no Apple-staff forum reply addresses stale context after `insertText`/`deleteBackward`, late `textDidChange`, or differences between `UITextField`, `UITextView`, web views, SwiftUI and Messages. [A, by absence]

**What the forums say (all community, no Apple reply)**

| Thread | Date | Report |
|---|---|---|
| https://developer.apple.com/forums/thread/700446 | Feb 2022, 0 replies | In Safari's search field showing `abcd`, `documentContextBeforeInput` returned `" abcd"` (5 characters), so an offset computed from its length overshot. The same class as this week's iMessage bug. |
| https://developer.apple.com/forums/thread/133403 | May 2020 | Accepted community answer: count in UTF-16 units for `adjustTextPosition`; the poster confirmed it fixed emoji handling. |
| https://developer.apple.com/forums/thread/45121 | 2016, replies 2019 | `textDidChange` is not called for the keyboard's own proxy edits; moving the cursor triggers it and refreshes the proxy. |

**What an agent can do in the simulator**

- Host truth for our own fields: a rig host owns its text views, so it can record the full text and selected range on every change, or expose them as accessibility values that XCUITest reads with `value` (the tests already do `field.value as? String`). [R] The simulator shares the Mac's filesystem, so a file in the host's container is readable from the test script (`simctl get_app_container`). [L]
- What the extension saw: a debug-only journal of every proxy read (before, after, selected text, `documentIdentifier`) written to the App Group container, the same channel `ColdStartMetrics` uses. [R]
- Cursor moves: an `XCUICoordinate` tap inside the field's text, the extension's own space-drag cursor, or a host button that sets `selectedRange` exactly. [A] [I]
- Field kinds worth covering in one host: `UITextField`, `UITextView`, SwiftUI `TextField` (single-line and `axis: .vertical`), and a `WKWebView` with a content-editable element. The web view's truth is readable from the host with `evaluateJavaScript`. [I]
- Apple's own apps: `MobileSMS.app`, `MobileNotes.app` and `MobileSafari.app` are present in the installed 18.4 and 26.5 runtimes. [L] XCUITest can launch them by bundle id and read a field's `value` [A], which gives the host-side text to compare. Whether the Messages compose field is usable in the simulator without an account is not tested and not documented.

**Not possible**

- Reading true text out of a third-party host (Messenger, Slack) other than through what its accessibility tree exposes.
- Trusting any single host as "the contract". The useful output is a per-host profile (window length, where it cuts, whether a read lags an edit, extra leading or trailing characters) fed back into `ProxySimulator`'s opt-in behaviours, which already model both window shapes. [R]

## Gap 4 — memory and launch

**Simulator**

- "When you run your app in the simulator, the memory gauge always stays in the green (safe) region because macOS doesn't issue memory warnings or out-of-memory terminations." [A] https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use So the simulator never kills the extension for memory and never shows the fallback to the system keyboard.
- Xcode 27.2 beta 2 lists "The Device->Simulate Memory Warning menu item does not work" (188326513). [A] https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes
- All three runtimes ship `leaks`, `heap`, `vmmap` and `sample`; the iOS 26.5 runtime also has `malloc_history` (not checked in the others). None has `footprint`. [L] The host's `footprint` reports `phys_footprint` and its peak for a pid and "must be run as root when inspecting processes that are not owned by the current user". [L] `man footprint`
- `leaks <pid> -outputGraph` writes a `.memgraph` that `heap`, `vmmap` and `footprint` can read later, and `heap -diffFrom=` compares two. [L] `man leaks`, `man heap` Whether these attach to a simulator appex without extra privileges is not stated in the man pages and not tested.
- `xctrace record --template Allocations --device <udid> --attach <pid|name>` then `xctrace export --toc` / `--xpath` gives XML an agent can parse. [L] Recording on simulator targets only works from Xcode 27 [A]. Attaching to an appex is untested.
- `MallocStackLogging` can be passed with `SIMCTL_CHILD_` to processes `simctl` starts. [L] The system starts the appex, so it probably does not reach it [I].
- Use: footprint deltas between builds, leak detection across repeated present/dismiss, and the existing `phys_footprint` log lines. [R] Absolute numbers do not transfer: different allocator behaviour, a Mac's page cache, no limit.

**Device**

- Apple gives no number for the keyboard limit: "The memory limits vary from model to model." [A] https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard "30 MB" and similar are community figures. [C] https://developer.apple.com/forums/thread/105815
- Jetsam reports are JSON named `JetsamEvent_<date>`, with a `reason` on the killed process (`per-process-limit` for a limit kill). [A] https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports
- Hands-free retrieval and probing, all [L] from `xcrun devicectl … --help`:
  - `devicectl device info files --device X --domain-type systemCrashLogs` then `devicectl device copy from … --domain-type systemCrashLogs`
  - `devicectl device process sendMemoryWarning --device X --pid <pid>`
  - `devicectl device info processes --device X --json-output -`
  - `devicectl device sysdiagnose --device X --destination <dir>`
  - `devicectl device capture screenshot --device X --destination shot.png`
- MetricKit delivers on a physical device only [A] https://developer.apple.com/documentation/metrickit/mxmetricmanager; iOS 27 adds a memory-exception diagnostic for extensions (table above). Whether a keyboard extension can subscribe itself is not documented; the only staff statement is for Network Extensions ("not a supported workflow"). [A, staff post] https://developer.apple.com/forums/thread/652719
- `os_proc_available_memory()` returns 0 "If the calling process isn't an app". [A] https://developer.apple.com/documentation/os/os_proc_available_memory Whether a keyboard extension counts as an app here is not stated.

**Still needs hands**: pairing (Trust), Developer Mode, keeping the phone unlocked, and selecting Lyklaborð in a host field. [A] https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device `devicectl` has no unlock command. [L]

## Gap 5 — evidence an agent can attach to a claim

- **Result bundle.** `xcodebuild test … -resultBundlePath X.xcresult` (the path must not exist). [L] `man xcodebuild`
- **Pass/fail as JSON.** `xcrun xcresulttool get test-results summary --path X.xcresult --compact`; per-test tree with `get test-results tests`. [L]
- **Attachments with a manifest.** `xcrun xcresulttool export attachments --path X.xcresult --output-path ./att` writes the files and a `manifest.json` mapping each test identifier to its attachments, with device name and timestamp. [L] `xcrun xcresulttool export attachments --schema`
- **Screenshots and video.** `XCTAttachment` defaults to `deleteOnSuccess`; the tests here already set `.keepAlways`. [A] https://developer.apple.com/documentation/xctest/adding-attachments-to-tests-activities-and-issues [R] UI tests record the screen automatically since Xcode 15, kept only for failures unless the test plan says "On, and keep all". [A] https://developer.apple.com/documentation/xcode-release-notes/xcode-15-release-notes, https://developer.apple.com/videos/play/wwdc2025/344/
- **Outside XCTest.** `simctl io <udid> screenshot` and `recordVideo` (prints "Recording started" to stderr; stop with SIGINT). [L]
- **Logs.** `xcrun simctl spawn <udid> log stream --level debug --style ndjson --predicate 'subsystem == "…"'`. The host `log help stream` lists `ndjson`; the runtime's own `log` binary was not run. [L] The console of the test run: `xcresulttool get log --type console`. [L]
- **Xcode 27 agent tool.** Each `DeviceInteractionSynthesize` call returns paths to a full-size screenshot, a thumbnail, the hierarchy file and the console log. [L]
- **Swift Testing.** Attachments since Swift 6.2, images since Xcode 26.4, but no UI automation and no way to keep attachments conditionally (ST-0018 returned for revision). UI evidence stays in XCTest. [A] https://developer.apple.com/documentation/testing/attachment, https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0018-conditionally-saving-attachments.md

Pattern that makes "I ran it" checkable [I]: one directory per run holding the summary JSON, the attachment manifest and files, the filtered ndjson log, the keyboard identity record from Gap 1 (build stamp, extension pid), the simulator runtime and device type, and the git SHA. A claim in a PR or in `WAVES.md` cites that directory; a reader can open the manifest and see which test produced which screenshot on which keyboard.

## Proposals, ranked

Ordering follows ADR-0010's rule: nothing that types through the simulator is trustworthy until activation and positive detection are solved, so those come first.

| # | What to build | Closes | Effort | Stays device-only |
|---|---|---|---|---|
| 1 | **Keyboard identity gate.** The extension sets one accessibility identifier on its root view and appends a "presented" record (build stamp, pid, timestamp) to the App Group container each time it appears. `launchHostWithKeyboard()` requires both: the identifier in the tree, and a new record from the expected build read via `simctl get_app_container … groups`. Replace the period-key check; fail, do not skip, when it is missing. | Gap 1 (identity) | Half a day | Nothing; the same record is readable on device with `devicectl device copy from` |
| 2 | **Evidence bundle script.** A wrapper around `xcodebuild test-without-building -resultBundlePath` that then runs `xcresulttool get test-results summary` and `export attachments`, captures the filtered log stream, copies the identity record, and writes one directory. Turn on "keep all" screen recording in the ReplayRig test plan. | Gap 5 | Half a day to a day | Device runs use the same script with `devicectl device capture` for video |
| 3 | **Proxy-truth rig.** Extend `ReplayHost` with the four field kinds, each logging true text and selection; add a debug-only proxy-read journal in the extension; a test that types, moves the cursor mid-text, applies a correction and diffs the two logs. First case: reproduce this week's over-delete. Then try Messages, Notes and Safari in the simulator and record a profile per host for `ProxySimulator`. Depends on 1. | Gap 3 | Two to three days | Third-party hosts; Messages with real conversation content |
| 4 | **Touch-path tests with human-shaped taps.** Jitter tap points inside keys with `XCUICoordinate` offsets, add long-press-and-slide with `press(forDuration:thenDragTo:…)`, and cover emoji switch, number pad and the suggestion-bar overlap that produced the three 1.3 regressions. Spike staggered two-finger rollover with Xcode 27's multi-touch command; fall back to WebDriverAgent only if that cannot reach the keys. Depends on 1. | Gap 2 | One to two days; rollover spike half a day | Latency, the system gesture gate, real finger contact size |
| 5 | **Enablement hardening spike.** In one sitting on a scratch simulator: does `pluginkit -m -p com.apple.keyboard-service` list the appex and its election; does enablement survive reinstall without uninstall; does `simctl clone` of an enabled simulator keep the keyboard; why does the Settings test not run on iOS 26.5; does `kbdebug` name the active keyboard process. Keep whichever checks hold. | Gap 1 (enabling) | Half a day | Enabling on a phone is a one-time manual step |
| 6 | **Memory: relative check in the simulator, real check on device.** Simulator: after N present/dismiss cycles, `leaks -outputGraph` on the appex pid and compare `heap` against a baseline. Device: add to `tools/cold-start` a script that lists and copies `JetsamEvent` reports and greps for the extension, and one that sends a memory warning to the extension pid and checks the `MEMORY_WARNING` log line. | Gap 4 | One day | The limit, jetsam, fallback to the system keyboard |
| 7 | **Try Xcode's MCP tools from Claude Code for ad hoc checks.** `claude mcp add --transport stdio xcode -- xcrun mcpbridge`, project open in Xcode, then one device-interaction session against `ReplayHost` to answer the open question about the hierarchy and the keyboard. Not a gate: sessions hold the Xcode UI, and the headless mode is a preview that needs `sudo`. | Gaps 2 and 5 (exploration) | One to two hours | — |

Not proposed: adopting idb, AXe, MobileBuildMCP, Maestro or Appium as the harness. None has evidence for keyboard extensions, the HID-based ones are in the middle of Xcode 27 breakage, and XCUITest already does the part that matters.

## Not established

- Whether any third-party tool's tree dump includes a keyboard appex's elements, and whether its HID touches reach the appex. Needs one empirical run (for idb: `idb ui describe-all --api axbridge --format complete` with the keyboard up, looking for another `pid`).
- Whether Xcode 27's device-interaction hierarchy shows the extension's keys or an `isRemoteLeafPlaceholder`, and whether a session can run with Xcode closed. Apple's public text is one sentence; everything else here is from binary strings. The command letters in the table (`t x y`, `d x y`, `drag …`, `b <button>`, `w <duration>`, `orientation <value>`) are reconstructed from the parser's error strings.
- Whether `xcrun agent skills export` and `xcrun mcpbridge run-agent --dry-run claude` work without further setup. Both are in the Xcode 27.0 help text; here the export wrote no files and the dry run hung until killed (Xcode was running, external-agent access not checked).
- Whether XCUITest still sees the extension's elements and delivers touches on the iOS 26.5 and iOS 27 simulators. All repo evidence is iOS 18.3–18.4.
- Why the Settings enablement test does not run on iOS 26.5.
- Whether `defaults`, `pluginkit -e use` or a cloned simulator can replace the Settings test.
- Whether the Messages compose field accepts typing in the simulator, and whether its proxy behaviour there matches a phone.
- The cause of the iMessage extra character. The Safari report suggests a host-inserted leading character; an object-replacement or invisible character is equally possible. No source settles it.
- The unit of `adjustTextPosition` from Apple; UTF-16 is a community answer.
- Whether `leaks`, `heap`, `footprint` and `xctrace --attach` work against a simulator appex without extra privileges.
- Whether a keyboard extension can register for MetricKit and receive the iOS 27 memory-exception diagnostic.
- Whether `devicectl device capture` works on a locked phone, and which iOS versions it needs.
- The `.xctestplan` key names for automatic screen capture; only the Xcode UI wording is documented.
- Third-party tool facts are as of the commits named; several repos had commits on the day of reading.
