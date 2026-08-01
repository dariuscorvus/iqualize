import Foundation
import IQControlProtocol
import XCTest

@testable import iqualize_cli

/// #167: the CLI reported a truncated 127 KB response as "Couldn't reach iQualize. Is it
/// installed?" — after launching a second copy of the app and retrying for five seconds.
/// Only a genuine connection failure may take that path.
final class IQClientRetryTests: XCTestCase {
    private let request = CLIRequest(command: CLICommand.status)

    private func run(
        failures: [IQClientError],
        thenSucceed: Bool = false
    ) throws -> (result: Result<CLIResponse, Error>, attempts: Int, launched: Int) {
        var attempts = 0
        var launched = 0
        var remaining = failures

        let result = Result {
            try IQClient.send(
                request,
                attempt: { _ in
                    attempts += 1
                    if !remaining.isEmpty { throw remaining.removeFirst() }
                    if thenSucceed { return CLIResponse.success() }
                    throw IQClientError.appNotReachable
                },
                launch: { launched += 1 },
                wait: {},
                retries: 3
            )
        }
        return (result, attempts, launched)
    }

    // A decode failure means the app answered. Launching another copy and retrying is wrong.
    func testDecodeFailureDoesNotLaunchOrRetry() throws {
        let decodeError = IQClientError.decodeFailed(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad json")))
        let (result, attempts, launched) = try run(failures: [decodeError])

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(launched, 0)
        guard case .failure(let error) = result, case .decodeFailed = error as? IQClientError else {
            return XCTFail("expected the decode failure to propagate, got \(result)")
        }
    }

    // Same for truncation — the frame came from a running app.
    func testTruncationDoesNotLaunchOrRetry() throws {
        let (result, attempts, launched) = try run(
            failures: [.truncatedResponse(.incomplete(bytesRead: 65_536))])

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(launched, 0)
        guard case .failure(let error) = result,
              case .truncatedResponse = error as? IQClientError else {
            return XCTFail("expected the truncation error to propagate, got \(result)")
        }
    }

    // The app genuinely not being reachable is still worth a launch and a few retries.
    func testConnectionFailureLaunchesAndRetries() throws {
        let (result, attempts, launched) = try run(
            failures: [.appNotReachable, .appNotReachable], thenSucceed: true)

        XCTAssertEqual(launched, 1)
        XCTAssertEqual(attempts, 3)
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
    }

    // Exhausting the retries reports the connection failure, as before.
    func testExhaustedRetriesReportsNotReachable() throws {
        let (result, _, launched) = try run(failures: [])
        XCTAssertEqual(launched, 1)
        guard case .failure(let error) = result,
              case .appNotReachable = error as? IQClientError else {
            return XCTFail("expected appNotReachable, got \(result)")
        }
    }
}
