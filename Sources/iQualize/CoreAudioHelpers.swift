import CoreAudio

func caCheck(_ status: OSStatus, _ message: String) throws {
    guard status == noErr else {
        throw NSError(domain: "iQualize", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "\(message): OSStatus \(status)"])
    }
}

func getDefaultOutputDeviceID() throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    try caCheck(
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil, &size, &deviceID),
        "Failed to get default output device"
    )
    return deviceID
}

func getDeviceUID(_ deviceID: AudioDeviceID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    try caCheck(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid),
        "Failed to get device UID"
    )
    return uid as String
}

/// All Core Audio process objects currently known to the HAL (one per process with an
/// open audio client) — used to detect newly-launched apps that need to be captured by
/// an already-running global process tap.
func getProcessObjectList() throws -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    try caCheck(
        AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size),
        "Failed to get process object list size"
    )
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }
    var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
    try caCheck(
        AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids),
        "Failed to get process object list"
    )
    return ids
}

func getDeviceName(_ deviceID: AudioDeviceID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    try caCheck(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name),
        "Failed to get device name"
    )
    return name as String
}
