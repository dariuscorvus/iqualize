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

/// Returns whether Core Audio currently reports the device as alive. This is
/// the same readiness signal used by the capture helper while its aggregate
/// device comes online.
func isAudioDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var alive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(
        deviceID, &address, 0, nil, &size, &alive
    )
    return status == noErr && alive != 0
}

/// Readiness check used by wake recovery. It deliberately does not introduce
/// another fixed delay. The lifecycle coordinator polls this condition with a
/// bounded deadline and starts only after the default output is alive.
func isDefaultOutputDeviceReady() -> Bool {
    guard let deviceID = try? getDefaultOutputDeviceID() else { return false }
    return isAudioDeviceAlive(deviceID)
}

// CoreAudio returns a +1 CFString for the UID/name selectors. Reading it into a
// `var uid: CFString` and passing `&uid` forms a raw pointer to a variable that
// holds an object reference — the compiler warns, and it leaks the retain.
// Reading into an `Unmanaged` and consuming it with takeRetainedValue is the
// correct ownership transfer.
private func getCFStringProperty(
    _ deviceID: AudioDeviceID,
    _ selector: AudioObjectPropertySelector,
    _ message: String
) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try caCheck(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value),
        message
    )
    guard let value else {
        throw NSError(domain: "iQualize", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "\(message): no value returned"])
    }
    return value.takeRetainedValue() as String
}

func getDeviceUID(_ deviceID: AudioDeviceID) throws -> String {
    try getCFStringProperty(deviceID, kAudioDevicePropertyDeviceUID, "Failed to get device UID")
}

func getDeviceName(_ deviceID: AudioDeviceID) throws -> String {
    try getCFStringProperty(deviceID, kAudioObjectPropertyName, "Failed to get device name")
}
