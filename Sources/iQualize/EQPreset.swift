import Foundation

// MARK: - State Persistence

struct iQualizeState: Codable {
    var isEnabled: Bool
    var selectedPresetID: UUID
    var peakLimiter: Bool
    var windowOpen: Bool
    var maxGainDB: Float
    var bypassed: Bool
    var autoScale: Bool
    var preEqSpectrumEnabled: Bool
    var postEqSpectrumEnabled: Bool
    var hideFromDock: Bool
    var startAtLogin: Bool
    var balance: Float
    var splitChannelEnabled: Bool
    var activeChannel: String?
    var inputGainDB: Float
    var outputGainDB: Float
    /// When true, `inputGainDB`/`outputGainDB` above are shared across all presets.
    /// When false, gain is read from/written to the active EQPresetData instead.
    var linkGainGlobally: Bool
    var showBandwidthAsQ: Bool
    /// User-picked Pre-EQ line color as `#RRGGBB` (sRGB). nil = use the dynamic system color.
    var preEqLineColorHex: String?
    /// User-picked Post-EQ line color as `#RRGGBB` (sRGB). nil = use the dynamic system color.
    var postEqLineColorHex: String?
    /// User-picked Pre-EQ fill color as `#RRGGBB` (sRGB). nil = use the dynamic system color.
    var preEqFillColorHex: String?
    /// User-picked Post-EQ fill color as `#RRGGBB` (sRGB). nil = use the dynamic system color.
    var postEqFillColorHex: String?
    var preEqFillEnabled: Bool
    var postEqFillEnabled: Bool
    /// Dream UI theme: "auto" | "light" | "dark". Nil = follow system (auto).
    var dreamTheme: String?
    /// Snap newly-dragged band frequencies to musical semitones.
    var snapToSemitone: Bool

    static let defaultState = iQualizeState(
        isEnabled: false,
        selectedPresetID: EQPresetData.flat.id,
        peakLimiter: true,
        windowOpen: false,
        maxGainDB: 12,
        bypassed: false,
        autoScale: true,
        preEqSpectrumEnabled: false,
        postEqSpectrumEnabled: false,
        hideFromDock: false,
        startAtLogin: false,
        balance: 0.0,
        splitChannelEnabled: false,
        activeChannel: nil,
        inputGainDB: 0.0,
        outputGainDB: 0.0,
        linkGainGlobally: false,
        showBandwidthAsQ: true,
        preEqFillEnabled: false,
        postEqFillEnabled: true,
        dreamTheme: nil,
        snapToSemitone: false
    )

    private static let key = "com.iqualize.state"

    init(isEnabled: Bool, selectedPresetID: UUID, peakLimiter: Bool, windowOpen: Bool = false, maxGainDB: Float = 12, bypassed: Bool = false, autoScale: Bool = true, preEqSpectrumEnabled: Bool = false, postEqSpectrumEnabled: Bool = false, hideFromDock: Bool = false, startAtLogin: Bool = false, balance: Float = 0.0, splitChannelEnabled: Bool = false, activeChannel: String? = nil, inputGainDB: Float = 0.0, outputGainDB: Float = 0.0, linkGainGlobally: Bool = false, showBandwidthAsQ: Bool = true, preEqLineColorHex: String? = nil, postEqLineColorHex: String? = nil, preEqFillColorHex: String? = nil, postEqFillColorHex: String? = nil, preEqFillEnabled: Bool = false, postEqFillEnabled: Bool = true, dreamTheme: String? = nil, snapToSemitone: Bool = false) {
        self.isEnabled = isEnabled
        self.selectedPresetID = selectedPresetID
        self.peakLimiter = peakLimiter
        self.windowOpen = windowOpen
        self.maxGainDB = maxGainDB
        self.bypassed = bypassed
        self.autoScale = autoScale
        self.preEqSpectrumEnabled = preEqSpectrumEnabled
        self.postEqSpectrumEnabled = postEqSpectrumEnabled
        self.hideFromDock = hideFromDock
        self.startAtLogin = startAtLogin
        self.balance = balance
        self.splitChannelEnabled = splitChannelEnabled
        self.activeChannel = activeChannel
        self.inputGainDB = inputGainDB
        self.outputGainDB = outputGainDB
        self.linkGainGlobally = linkGainGlobally
        self.showBandwidthAsQ = showBandwidthAsQ
        self.preEqLineColorHex = preEqLineColorHex
        self.postEqLineColorHex = postEqLineColorHex
        self.preEqFillColorHex = preEqFillColorHex
        self.postEqFillColorHex = postEqFillColorHex
        self.preEqFillEnabled = preEqFillEnabled
        self.postEqFillEnabled = postEqFillEnabled
        self.dreamTheme = dreamTheme
        self.snapToSemitone = snapToSemitone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? false
        selectedPresetID = (try? container.decode(UUID.self, forKey: .selectedPresetID)) ?? EQPresetData.flat.id
        peakLimiter = (try? container.decode(Bool.self, forKey: .peakLimiter)) ?? true
        windowOpen = (try? container.decode(Bool.self, forKey: .windowOpen)) ?? false
        maxGainDB = (try? container.decode(Float.self, forKey: .maxGainDB)) ?? 12
        bypassed = (try? container.decode(Bool.self, forKey: .bypassed)) ?? false
        autoScale = (try? container.decode(Bool.self, forKey: .autoScale)) ?? true
        preEqSpectrumEnabled = (try? container.decode(Bool.self, forKey: .preEqSpectrumEnabled)) ?? false
        postEqSpectrumEnabled = (try? container.decode(Bool.self, forKey: .postEqSpectrumEnabled)) ?? false
        hideFromDock = (try? container.decode(Bool.self, forKey: .hideFromDock)) ?? false
        startAtLogin = (try? container.decode(Bool.self, forKey: .startAtLogin)) ?? false
        balance = (try? container.decode(Float.self, forKey: .balance)) ?? 0.0
        splitChannelEnabled = (try? container.decode(Bool.self, forKey: .splitChannelEnabled)) ?? false
        activeChannel = try? container.decode(String.self, forKey: .activeChannel)
        inputGainDB = (try? container.decode(Float.self, forKey: .inputGainDB)) ?? 0.0
        outputGainDB = (try? container.decode(Float.self, forKey: .outputGainDB)) ?? 0.0
        linkGainGlobally = (try? container.decode(Bool.self, forKey: .linkGainGlobally)) ?? false
        showBandwidthAsQ = (try? container.decode(Bool.self, forKey: .showBandwidthAsQ)) ?? true
        preEqLineColorHex = try? container.decode(String.self, forKey: .preEqLineColorHex)
        postEqLineColorHex = try? container.decode(String.self, forKey: .postEqLineColorHex)
        preEqFillColorHex = try? container.decode(String.self, forKey: .preEqFillColorHex)
        postEqFillColorHex = try? container.decode(String.self, forKey: .postEqFillColorHex)
        preEqFillEnabled = (try? container.decode(Bool.self, forKey: .preEqFillEnabled)) ?? false
        postEqFillEnabled = (try? container.decode(Bool.self, forKey: .postEqFillEnabled)) ?? true
        dreamTheme = try? container.decode(String.self, forKey: .dreamTheme)
        snapToSemitone = (try? container.decode(Bool.self, forKey: .snapToSemitone)) ?? false
    }

    static func load() -> iQualizeState {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(iQualizeState.self, from: data) else {
            return .defaultState
        }
        return state
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: iQualizeState.key)
        }
    }
}
