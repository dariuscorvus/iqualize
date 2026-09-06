import Foundation

/// Decides when the realtime spectrum overlay is mounted.
///
/// Spectrum drawing lives in an AppKit timer view (`SpectrumOverlayView`) so
/// refresh does not force `NSHostingView` layout. Background / inactive windows
/// do not mount the overlay and therefore produce no periodic UI frames.
enum EQCanvasRenderPolicy {
    /// Informational — the AppKit overlay uses `SpectrumAnalyzer.targetInterval` (~23.4 Hz).
    static let spectrumFrameInterval: TimeInterval = SpectrumAnalyzer.targetInterval

    static func shouldAnimate(
        windowForeground: Bool,
        engineRunning: Bool,
        preEqEnabled: Bool,
        postEqEnabled: Bool,
        bypassed: Bool
    ) -> Bool {
        guard windowForeground, engineRunning else { return false }
        return preEqEnabled || (postEqEnabled && !bypassed)
    }
}
