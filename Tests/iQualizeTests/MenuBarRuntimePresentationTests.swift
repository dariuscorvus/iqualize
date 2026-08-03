import XCTest
@testable import iQualize

final class MenuBarRuntimePresentationTests: XCTestCase {
    func testMapsAllLifecycleStatesToStablePresentation() {
        let active = presentation(.running, userEnabled: true, bypassed: false)
        XCTAssertEqual(active.status, .active)
        XCTAssertEqual(active.title, "Status: Active")
        XCTAssertEqual(active.symbolName, "slider.vertical.3")
        XCTAssertFalse(active.appearsDisabled)

        let bypassed = presentation(.running, userEnabled: true, bypassed: true)
        XCTAssertEqual(bypassed.status, .bypassed)
        XCTAssertEqual(bypassed.title, "Status: Bypassed")
        XCTAssertEqual(bypassed.symbolName, "speaker.slash")
        XCTAssertFalse(bypassed.appearsDisabled)

        let stopped = presentation(.inactive, userEnabled: false, bypassed: false)
        XCTAssertEqual(stopped.status, .stopped)
        XCTAssertEqual(stopped.title, "Status: Off")
        XCTAssertEqual(stopped.symbolName, "pause.circle")
        XCTAssertTrue(stopped.appearsDisabled)

        let userEnabledStopped = presentation(.inactive, userEnabled: true, bypassed: false)
        XCTAssertEqual(userEnabledStopped.title, "Status: Stopped")

        XCTAssertEqual(presentation(.starting).status, .starting)
        XCTAssertEqual(presentation(.starting).title, "Status: Starting")
        XCTAssertEqual(presentation(.starting).symbolName, "arrow.triangle.2.circlepath")
        XCTAssertFalse(presentation(.starting).appearsDisabled)

        XCTAssertEqual(presentation(.recovering).status, .recovering)
        XCTAssertEqual(presentation(.recovering).title, "Status: Recovering")
        XCTAssertEqual(presentation(.recovering).symbolName, "arrow.clockwise.circle")
        XCTAssertFalse(presentation(.recovering).appearsDisabled)

        XCTAssertEqual(presentation(.sleeping).status, .sleeping)
        XCTAssertEqual(presentation(.sleeping).title, "Status: Sleeping")
        XCTAssertEqual(presentation(.sleeping).symbolName, "moon.zzz")
        XCTAssertTrue(presentation(.sleeping).appearsDisabled)

        XCTAssertEqual(presentation(.stopping).status, .stopping)
        XCTAssertEqual(presentation(.stopping).title, "Status: Stopping")
        XCTAssertEqual(presentation(.stopping).symbolName, "stop.circle")
        XCTAssertTrue(presentation(.stopping).appearsDisabled)
    }

    func testFailureTakesPrecedenceOverBypassAndDoesNotExposeDiagnostics() {
        let result = presentation(
            .failed,
            userEnabled: true,
            bypassed: true,
            failure: .helperMissing(.init(path: "/Applications/iQualize.app/Contents/MacOS/iQualizeCapture"))
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.title, "Status: Capture Helper Missing")
        XCTAssertEqual(result.accessibilityLabel, "iQualize capture helper missing")
        XCTAssertEqual(result.symbolName, "exclamationmark.triangle")
        XCTAssertFalse(result.appearsDisabled)
        XCTAssertFalse(result.title.contains("/Applications"))
        XCTAssertFalse(result.accessibilityLabel.contains("/Applications"))
    }

    func testRetryAffordanceOnlyAppearsForRetryableFailedStates() {
        XCTAssertTrue(presentation(.failed, failure: .transient(.handshakeTimeout(seconds: 30))).showsRetryCapture)
        XCTAssertTrue(presentation(.failed, failure: .deviceUnavailable(.coreAudioStatus(-200))).showsRetryCapture)
        XCTAssertTrue(presentation(.failed, failure: .helperExited(.init(status: 9, signaled: true))).showsRetryCapture)

        XCTAssertTrue(presentation(.failed, failure: .permissionDenied(.processTap(status: -54))).showsRetryCapture)
        XCTAssertFalse(presentation(.failed, failure: .helperMissing(.init(path: "/tmp/helper"))).showsRetryCapture)
        XCTAssertFalse(presentation(.failed, failure: .terminal(.unknown)).showsRetryCapture)
        XCTAssertFalse(presentation(.recovering, failure: .transient(.handshakeTimeout(seconds: 30))).showsRetryCapture)
    }

    func testPermissionSettingsAffordanceOnlyAppearsForPermissionDeniedFailure() {
        let permission = presentation(.failed, failure: .permissionDenied(.processTap(status: -54)))
        XCTAssertTrue(permission.showsPermissionSettings)
        XCTAssertEqual(permission.title, "Status: Audio Capture Permission Needed")
        XCTAssertFalse(permission.title.contains("-54"))
        XCTAssertFalse(permission.accessibilityLabel.contains("-54"))

        XCTAssertFalse(presentation(.failed, failure: .transient(.handshakeRead(errno: 54))).showsPermissionSettings)
        XCTAssertFalse(presentation(.failed, failure: .terminal(.helperStartup(stage: .environment, exitCode: 2, osStatus: -1))).showsPermissionSettings)
    }

    private func presentation(
        _ lifecycleState: AudioLifecycleState,
        userEnabled: Bool = true,
        bypassed: Bool = false,
        failure: AudioRuntimeFailure? = nil
    ) -> MenuBarRuntimePresentation {
        MenuBarRuntimePresentation.make(
            lifecycleState: lifecycleState,
            userEnabled: userEnabled,
            bypassed: bypassed,
            lastFailure: failure
        )
    }
}
