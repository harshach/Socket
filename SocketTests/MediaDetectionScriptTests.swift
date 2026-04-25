//
//  MediaDetectionScriptTests.swift
//  SocketTests
//
//  Pins the media-detection JS against three regressions that caused audible
//  YouTube stutter / start-of-video buzz:
//
//    1. The per-element event listener list must not include 'timeupdate'
//       — it fires 4-60Hz during playback with no state-change signal and
//       floods the JS→Swift bridge, starving the WebContent JS thread.
//    2. All checkMediaState wake-ups must go through the coalesced
//       scheduleMediaCheck() helper so bursts collapse to one DOM scan.
//    3. resetSoundTracking (SPA nav) must not force-post {all: false}
//       — that toggled Tab.hasAudioContent.didSet and tore down/rebuilt
//       the Core Audio listener + 1s Timer right as the next video's
//       audio decoder was spinning up.
//    4. Initial DOM-scan wake-ups must be scheduled past the ~0-1s
//       audio-startup window.
//

import XCTest

@testable import Socket

@MainActor
final class MediaDetectionScriptTests: XCTestCase {

    private var script: String!

    override func setUp() {
        super.setUp()
        script = Tab.mediaDetectionScript(handlerSuffix: "TEST-HANDLER")
    }

    // MARK: - Handler wiring

    func test_scriptEmbedsHandlerSuffix() {
        XCTAssertTrue(
            script.contains("mediaStateChange_TEST-HANDLER"),
            "Script must interpolate the handler suffix into the message-handler name"
        )
    }

    // MARK: - Regression: timeupdate flood

    func test_addAudioListeners_doesNotIncludeTimeupdate() {
        // 'timeupdate' should not appear inside any JS array literal. In the
        // event-listener array it would be `'timeupdate',` (middle) or
        // `'timeupdate']` (end). Matching those exact punctuations avoids
        // false-positives from the documenting comment that names the event.
        let message = """
            'timeupdate' must not be registered as a per-element event listener.
            It fires 4-60Hz during playback and caused YouTube audio stutter
            via bridge overhead. The 5s setInterval covers DRM progress polling.
            """
        XCTAssertFalse(script.contains("'timeupdate',"), message)
        XCTAssertFalse(script.contains("'timeupdate']"), message)
    }

    // MARK: - Regression: coalescing

    func test_scriptDefinesScheduleMediaCheck() {
        XCTAssertTrue(
            script.contains("function scheduleMediaCheck(delay)"),
            "Coalescing helper scheduleMediaCheck must be defined"
        )
        XCTAssertTrue(
            script.contains("mediaCheckPending"),
            "Coalescing helper must guard via mediaCheckPending flag"
        )
    }

    func test_noRawSetTimeoutOnCheckMediaState() {
        // Every wake-up of checkMediaState must route through scheduleMediaCheck
        // so bursts of events (e.g. play + loadedmetadata + canplay firing in
        // the same tick) collapse to a single DOM scan + postMessage.
        XCTAssertFalse(
            script.contains("setTimeout(checkMediaState"),
            "All checkMediaState wake-ups must go through scheduleMediaCheck(delay)"
        )
    }

    // MARK: - Regression: SPA-nav false flip

    func test_resetSoundTracking_doesNotForcePostFalseState() {
        // Extract the resetSoundTracking body and verify it doesn't contain
        // a postMessage with hasAudioContent: false. The previous code did:
        //   postMessage({hasAudioContent: false, hasPlayingAudio: false, ...})
        // then scheduleMediaCheck(100) — which re-entered
        // Tab.hasAudioContent.didSet twice within 100ms.
        let body = extractFunctionBody(named: "resetSoundTracking", in: script)
        XCTAssertNotNil(body, "resetSoundTracking must exist in the script")
        guard let body else { return }

        XCTAssertFalse(
            body.contains("hasAudioContent: false"),
            """
            resetSoundTracking must not force-post {hasAudioContent: false} on SPA nav.
            That flip churned Core Audio listener + 1s Timer on every pushState
            and correlated with start-of-video buzz on YouTube Shorts transitions.
            """
        )
        XCTAssertTrue(
            body.contains("scheduleMediaCheck("),
            "resetSoundTracking must still schedule a follow-up check"
        )
    }

    // MARK: - Regression: work scheduled inside audio-startup window

    func test_initialCheckDeferredPastAudioStartupWindow() {
        // The last scheduleMediaCheck(...) call in the IIFE is the initial
        // post-injection kick. It must be >= 1500ms so it lands after
        // WebKit's first-buffer-fill window for video audio.
        guard let lastDelay = lastInitialScheduleDelay(in: script) else {
            XCTFail("Could not find initial scheduleMediaCheck(N) in script")
            return
        }
        XCTAssertGreaterThanOrEqual(
            lastDelay,
            1500,
            """
            Initial scheduleMediaCheck must be deferred past the audio-startup
            window (~0-1s). Running a DOM scan + postMessage inside that
            window correlated with start-of-video mute/crackle.
            """
        )
    }

    func test_setupStreamingSiteMonitoringDeferredPastAudioStartupWindow() {
        guard let delay = delayOfSetTimeout(named: "setupStreamingSiteMonitoring", in: script) else {
            XCTFail("Could not find setTimeout(setupStreamingSiteMonitoring, N)")
            return
        }
        XCTAssertGreaterThanOrEqual(
            delay,
            2000,
            "Streaming-site observer setup must be deferred past the audio-startup window"
        )
    }

    // MARK: - Helpers

    /// Finds `function NAME(...) { ... }` and returns the body up to the
    /// matching brace. Good enough for the single, flat functions in this
    /// script — not a general JS parser.
    private func extractFunctionBody(named name: String, in source: String) -> String? {
        guard let nameRange = source.range(of: "function \(name)(") else { return nil }
        guard let openBrace = source.range(of: "{", range: nameRange.upperBound..<source.endIndex)
        else { return nil }

        var depth = 1
        var idx = openBrace.upperBound
        while idx < source.endIndex && depth > 0 {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1 }
            idx = source.index(after: idx)
        }
        guard depth == 0 else { return nil }
        return String(source[openBrace.upperBound..<source.index(before: idx)])
    }

    /// The initial post-injection wake-up is the last `scheduleMediaCheck(N)`
    /// call in the script (it sits just after the setInterval declaration in
    /// the IIFE footer). Return N.
    private func lastInitialScheduleDelay(in source: String) -> Int? {
        let pattern = "scheduleMediaCheck("
        var searchStart = source.startIndex
        var lastDelay: Int?
        while let hit = source.range(of: pattern, range: searchStart..<source.endIndex) {
            if let close = source.range(of: ")", range: hit.upperBound..<source.endIndex) {
                let arg = source[hit.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
                if let n = Int(arg) {
                    lastDelay = n
                }
                searchStart = close.upperBound
            } else {
                break
            }
        }
        return lastDelay
    }

    /// Returns the N from `setTimeout(NAME, N)`.
    private func delayOfSetTimeout(named name: String, in source: String) -> Int? {
        let pattern = "setTimeout(\(name),"
        guard let hit = source.range(of: pattern) else { return nil }
        guard let close = source.range(of: ")", range: hit.upperBound..<source.endIndex)
        else { return nil }
        let arg = source[hit.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
        return Int(arg)
    }
}
