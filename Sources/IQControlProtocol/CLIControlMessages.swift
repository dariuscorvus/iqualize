import Foundation

// MARK: - Request

/// Wire request sent by the `iqualize` CLI to the running app over the control socket.
/// Flat/hand-written rather than a polymorphic enum — simpler to encode/decode/debug
/// for a handful of commands, and easy to extend without breaking older clients.
public struct CLIRequest: Codable, Sendable {
    public var command: String
    public var stringArg: String?
    public var floatArg: Float?
    public var boolArg: Bool?

    public init(command: String, stringArg: String? = nil, floatArg: Float? = nil, boolArg: Bool? = nil) {
        self.command = command
        self.stringArg = stringArg
        self.floatArg = floatArg
        self.boolArg = boolArg
    }
}

public enum CLICommand {
    public static let status = "status"
    public static let listPresets = "listPresets"
    public static let selectPreset = "selectPreset"
    public static let setBypass = "setBypass"
    public static let toggleBypass = "toggleBypass"
    public static let setInputGain = "setInputGain"
    public static let setOutputGain = "setOutputGain"
    public static let setBalance = "setBalance"
}

// MARK: - Response

public struct CLIResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: CLIStatusPayload?
    public var presets: [CLIPresetSummary]?

    public init(ok: Bool, error: String? = nil, status: CLIStatusPayload? = nil, presets: [CLIPresetSummary]? = nil) {
        self.ok = ok
        self.error = error
        self.status = status
        self.presets = presets
    }

    public static func success(status: CLIStatusPayload? = nil, presets: [CLIPresetSummary]? = nil) -> CLIResponse {
        CLIResponse(ok: true, status: status, presets: presets)
    }

    public static func failure(_ message: String) -> CLIResponse {
        CLIResponse(ok: false, error: message)
    }
}

public struct CLIStatusPayload: Codable, Sendable {
    public var bypassed: Bool
    public var activePresetID: UUID
    public var activePresetName: String
    public var inputGainDB: Float
    public var outputGainDB: Float
    public var balance: Float
    public var gainIsGlobal: Bool
    public var outputDeviceName: String
    public var isRunning: Bool

    public init(bypassed: Bool, activePresetID: UUID, activePresetName: String, inputGainDB: Float, outputGainDB: Float, balance: Float, gainIsGlobal: Bool, outputDeviceName: String, isRunning: Bool) {
        self.bypassed = bypassed
        self.activePresetID = activePresetID
        self.activePresetName = activePresetName
        self.inputGainDB = inputGainDB
        self.outputGainDB = outputGainDB
        self.balance = balance
        self.gainIsGlobal = gainIsGlobal
        self.outputDeviceName = outputDeviceName
        self.isRunning = isRunning
    }
}

public struct CLIPresetSummary: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var isBuiltIn: Bool
    public var isFavorite: Bool
    public var isActive: Bool

    public init(id: UUID, name: String, isBuiltIn: Bool, isFavorite: Bool, isActive: Bool) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isFavorite = isFavorite
        self.isActive = isActive
    }
}
