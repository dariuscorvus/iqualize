import XCTest
import CoreAudio
import IQCaptureProtocol
@testable import iQualize

final class AudioRuntimeFailureClassifierTests: XCTestCase {
    func testClassifiesCaptureClientErrorsWithoutLocalizedDescription() {
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(CaptureClientError.helperMissing(path: "/app/iQualizeCapture")),
            .helperMissing(.init(path: "/app/iQualizeCapture"))
        )
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(CaptureClientError.unexpectedExit(status: 9, signaled: true)),
            .helperExited(.init(status: 9, signaled: true))
        )
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(CaptureClientError.handshakeTimeout(seconds: 1.5)),
            .transient(.handshakeTimeout(seconds: 1.5))
        )
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(CaptureClientError.malformedHandshake),
            .terminal(.malformedHandshake)
        )
    }

    func testClassifiesProcessTapPermissionStatus() {
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(
                CaptureStartupFailure(stage: .processTap, exitCode: 10, osStatus: kAudioDevicePermissionsError)
            ),
            .permissionDenied(.processTap(status: kAudioDevicePermissionsError))
        )
    }

    func testClassifiesProcessTapNonPermissionStatusAsHelperStartup() {
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(
                CaptureStartupFailure(stage: .processTap, exitCode: 10, osStatus: -54)
            ),
            .terminal(.helperStartup(stage: .processTap, exitCode: 10, osStatus: -54))
        )
    }

    func testClassifiesProcessTapNilStatusAsHelperStartup() {
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(
                CaptureStartupFailure(stage: .processTap, exitCode: 10, osStatus: nil)
            ),
            .terminal(.helperStartup(stage: .processTap, exitCode: 10, osStatus: nil))
        )
    }

    func testClassifiesStructuredStartupFailures() {
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(
                CaptureStartupFailure(stage: .aggregateDevice, exitCode: 30, osStatus: -200)
            ),
            .deviceUnavailable(.coreAudioStatus(-200))
        )
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(
                CaptureStartupFailure(stage: .ioProc, exitCode: 40, osStatus: -201)
            ),
            .deviceUnavailable(.coreAudioStatus(-201))
        )
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(
                CaptureStartupFailure(stage: .sharedMemory, exitCode: 20, osStatus: nil)
            ),
            .transient(.sharedMemoryStartup(exitCode: 20))
        )
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(
                CaptureStartupFailure(stage: .tapFormat, exitCode: 11, osStatus: -201)
            ),
            .terminal(.helperStartup(stage: .tapFormat, exitCode: 11, osStatus: -201))
        )
    }

    func testClassifiesCaptureProtocolErrors() {
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(
                CaptureProtocolError.invalidGeometry("channels=0")
            ),
            .terminal(.invalidCaptureGeometry)
        )
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(
                CaptureProtocolError.unsupportedLayoutVersion(received: 2, supported: 1)
            ),
            .terminal(.captureProtocolViolation)
        )
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(
                CaptureProtocolError.mappedHeaderMismatch("header channels=1, handshake=2")
            ),
            .terminal(.captureProtocolViolation)
        )
    }

    func testClassifiesNSErrorFallbacksConservatively() {
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(
                NSError(domain: "iQualize", code: -201, userInfo: [:])
            ),
            .terminal(.renderConfiguration)
        )
        XCTAssertEqual(
            AudioRuntimeFailureClassifier.classify(
                NSError(domain: "Other", code: 1, userInfo: [:])
            ),
            .terminal(.unknown)
        )
    }
}
