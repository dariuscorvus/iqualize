import XCTest
@testable import iQualize

/// #166 — `PresetImporter` is the only writer into the DSP fed by files the user
/// did not write. Every band it produces must land inside `EQBand.frequencyRange`,
/// `gainRange`, and `bandwidthRange`, whatever the file says.
final class PresetImportClampingTests: XCTestCase {

    private func assertInRange(_ bands: [EQBand], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(bands.isEmpty, "expected at least one band", file: file, line: line)
        for band in bands {
            XCTAssertTrue(band.frequency.isFinite, "frequency not finite: \(band.frequency)", file: file, line: line)
            XCTAssertTrue(band.gain.isFinite, "gain not finite: \(band.gain)", file: file, line: line)
            XCTAssertTrue(band.bandwidth.isFinite, "bandwidth not finite: \(band.bandwidth)", file: file, line: line)
            XCTAssertTrue(EQBand.frequencyRange.contains(band.frequency),
                          "frequency out of range: \(band.frequency)", file: file, line: line)
            XCTAssertTrue(EQBand.gainRange.contains(band.gain),
                          "gain out of range: \(band.gain)", file: file, line: line)
            XCTAssertTrue(EQBand.bandwidthRange.contains(band.bandwidth),
                          "bandwidth out of range: \(band.bandwidth)", file: file, line: line)
        }
    }

    private func parse(_ text: String) throws -> ParsedPreset {
        try PresetImporter.parse(data: Data(text.utf8), filename: "test.txt")
    }

    // MARK: AutoEQ ParametricEQ

    /// The confirmed repro from #166: `Q 0.0` makes `qToOctaves(0) == +Infinity`,
    /// which produces NaN coefficients that latch permanently in the DF2T state.
    func testAutoEQZeroQIsClamped() throws {
        let parsed = try parse("""
        Preamp: -6.0 dB
        Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 0.0
        """)
        assertInRange(parsed.bands)
    }

    func testAutoEQHostileValuesAreClamped() throws {
        let parsed = try parse("""
        Preamp: -6.0 dB
        Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 0.0
        Filter 2: ON PK Fc 1000 Hz Gain 3.0 dB Q -1
        Filter 3: ON PK Fc 0 Hz Gain 3.0 dB Q 1.0
        Filter 4: ON PK Fc 1000000000 Hz Gain 3.0 dB Q 1.0
        Filter 5: ON PK Fc 1000 Hz Gain 1000000 dB Q 1.0
        Filter 6: ON PK Fc -500 Hz Gain -1000000 dB Q 1.0
        Filter 7: ON LSC Fc 105 Hz Gain 400 dB Q 0.0
        """)
        XCTAssertEqual(parsed.bands.count, 7)
        assertInRange(parsed.bands)
    }

    /// A valid AutoEQ file must round-trip untouched — clamping is only for the edges.
    func testAutoEQInRangeValuesAreUnchanged() throws {
        let parsed = try parse("""
        Preamp: -6.7 dB
        Filter 1: ON PK Fc 105 Hz Gain 4.5 dB Q 0.7
        Filter 2: ON PK Fc 2500 Hz Gain -3.2 dB Q 1.4
        """)
        XCTAssertEqual(parsed.bands.count, 2)
        XCTAssertEqual(parsed.bands[0].frequency, 105)
        XCTAssertEqual(parsed.bands[0].gain, 4.5)
        XCTAssertEqual(parsed.bands[0].bandwidth, EQBand.qToOctaves(0.7), accuracy: 1e-6)
        XCTAssertEqual(parsed.bands[1].frequency, 2500)
        XCTAssertEqual(parsed.bands[1].gain, -3.2)
        XCTAssertEqual(parsed.bands[1].bandwidth, EQBand.qToOctaves(1.4), accuracy: 1e-6)
        XCTAssertEqual(parsed.inputGainDB, -6.7)
    }

    /// A file whose every band is hostile must still import rather than throwing —
    /// clamping substitutes, it does not drop.
    func testAutoEQAllBandsHostileStillImports() throws {
        let parsed = try parse("Filter 1: ON PK Fc nan Hz Gain nan dB Q nan")
        assertInRange(parsed.bands)
    }

