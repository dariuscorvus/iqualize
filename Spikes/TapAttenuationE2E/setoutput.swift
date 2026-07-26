// Scratch tool: set the default output device by name substring.
// Usage: setoutput <name-substring>   (or no args to list output devices,
//        or --current to print the current default output device name)
import CoreAudio
import Foundation

func propAddress(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func allDevices() -> [AudioObjectID] {
    var addr = propAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceName(_ id: AudioObjectID) -> String {
    var addr = propAddress(kAudioDevicePropertyDeviceNameCFString)
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let err = withUnsafeMutablePointer(to: &name) { ptr in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
    }
    return err == noErr ? (name as String) : "?"
}

func outputChannelCount(_ id: AudioObjectID) -> Int {
    var addr = propAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

let outputs = allDevices().map { (id: $0, name: deviceName($0), ch: outputChannelCount($0)) }
    .filter { $0.ch > 0 }

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--current" {
    var addr = propAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else {
        exit(1)
    }
    print(deviceName(id))
    exit(0)
}

guard CommandLine.arguments.count > 1 else {
    for d in outputs { print("\(d.id)\t\(d.ch)ch\t\(d.name)") }
    exit(0)
}

let query = CommandLine.arguments[1].lowercased()
guard let target = outputs.first(where: { $0.name.lowercased().contains(query) }) else {
    FileHandle.standardError.write("no output device matching \"\(query)\"\n".data(using: .utf8)!)
    exit(1)
}

var addr = propAddress(kAudioHardwarePropertyDefaultOutputDevice)
var id = target.id
let err = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                     UInt32(MemoryLayout<AudioObjectID>.size), &id)
guard err == noErr else {
    FileHandle.standardError.write("set default output failed: OSStatus \(err)\n".data(using: .utf8)!)
    exit(1)
}
print("default output -> \(target.name) (\(target.ch)ch)")
