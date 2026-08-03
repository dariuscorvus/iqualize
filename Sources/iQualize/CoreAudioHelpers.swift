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

func getDeviceNominalSampleRate(_ deviceID: AudioDeviceID) throws -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var sampleRate = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    try caCheck(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate),
        "Failed to get device nominal sample rate"
    )
    return sampleRate
}

func getDeviceOutputChannelCount(_ deviceID: AudioDeviceID) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    try caCheck(
        AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
        "Failed to get device output stream configuration size"
    )
    let bufferListPointer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { bufferListPointer.deallocate() }
    try caCheck(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer),
        "Failed to get device output stream configuration"
    )
    let bufferList = UnsafeMutableAudioBufferListPointer(
        bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
    )
    return bufferList.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
}

func getDefaultOutputDevice() throws -> CoreAudioOutputDevice {
    let deviceID = try getDefaultOutputDeviceID()
    return CoreAudioOutputDevice(
        id: deviceID,
        name: try getDeviceName(deviceID),
        uid: try? getDeviceUID(deviceID),
        nominalSampleRate: try? getDeviceNominalSampleRate(deviceID),
        outputChannelCount: try? getDeviceOutputChannelCount(deviceID)
    )
}
