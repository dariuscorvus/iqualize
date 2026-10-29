import XCTest
@testable import iQualize

@MainActor
final class DockPolicyControllerTests: XCTestCase {
    func testLivePreferenceControlsBothDirections() throws {
        try DockPolicyTestScenarios.livePreferenceControlsBothDirections()
    }

    func testMatchingPoliciesSkipSetter() throws {
        try DockPolicyTestScenarios.matchingPoliciesSkipSetter()
    }

    func testReopenRepairsPolicyDriftWithoutChangingIntent() throws {
        try DockPolicyTestScenarios.reopenRepairsPolicyDriftWithoutChangingIntent()
    }

    func testFailedSetterPreservesIntentAndReportsFailure() throws {
        try DockPolicyTestScenarios.failedSetterPreservesIntentAndReportsFailure()
    }

    func testSetterResultAndObservedPolicyRemainDistinct() throws {
        try DockPolicyTestScenarios.setterResultAndObservedPolicyRemainDistinct()
    }
}