    /// A non-finite Preamp must not reach the input-gain stage.
    func testAutoEQNonFinitePreampIsDropped() throws {
        let parsed = try parse("""
        Preamp: inf dB
        Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.0
        """)
        if let preamp = parsed.inputGainDB {
            XCTAssertTrue(preamp.isFinite)
        }
    }

    // MARK: AutoEQ GraphicEQ

    func testGraphicEQOutOfRangeGainsAreClamped() throws {
        let parsed = try parse("GraphicEQ: 20 -900.0; 1000 1e9; 20000 -1e9")
        XCTAssertEqual(parsed.bands.count, 31)
        assertInRange(parsed.bands)
    }

    // MARK: OPRA

    func testOPRAZeroAndMissingQAreClamped() throws {
        let json = """
        {"type":"parametric_eq","parameters":{"gain_db":-5.0,"bands":[
          {"type":"peak_dip","frequency":1000,"gain_db":3.0,"q":0},
          {"type":"peak_dip","frequency":2000,"gain_db":3.0},
          {"type":"peak_dip","frequency":1e9,"gain_db":1e6,"q":-2},
          {"type":"low_shelf","frequency":105,"gain_db":4.0,"q":0.7}
        ]}}
        """
        let parsed = try PresetImporter.parse(data: Data(json.utf8), filename: "eq_info.json")
        XCTAssertEqual(parsed.bands.count, 4)
        assertInRange(parsed.bands)
        // The in-range band is untouched.
        XCTAssertEqual(parsed.bands[3].frequency, 105)
        XCTAssertEqual(parsed.bands[3].gain, 4.0)
        XCTAssertEqual(parsed.bands[3].bandwidth, EQBand.qToOctaves(0.7), accuracy: 1e-6)
    }

    // MARK: Native JSON

    func testNativeJSONOutOfRangeBandsAreClamped() throws {
        let json = """
        {"id":"9F1F6B24-0000-4000-8000-000000000000","name":"Hostile","isBuiltIn":false,"bands":[
          {"frequency":1e9,"gain":1e6,"bandwidth":1e9,"filterType":"parametric"},
          {"frequency":-500,"gain":-400,"bandwidth":0,"filterType":"parametric"},
          {"frequency":1000,"gain":3.0,"bandwidth":1.0,"filterType":"parametric"}
        ]}
        """
        let parsed = try PresetImporter.parse(data: Data(json.utf8), filename: "preset.json")
        XCTAssertEqual(parsed.bands.count, 3)
        assertInRange(parsed.bands)
        XCTAssertEqual(parsed.bands[2].frequency, 1000)
        XCTAssertEqual(parsed.bands[2].gain, 3.0)
        XCTAssertEqual(parsed.bands[2].bandwidth, 1.0)
    }

    func testNativeJSONRightChannelBandsAreClamped() throws {
        let json = """
        {"id":"9F1F6B24-0000-4000-8000-000000000001","name":"Split","isBuiltIn":false,
         "bands":[{"frequency":1000,"gain":3.0,"bandwidth":1.0,"filterType":"parametric"}],
         "rightBands":[{"frequency":1e9,"gain":1e6,"bandwidth":0,"filterType":"parametric"}]}
        """
        let parsed = try PresetImporter.parse(data: Data(json.utf8), filename: "preset.json")
        assertInRange(parsed.bands)
        assertInRange(try XCTUnwrap(parsed.rightBands))
    }

    // MARK: End-to-end through the DSP

    /// The whole point: whatever the file says, the chain built from the import
    /// must not produce NaN. 200k samples so a latched NaN cannot hide.
    func testImportedHostilePresetProducesFiniteAudio() throws {
        let parsed = try parse("""
        Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 0.0
        Filter 2: ON PK Fc 1000000000 Hz Gain 1000000 dB Q -1
        Filter 3: ON PK Fc -500 Hz Gain 3.0 dB Q 0
        """)
        for sampleRate in [16000.0, 44100.0, 48000.0, 96000.0] {
            let chain = BiquadFilterChain(bands: parsed.bands, sampleRate: sampleRate)
            var buffer = [Float](repeating: 0, count: 200_000)
            buffer[0] = 1.0
            buffer.withUnsafeMutableBufferPointer { ptr in
                chain.process(ptr.baseAddress!, frameCount: ptr.count)
            }
            XCTAssertTrue(buffer.allSatisfy { $0.isFinite },
                          "non-finite output at \(sampleRate) Hz")
        }
    }
}
