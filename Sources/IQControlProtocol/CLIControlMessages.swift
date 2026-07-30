import Foundation

// MARK: - Request

/// Wire request sent by the `iqualize` CLI to the running app over the control socket.
/// Flat/hand-written rather than a polymorphic enum — simpler to encode/decode/debug
/// for a handful of commands, and easy to extend without breaking older clients.
public struct CLIRequest: Codable, Sendable {
    public var command: String
    public var stringArg: String?
    /// Second string slot — rename old->new, duplicate source->newName, export name->outputPath.
    public var stringArg2: String?
    public var floatArg: Float?
    public var boolArg: Bool?
    public var bandArgs: CLIBandArgs?

    public init(command: String, stringArg: String? = nil, stringArg2: String? = nil, floatArg: Float? = nil, boolArg: Bool? = nil, bandArgs: CLIBandArgs? = nil) {
        self.command = command
        self.stringArg = stringArg
        self.stringArg2 = stringArg2
        self.floatArg = floatArg
        self.boolArg = boolArg
        self.bandArgs = bandArgs
    }
}

/// Structured payload for band commands — too many simultaneous optional values for the
/// flat scalar request fields above.
public struct CLIBandArgs: Codable, Sendable {
    /// 1-based, sorted-by-frequency addressing.
    public var index: Int?
    /// Nearest-frequency-match addressing — mutually exclusive with `index`.
    public var matchFrequency: Float?
    /// New value (add/set).
    public var frequency: Float?
    public var gain: Float?
    public var bandwidth: Float?
    /// `FilterType.rawValue` (add/set).
    public var filterType: String?
    /// "left" | "right" (move only).
    public var direction: String?

    public init(index: Int? = nil, matchFrequency: Float? = nil, frequency: Float? = nil, gain: Float? = nil, bandwidth: Float? = nil, filterType: String? = nil, direction: String? = nil) {
        self.index = index
        self.matchFrequency = matchFrequency
        self.frequency = frequency
        self.gain = gain
        self.bandwidth = bandwidth
        self.filterType = filterType
        self.direction = direction
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
    public static let setPeakLimiter = "setPeakLimiter"
    public static let togglePeakLimiter = "togglePeakLimiter"
    public static let setGainIsGlobal = "setGainIsGlobal"
    public static let toggleGainIsGlobal = "toggleGainIsGlobal"
    public static let setPreEqSpectrum = "setPreEqSpectrum"
    public static let togglePreEqSpectrum = "togglePreEqSpectrum"
    public static let setPostEqSpectrum = "setPostEqSpectrum"
    public static let togglePostEqSpectrum = "togglePostEqSpectrum"
    public static let setCapture = "setCapture"
    public static let toggleCapture = "toggleCapture"

    // Band editing
    public static let listBands = "listBands"
    public static let addBand = "addBand"
    public static let deleteBand = "deleteBand"
    public static let setBand = "setBand"
    public static let moveBand = "moveBand"
    public static let setBandMute = "setBandMute"
    public static let toggleBandMute = "toggleBandMute"

    // Preset lifecycle
    public static let saveActivePreset = "saveActivePreset"
    public static let resetActivePreset = "resetActivePreset"
    public static let deletePreset = "deletePreset"
    public static let newPreset = "newPreset"
    public static let renamePreset = "renamePreset"
    public static let duplicatePreset = "duplicatePreset"
    public static let setFavoritePreset = "setFavoritePreset"
    public static let toggleFavoritePreset = "toggleFavoritePreset"
    public static let pinPreset = "pinPreset"
    public static let unpinPreset = "unpinPreset"
    public static let listHiddenPresets = "listHiddenPresets"
    public static let restoreBuiltInPreset = "restoreBuiltInPreset"

    // Import/export
    public static let importPresetFile = "importPresetFile"
    public static let exportPreset = "exportPreset"

    // OPRA catalog
    public static let searchOPRA = "searchOPRA"
    public static let importOPRA = "importOPRA"
}

// MARK: - Response

public struct CLIResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: CLIStatusPayload?
    public var presets: [CLIPresetSummary]?
    public var bands: [CLIBandSummary]?
    public var opraProducts: [CLIOPRAProductSummary]?

    public init(ok: Bool, error: String? = nil, status: CLIStatusPayload? = nil, presets: [CLIPresetSummary]? = nil, bands: [CLIBandSummary]? = nil, opraProducts: [CLIOPRAProductSummary]? = nil) {
        self.ok = ok
        self.error = error
        self.status = status
        self.presets = presets
        self.bands = bands
        self.opraProducts = opraProducts
    }

    public static func success(status: CLIStatusPayload? = nil, presets: [CLIPresetSummary]? = nil, bands: [CLIBandSummary]? = nil, opraProducts: [CLIOPRAProductSummary]? = nil) -> CLIResponse {
        CLIResponse(ok: true, status: status, presets: presets, bands: bands, opraProducts: opraProducts)
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
    public var peakLimiter: Bool
    public var preEqSpectrumEnabled: Bool
    public var postEqSpectrumEnabled: Bool
    /// App version (CFBundleShortVersionString). Optional so a newer CLI still decodes
    /// responses from an older app that doesn't send it.
    public var appVersion: String?
    /// Git commit the app was built from (IQGitCommit, stamped by install.sh).
    /// nil for unstamped builds (e.g. plain `swift build` outside a git checkout).
    public var gitCommit: String?

    public init(bypassed: Bool, activePresetID: UUID, activePresetName: String, inputGainDB: Float, outputGainDB: Float, balance: Float, gainIsGlobal: Bool, outputDeviceName: String, isRunning: Bool, peakLimiter: Bool, preEqSpectrumEnabled: Bool, postEqSpectrumEnabled: Bool, appVersion: String? = nil, gitCommit: String? = nil) {
        self.bypassed = bypassed
        self.activePresetID = activePresetID
        self.activePresetName = activePresetName
        self.inputGainDB = inputGainDB
        self.outputGainDB = outputGainDB
        self.balance = balance
        self.gainIsGlobal = gainIsGlobal
        self.outputDeviceName = outputDeviceName
        self.isRunning = isRunning
        self.peakLimiter = peakLimiter
        self.preEqSpectrumEnabled = preEqSpectrumEnabled
        self.postEqSpectrumEnabled = postEqSpectrumEnabled
        self.appVersion = appVersion
        self.gitCommit = gitCommit
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

public struct CLIBandSummary: Codable, Sendable {
    /// 1-based, sorted-by-frequency — matches the order the GUI displays bands in.
    public var index: Int
    public var frequency: Float
    public var gain: Float
    public var bandwidth: Float
    /// `FilterType.rawValue`.
    public var filterType: String
    public var muted: Bool

    public init(index: Int, frequency: Float, gain: Float, bandwidth: Float, filterType: String, muted: Bool) {
        self.index = index
        self.frequency = frequency
        self.gain = gain
        self.bandwidth = bandwidth
        self.filterType = filterType
        self.muted = muted
    }
}

public struct CLIOPRAProductSummary: Codable, Sendable {
    public var id: String
    public var vendorName: String
    public var productName: String
    public var curveAuthors: [String]

    public init(id: String, vendorName: String, productName: String, curveAuthors: [String]) {
        self.id = id
        self.vendorName = vendorName
        self.productName = productName
        self.curveAuthors = curveAuthors
    }
}
