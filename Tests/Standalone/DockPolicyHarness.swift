import Foundation

// Run without XCTest on a CLT-only machine. Compile this with the production
// EQModels, EQPreset, SettingsStore, DockPolicyController and shared scenarios,
// using -D DOCK_POLICY_STANDALONE to omit the XCTest target's module import.
@main
struct DockPolicyHarness {
    @MainActor
    static func main() throws {
        try DockPolicyTestScenarios.livePreferenceControlsBothDirections()
        print("PASS: live preference controls both hide/show directions")
        try DockPolicyTestScenarios.matchingPoliciesSkipSetter()
        print("PASS: matching policies skip setter and preserve settings")
        try DockPolicyTestScenarios.failedSetterPreservesIntentAndReportsFailure()
        print("PASS: failed setters report failure and preserve persisted intent in both directions")
        try DockPolicyTestScenarios.setterResultAndObservedPolicyRemainDistinct()
        print("PASS: setter API result remains distinct from immediate observed policy")
    }
}
