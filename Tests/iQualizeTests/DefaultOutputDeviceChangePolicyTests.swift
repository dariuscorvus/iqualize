import XCTest
@testable import iQualize

final class DefaultOutputDeviceChangePolicyTests: XCTestCase {
    func testSameUIDDoesNotCountAsADeviceChange() {
        XCTAssertFalse(defaultOutputDeviceChanged(previousUID: "built-in-output", currentUID: "built-in-output"))
    }

    func testNewUIDCountsAsADeviceChange() {
        XCTAssertTrue(defaultOutputDeviceChanged(previousUID: "built-in-output", currentUID: "usb-dac"))
    }

    func testFirstKnownUIDCountsAsADeviceChange() {
        XCTAssertTrue(defaultOutputDeviceChanged(previousUID: nil, currentUID: "built-in-output"))
    }

    func testUnknownCurrentUIDDoesNotCountAsADeviceChange() {
        XCTAssertFalse(defaultOutputDeviceChanged(previousUID: "built-in-output", currentUID: nil))
        XCTAssertFalse(defaultOutputDeviceChanged(previousUID: nil, currentUID: nil))
    }
}
