// Plays a 997 Hz sine through kAudioUnitSubType_VoiceProcessingIO — the same
// AU FaceTime/WhatsApp/phone-relay use — to reproduce call-audio behavior
// without placing a real call. AGC disabled so the level stays known.
// Usage: vpio_tone [seconds] [amp_dBFS|silent]
import AudioToolbox
import CoreAudio
import Foundation

let seconds = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 6) : 6
nonisolated(unsafe) var amp: Float = powf(10, -30.0 / 20.0)
if CommandLine.arguments.count > 2 {
    if CommandLine.arguments[2] == "silent" {
        amp = 0
    } else if let db = Float(CommandLine.arguments[2]) {
        amp = powf(10, db / 20.0)
    }
}

nonisolated(unsafe) var phase: Double = 0
let freq = 997.0
let sr = 48000.0

let renderCallback: AURenderCallback = { _, _, _, _, frameCount, ioData -> OSStatus in
    guard let ioData else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    let step = 2.0 * Double.pi * freq / sr
    for frame in 0..<Int(frameCount) {
        let sample = amp * Float(sin(phase))
        phase += step
        for buf in buffers {
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = Int(buf.mNumberChannels)
            for c in 0..<ch { data[frame * ch + c] = sample }
        }
    }
    return noErr
}

var desc = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_VoiceProcessingIO,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0, componentFlagsMask: 0)
guard let comp = AudioComponentFindNext(nil, &desc) else {
    FileHandle.standardError.write("no VPIO component\n".data(using: .utf8)!)
    exit(1)
}
var unit: AudioUnit?
var err = AudioComponentInstanceNew(comp, &unit)
guard err == noErr, let au = unit else {
    FileHandle.standardError.write("instantiate failed: \(err)\n".data(using: .utf8)!)
    exit(1)
}

// Enable output (bus 0) and input (bus 1) — a real voice session uses both,
// and the input side is what marks the session as an active call to the OS.
var one: UInt32 = 1
AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, 4)
AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4)

// Known, fixed level: no AGC.
var zero: UInt32 = 0
AudioUnitSetProperty(au, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0, &zero, 4)

var fmt = AudioStreamBasicDescription(
    mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
    mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
err = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                           &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
guard err == noErr else {
    FileHandle.standardError.write("set format failed: \(err)\n".data(using: .utf8)!)
    exit(1)
}
// VPIO refuses to initialize (-10875) unless the mic-side client format
// (output scope, bus 1) is set as well.
err = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                           &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
guard err == noErr else {
    FileHandle.standardError.write("set mic-side format failed: \(err)\n".data(using: .utf8)!)
    exit(1)
}

var cb = AURenderCallbackStruct(inputProc: renderCallback, inputProcRefCon: nil)
AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                     &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

err = AudioUnitInitialize(au)
guard err == noErr else {
    FileHandle.standardError.write("initialize failed: \(err)\n".data(using: .utf8)!)
    exit(1)
}
err = AudioOutputUnitStart(au)
guard err == noErr else {
    FileHandle.standardError.write("start failed: \(err) (mic permission?)\n".data(using: .utf8)!)
    exit(1)
}
print("VPIO session active: \(amp == 0 ? "silent" : "997 Hz tone"), \(seconds)s")
Thread.sleep(forTimeInterval: seconds)
AudioOutputUnitStop(au)
AudioUnitUninitialize(au)
AudioComponentInstanceDispose(au)
