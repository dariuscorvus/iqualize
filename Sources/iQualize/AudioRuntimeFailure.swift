import CoreAudio
import Foundation
import IQCaptureProtocol

/// Presentation-neutral runtime capture failure. The cases are the stable public
/// buckets that UI and automation can switch over without parsing localized text.
/// Associated values keep diagnostics distinguishable without carrying copy.
enum AudioRuntimeFailure: Sendable, Equatable {
    case permissionDenied(PermissionFailure)
    case helperMissing(HelperMissingFailure)
    case helperExited(HelperExitFailure)
    case deviceUnavailable(DeviceUnavailableFailure)
    case transient(TransientFailure)
    case terminal(TerminalFailure)

    enum PermissionFailure: Sendable, Equatable {
        case processTap(status: Int32?)
    }

    struct HelperMissingFailure: Sendable, Equatable {
        let path: String
    }

    struct HelperExitFailure: Sendable, Equatable {
        let status: Int32
        let signaled: Bool
    }

    enum DeviceUnavailableFailure: Sendable, Equatable {
        case defaultOutputNotReady
        case coreAudioStatus(Int32)
    }

    enum TransientFailure: Sendable, Equatable {
        case handshakeTimeout(seconds: Double)
        case handshakeRead(errno: Int32)
        case sharedMemoryOpen(errno: Int32)
        case sharedMemoryStat(errno: Int32)
        case sharedMemoryMap(errno: Int32)
        case sharedMemoryStartup(exitCode: Int32)
    }

    enum TerminalFailure: Sendable, Equatable {
        case malformedHandshake
        case helperStartup(stage: CaptureStartupFailure.Stage, exitCode: Int32, osStatus: Int32?)
        case invalidCaptureGeometry
        case captureProtocolViolation
        case engineUnavailable
        case renderConfiguration
        case unknown
    }
}

enum AudioRuntimeFailureClassifier {
    static func classify(_ error: Error) -> AudioRuntimeFailure {
        if let captureError = error as? CaptureClientError {
            return classify(captureError)
        }
        if let protocolError = error as? CaptureProtocolError {
            return classify(protocolError)
        }

        let nsError = error as NSError
        if nsError.domain == "iQualize" {
            switch nsError.code {
            case -200:
                return .terminal(.engineUnavailable)
            case -201, -202:
                return .terminal(.renderConfiguration)
            case -1:
                return .deviceUnavailable(.coreAudioStatus(Int32(nsError.code)))
            default:
                if nsError.code != 0 {
                    return .deviceUnavailable(.coreAudioStatus(Int32(nsError.code)))
                }
            }
        }

        // Fallback is deliberately terminal instead of retryable. Unknown Error
        // values do not expose a stable machine-readable cause, and treating them
        // as retryable would risk an unbounded recovery loop.
        return .terminal(.unknown)
    }

    static func classify(_ error: CaptureClientError) -> AudioRuntimeFailure {
        switch error {
        case .helperMissing(let path):
            return .helperMissing(.init(path: path))
        case .handshakeTimeout(let seconds):
            return .transient(.handshakeTimeout(seconds: seconds))
        case .malformedHandshake:
            return .terminal(.malformedHandshake)
        case .helperStartupFailed(let failure):
            return classify(failure)
        case .unexpectedExit(let status, let signaled):
            return .helperExited(.init(status: status, signaled: signaled))
        case .handshakeReadFailed(let errno):
            return .transient(.handshakeRead(errno: errno))
        case .sharedMemoryOpenFailed(let errno):
            return .transient(.sharedMemoryOpen(errno: errno))
        case .sharedMemoryStatFailed(let errno):
            return .transient(.sharedMemoryStat(errno: errno))
        case .sharedMemoryMapFailed(let errno):
            return .transient(.sharedMemoryMap(errno: errno))
        }
    }

    static func classify(_ error: CaptureProtocolError) -> AudioRuntimeFailure {
        switch error {
        case .invalidGeometry:
            return .terminal(.invalidCaptureGeometry)
        case .unsupportedLayoutVersion, .mappedHeaderMismatch:
            return .terminal(.captureProtocolViolation)
        }
    }

    static func classify(_ failure: CaptureStartupFailure) -> AudioRuntimeFailure {
        switch failure.stage {
        case .processTap:
            if failure.osStatus == kAudioDevicePermissionsError {
                return .permissionDenied(.processTap(status: failure.osStatus))
            }
            return .terminal(.helperStartup(stage: failure.stage, exitCode: failure.exitCode, osStatus: failure.osStatus))
        case .tapFormat:
            return .terminal(.helperStartup(stage: failure.stage, exitCode: failure.exitCode, osStatus: failure.osStatus))
        case .sharedMemory:
            return .transient(.sharedMemoryStartup(exitCode: failure.exitCode))
        case .aggregateDevice, .ioProc:
            return .deviceUnavailable(.coreAudioStatus(failure.osStatus ?? failure.exitCode))
        case .environment:
            return .terminal(.helperStartup(stage: failure.stage, exitCode: failure.exitCode, osStatus: failure.osStatus))
        }
    }
}
