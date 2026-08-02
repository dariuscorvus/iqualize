import Foundation
import IQControlProtocol
import XCTest

@testable import iQualize
@testable import iqualize_cli

final class CLIDirtyPresetTests: XCTestCase {
    func testForceFlagParsesBeforeAndAfterPresetName() throws {
        let beforeName = try PresetCommand.parse(["--force", "Bass Boost"])
        XCTAssertEqual(beforeName.name, "Bass Boost")
        XCTAssertTrue(beforeName.force)

        let afterName = try PresetCommand.parse(["Bass Boost", "--force"])
        XCTAssertEqual(afterName.name, "Bass Boost")
        XCTAssertTrue(afterName.force)
    }

    func testForceFieldRoundTripsAndLegacyRequestsStillDecode() throws {
        let request = CLIRequest(command: CLICommand.selectPreset, stringArg: "Bass Boost", force: true)
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CLIRequest.self, from: encoded)
        XCTAssertEqual(decoded.force, true)

        let legacy = Data(#"{"command":"selectPreset","stringArg":"Flat"}"#.utf8)
        let legacyRequest = try JSONDecoder().decode(CLIRequest.self, from: legacy)
        XCTAssertNil(legacyRequest.force)
    }

    func testPresetSwitchPolicyMatrix() {
        XCTAssertEqual(PresetSwitchPolicy.prompt.decision(isDirty: false), .proceed)
        XCTAssertEqual(PresetSwitchPolicy.prompt.decision(isDirty: true), .prompt)
        XCTAssertEqual(PresetSwitchPolicy.failIfDirty.decision(isDirty: false), .proceed)
        XCTAssertEqual(PresetSwitchPolicy.failIfDirty.decision(isDirty: true), .fail)
        XCTAssertEqual(PresetSwitchPolicy.discard.decision(isDirty: false), .proceed)
        XCTAssertEqual(PresetSwitchPolicy.discard.decision(isDirty: true), .proceed)
    }
}
