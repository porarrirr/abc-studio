import XCTest
import AVFoundation
@testable import ABCStudio

final class SpatialAudioTests: XCTestCase {
    private func signal(impulse: Bool = false, frequency: Double = 440) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for i in 0..<4410 {
            let value: Float = impulse ? (i == 0 ? 0.5 : 0) : Float(sin(Double(i) * 2 * .pi * frequency / 44100)) * 0.5
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
        }
        return buffer
    }

    private func energy(_ buffer: AVAudioPCMBuffer, channel: Int) -> Double {
        (0..<Int(buffer.frameLength)).reduce(0) {
            $0 + pow(Double(buffer.floatChannelData![channel][$1]), 2)
        }
    }

    func testMirroredPlacementSwapsChannelsAndPreservesSource() {
        let source = signal()
        let original = source.floatChannelData![0][123]
        let renderer = OrchestraSpatializer()
        let reference = HeadphoneSettings(profile: .reference)
        let left = renderer.render(source, at: StagePosition(x: -0.8, depth: 0.2), settings: reference)
        let right = renderer.render(source, at: StagePosition(x: 0.8, depth: 0.2), settings: reference)
        XCTAssertGreaterThan(energy(left, channel: 0), energy(left, channel: 1) * 3)
        for i in 0..<Int(left.frameLength) {
            XCTAssertEqual(left.floatChannelData![0][i], right.floatChannelData![1][i], accuracy: 1e-6)
            XCTAssertEqual(left.floatChannelData![1][i], right.floatChannelData![0][i], accuracy: 1e-6)
        }
        XCTAssertEqual(source.floatChannelData![0][123], original)
        XCTAssertTrue(left === renderer.render(source, at: StagePosition(x: -0.8, depth: 0.2), settings: reference))
    }

    func testFarEarArrivalIsDelayedButCenterIsAligned() {
        let renderer = OrchestraSpatializer()
        let reference = HeadphoneSettings(profile: .reference)
        let source = signal(impulse: true)
        let right = renderer.render(source, at: StagePosition(x: 1, depth: 0), settings: reference)
        func firstSound(_ buffer: AVAudioPCMBuffer, _ channel: Int) -> Int {
            (0..<Int(buffer.frameLength)).first { abs(buffer.floatChannelData![channel][$0]) > 0.0001 }!
        }
        let difference = firstSound(right, 0) - firstSound(right, 1)
        XCTAssertGreaterThan(difference, 15)
        XCTAssertLessThanOrEqual(difference, 29)
        let center = renderer.render(source, at: StagePosition(x: 0, depth: 0), settings: reference)
        XCTAssertEqual(firstSound(center, 0), firstSound(center, 1))
        XCTAssertEqual(energy(center, channel: 0), energy(center, channel: 1), accuracy: 1e-8)
    }

    func testDepthReducesLevelAndHighFrequencyEnergy() {
        let renderer = OrchestraSpatializer()
        let reference = HeadphoneSettings(profile: .reference)
        let low = signal(frequency: 220)
        let high = signal(frequency: 12000)
        let front = StagePosition(x: 0, depth: 0)
        let back = StagePosition(x: 0, depth: 1)
        let lowRatio = energy(renderer.render(low, at: back, settings: reference), channel: 0) / energy(renderer.render(low, at: front, settings: reference), channel: 0)
        let highRatio = energy(renderer.render(high, at: back, settings: reference), channel: 0) / energy(renderer.render(high, at: front, settings: reference), channel: 0)
        XCTAssertLessThan(lowRatio, 0.8)
        XCTAssertGreaterThan(lowRatio, 0.3, "Distant sections must remain audible")
        XCTAssertLessThan(highRatio, lowRatio)
    }

    func testOrchestralDefaultsAndInvalidCoordinates() {
        func position(_ id: String, _ name: String = "") -> StagePosition {
            .orchestral(instrument: Instruments.byID(id)!, partName: name)
        }
        XCTAssertLessThan(position("violin", "Violin I").x, position("violin", "Violin II").x)
        XCTAssertEqual(position("violin", "Violin II"), position("violin", "第2バイオリン"))
        XCTAssertGreaterThan(position("cello").x, 0)
        XCTAssertGreaterThan(position("contrabass").depth, position("cello").depth)
        XCTAssertGreaterThan(position("trumpet").depth, position("oboe").depth)
        XCTAssertGreaterThan(position("timpani").depth, position("trumpet").depth)
        XCTAssertEqual(StagePosition(x: .nan, depth: .infinity), StagePosition(x: 0, depth: 0.35))
        XCTAssertEqual(StagePosition(x: -5, depth: 5), StagePosition(x: -1, depth: 1))
    }

    func testPositionChangeKeepsTransportRunning() {
        let engine = PlaybackEngine(makePlayerNode: { AVAudioPlayerNode() }, makeBuffer: { _, _, _, _ in self.signal() })
        let track = PlaybackTrack(voiceID: "v", name: "Violin", isPercussion: false,
                                  events: [PlaybackEvent(elementID: 0, midi: 60, startBeat: 0, durationBeats: 32, velocity: 80)])
        engine.load(PlaybackSequence(tracks: [track], tempoMap: [TempoPoint(beat: 0, quarterNoteBPM: 120)], totalBeats: 32), instruments: ["v": Instruments.byID("violin")!])
        defer { engine.stop() }
        engine.play()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let before = engine.progress
        engine.setTrackPositions(["v": StagePosition(x: 0.7, depth: 0.8)])
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertTrue(engine.isPlaying)
        XCTAssertGreaterThanOrEqual(engine.progress, before)
        XCTAssertLessThan(engine.progress - before, 0.03)
    }

    func testWAVExportUsesStagePlacement() throws {
        let track = PlaybackTrack(voiceID: "v", name: "Flute", isPercussion: false,
                                  events: [PlaybackEvent(elementID: 0, midi: 72, startBeat: 0, durationBeats: 1, velocity: 80)])
        let sequence = PlaybackSequence(tracks: [track], tempoMap: [TempoPoint(beat: 0, quarterNoteBPM: 120)], totalBeats: 1)
        let url = try AudioExporter.render(sequence: sequence, instruments: ["v": Instruments.byID("flute")!],
                                           positions: ["v": StagePosition(x: 1, depth: 0)], filename: "spatial-test-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        XCTAssertGreaterThan(energy(buffer, channel: 1), 0.001)
        XCTAssertGreaterThan(energy(buffer, channel: 1), energy(buffer, channel: 0) * 2)
    }
    func testConvolutionMatchesKnownLinearConvolutionIncludingTail() {
        XCTAssertEqual(HeadphoneHRTF.convolve([1, 2, 3], filter: [0.5, -1, 0.25]), [0.5, 0, -0.25, -2.5, 0.75])
        XCTAssertEqual(HeadphoneHRTF.convolve([1, 0, 0], filter: [0, 1, -0.5]), [0, 1, -0.5, 0, 0])
    }

    func testMeasuredProfilesAreBundledDistinctAndKeepEarDirection() throws {
        XCTAssertTrue(HeadphoneHRTF.isAvailable, "A missing resource must never silently pass as measured HRTF")
        var centers: [[Float]] = []
        for profile in [HeadphoneProfile.a, .b, .c] {
            let left = try XCTUnwrap(HeadphoneHRTF.direction(profile: profile, azimuth: -65))
            let right = try XCTUnwrap(HeadphoneHRTF.direction(profile: profile, azimuth: 65))
            func power(_ values: [Float]) -> Float { values.reduce(0) { $0 + $1 * $1 } }
            XCTAssertGreaterThan(power(left.left), power(left.right))
            XCTAssertGreaterThan(power(right.right), power(right.left))
            centers.append(try XCTUnwrap(HeadphoneHRTF.direction(profile: profile, azimuth: 0)).left)
        }
        XCTAssertNotEqual(centers[0], centers[1])
        XCTAssertNotEqual(centers[1], centers[2])
    }

    func testRoomCreatesInterauralReflectionsAndCacheIncludesSettings() {
        let source = signal(impulse: true)
        let renderer = OrchestraSpatializer()
        let position = StagePosition(x: 0, depth: 0.5)
        let dry = renderer.render(source, at: position, settings: HeadphoneSettings(profile: .a, room: 0))
        let room = renderer.render(source, at: position, settings: HeadphoneSettings(profile: .a, room: 1))
        let other = renderer.render(source, at: position, settings: HeadphoneSettings(profile: .b, room: 0))
        XCTAssertFalse(dry === room)
        XCTAssertFalse(dry === other)
        XCTAssertGreaterThan(room.frameLength, dry.frameLength)
        // Reflection arrivals are deliberately distinct at each ear.
        let begin = 500, end = min(Int(room.frameLength), 4000)
        var difference: Float = 0
        for i in begin..<end { difference += abs(room.floatChannelData![0][i] - room.floatChannelData![1][i]) }
        XCTAssertGreaterThan(difference, 0.001)
        for channel in 0..<2 {
            for i in 0..<Int(room.frameLength) { XCTAssertTrue(room.floatChannelData![channel][i].isFinite) }
        }
    }

    func testHeadphoneChoicePersistsAndSettingsClamp() throws {
        let suite = "spatial-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = StudioModel(headphoneDefaults: defaults)
        let settings = HeadphoneSettings(profile: .c, room: 0.7, width: 1.2)
        model.setHeadphoneSettings(settings)
        XCTAssertEqual(StudioModel(headphoneDefaults: defaults).headphoneSettings, settings)
        XCTAssertEqual(HeadphoneSettings(profile: .a, room: .nan, width: .infinity), HeadphoneSettings())
        let invalid = Data(#"{"profile":"b","room":20,"width":-5}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(HeadphoneSettings.self, from: invalid),
                       HeadphoneSettings(profile: .b, room: 1, width: 0.75))
        let burst = HeadphoneTrial.signal()
        for i in 0..<Int(burst.frameLength) {
            XCTAssertEqual(burst.floatChannelData![0][i], burst.floatChannelData![1][i])
            XCTAssertLessThan(abs(burst.floatChannelData![0][i]), 0.3)
        }
    }

    func testAuditionCanReturnToMainPlaybackWithoutDelayedSessionRelease() {
        let main = PlaybackEngine(makePlayerNode: { AVAudioPlayerNode() }, makeBuffer: { _, _, _, _ in HeadphoneTrial.signal() })
        let preview = PlaybackEngine(makePlayerNode: { AVAudioPlayerNode() }, makeBuffer: { _, _, _, _ in HeadphoneTrial.signal() })
        let track = PlaybackTrack(voiceID: "v", name: "Violin", isPercussion: false,
                                  events: [PlaybackEvent(elementID: 0, midi: 60, startBeat: 0, durationBeats: 32, velocity: 80)])
        main.load(PlaybackSequence(tracks: [track], tempoMap: [TempoPoint(beat: 0, quarterNoteBPM: 120)], totalBeats: 32), instruments: [:])
        defer { main.stop(); preview.finishAudition() }
        main.play()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        main.suspendForAudition()
        preview.load(HeadphoneTrial.sequence(), instruments: [:])
        preview.onCursor = { _, _ in }
        preview.onFinish = {}
        preview.play()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        preview.finishAudition()
        XCTAssertNil(preview.onCursor)
        XCTAssertNil(preview.onFinish)
        main.play()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        XCTAssertTrue(main.isPlaying)
        XCTAssertGreaterThan(main.progress, 0.05)
    }

    func testWAVUsesChosenProfileRatherThanOnlyDefault() throws {
        let track = PlaybackTrack(voiceID: "v", name: "Violin", isPercussion: false,
                                  events: [PlaybackEvent(elementID: 0, midi: 72, startBeat: 0, durationBeats: 1, velocity: 80)])
        let sequence = PlaybackSequence(tracks: [track], tempoMap: [TempoPoint(beat: 0, quarterNoteBPM: 120)], totalBeats: 1)
        var signals: [[Float]] = []
        for profile in [HeadphoneProfile.a, .b] {
            let url = try AudioExporter.render(sequence: sequence, instruments: ["v": Instruments.byID("violin")!],
                                               headphoneSettings: HeadphoneSettings(profile: profile, room: 0),
                                               filename: "chosen-profile-\(UUID()).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            signals.append(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
        }
        XCTAssertNotEqual(signals[0], signals[1])
    }

}
