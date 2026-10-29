import AVFAudio
import AudioToolbox
import Foundation

/// Configure the native portion of the linked-channel EQ.
func configureNativeEQBands(_ eq: AVAudioUnitEQ, bands: [EQBand], oldBands: [EQBand]?) {
    let newCount = min(bands.count, eq.bands.count)
    let oldCount = min(oldBands?.count ?? 0, eq.bands.count)
    func setGain(_ gain: Float, at index: Int) {
        // AVAudioUnitEQFilterParameters.gain can apply the old value when a
        // band changes filter type. Write the same native unit parameter
        // directly so the requested gain takes effect with the new type.
        let status = AudioUnitSetParameter(eq.audioUnit, AudioUnitParameterID(kAUNBandEQParam_Gain + UInt32(index)), kAudioUnitScope_Global, 0, gain, 0)
        if status != noErr {
            NSLog("iQualize: failed to set native EQ band %d gain (OSStatus %d); falling back to AVAudioUnitEQ", index, status)
            eq.bands[index].gain = gain
        }
    }
    for i in 0..<newCount {
        let band = bands[i]
        let eqBand = eq.bands[i]
        let gain = band.muted ? 0 : band.gain
        if i >= oldCount {
            eqBand.filterType = band.filterType.avType
            eqBand.frequency = band.frequency
            eqBand.bandwidth = band.bandwidth
            setGain(gain, at: i)
            eqBand.bypass = band.muted
        } else if let oldBand = oldBands?[i] {
            if band.filterType != oldBand.filterType { eqBand.filterType = band.filterType.avType }
            if band.frequency != oldBand.frequency { eqBand.frequency = band.frequency }
            if band.filterType != oldBand.filterType || gain != (oldBand.muted ? 0 : oldBand.gain) {
                setGain(gain, at: i)
            }
            if band.bandwidth != oldBand.bandwidth { eqBand.bandwidth = band.bandwidth }
            if band.muted != oldBand.muted { eqBand.bypass = band.muted }
        }
    }
    if newCount < eq.bands.count {
        for i in newCount..<eq.bands.count { eq.bands[i].bypass = true }
    }
}
