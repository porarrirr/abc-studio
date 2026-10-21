import AVFoundation
import Foundation

/// PlaybackSequence をオフラインで WAV ファイルにレンダリングする。
/// 再生時と同じグラフ(playerNodes → auxMixer → reverb → mainMixer)を
/// manual rendering mode の別エンジンで回す。
public enum AudioExporter {
    public enum RenderError: LocalizedError {
        case empty
        case tooLong
        case renderFailed
        case cancelled
        public var errorDescription: String? {
            switch self {
            case .empty: return "書き出す音がありません"
            case .tooLong: return "曲が長すぎて書き出せません"
            case .renderFailed: return "音声のレンダリングに失敗しました"
            case .cancelled: return "書き出しをキャンセルしました"
            }
        }
    }

    /// 上限 20 分(speed 反映後の実時間)
    public static let maxRenderSeconds: TimeInterval = 20 * 60

    /// 現在のパート割当・ミュート/ソロ・音量・速度を反映して書き出す。
    /// - returns: 一時ディレクトリ内の .wav ファイル URL
    public static func render(sequence: PlaybackSequence,
                              instruments: [String: Instrument],
                              trackGains: [String: Float] = [:],
                              positions: [String: StagePosition] = [:],
                              headphoneSettings: HeadphoneSettings = HeadphoneSettings(),
                              masterVolume: Float = 1,
                              speedPercent: Int = 100,
                              filename: String = "ABCStudio-render.wav") throws -> URL {
        let rate = max(0.25, Double(speedPercent) / 100)
        let outSeconds = sequence.totalSeconds / rate
        guard sequence.totalBeats > 0 else { throw RenderError.empty }
        guard outSeconds <= maxRenderSeconds else { throw RenderError.tooLong }

        let font = SoundFontPlayer()
        let spatializer = OrchestraSpatializer()
        let format = font.format
        let engine = AVAudioEngine()
        let auxMixer = AVAudioMixerNode()
        let reverb = AVAudioUnitReverb()
        // PlaybackEngine と同じ auxMixer → reverb → limiter → mainMixer。
        let limiter = AVAudioUnitEffect(audioComponentDescription:
            AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_DynamicsProcessor,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0))

        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 8192)
        engine.attach(auxMixer)
        engine.attach(reverb)
        engine.attach(limiter)
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = headphoneSettings.reverbMix
        engine.connect(auxMixer, to: reverb, format: format)
        engine.connect(reverb, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = min(1, max(0, masterVolume))
        func setLimit(_ address: AUParameterAddress, _ value: Float) {
            limiter.auAudioUnit.parameterTree?
                .parameter(withAddress: address)?.value = value
        }
        setLimit(0, -6); setLimit(1, 5); setLimit(4, 0.004)
        setLimit(5, 0.12); setLimit(6, 0)

        var nodes: [AVAudioPlayerNode] = []
        for track in sequence.tracks {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: auxMixer, format: format)
            let gain = trackGains[track.voiceID] ?? 1
            node.volume = gain.isFinite ? min(1, max(0, gain)) : 1
            nodes.append(node)
        }
        try engine.start()
        defer { engine.stop() }
        for node in nodes { node.play() }

        // 全イベントを絶対サンプル時刻でスケジュール(先読み不要、一括でよい)
        // makeBuffer がイベントごとに走るのでキャンセルもここで拾う。
        let leadIn = 0.05
        for (index, track) in sequence.tracks.enumerated() {
            let instrument = instruments[track.voiceID]
                ?? (track.isPercussion
                    ? (Instruments.byID("drums") ?? Instruments.all[0])
                    : Instruments.all[0])
            for event in track.events {
                if Task.isCancelled {
                    engine.stop()
                    throw RenderError.cancelled
                }
                let offsetSec = sequence.seconds(forBeat: event.startBeat) / rate + leadIn
                let eventSec = (sequence.seconds(forBeat: event.startBeat + event.durationBeats)
                                - sequence.seconds(forBeat: event.startBeat)) / rate
                guard let source = font.makeBuffer(dir: instrument.soundFontDir,
                                                   midi: instrument.soundingNote(event.midi),
                                                   seconds: eventSec,
                                                   velocity: event.velocity) else {
                    continue
                }
                let position = positions[track.voiceID]
                    ?? .orchestral(instrument: instrument, partName: track.name)
                let buffer = spatializer.render(source, at: position, settings: headphoneSettings)
                let time = AVAudioTime(
                    sampleTime: AVAudioFramePosition((offsetSec * format.sampleRate).rounded()),
                    atRate: format.sampleRate)
                nodes[index].scheduleBuffer(buffer, at: time, options: [],
                                            completionHandler: nil)
            }
        }

        let totalFrames = AVAudioFrameCount((outSeconds + leadIn + font.sustainTail + font.releaseFade + 0.35) * format.sampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)
        else { throw RenderError.renderFailed }
        var written: AVAudioFrameCount = 0
        while written < totalFrames {
            if Task.isCancelled {
                engine.stop()
                try? FileManager.default.removeItem(at: url)   // 中途半端なファイルを残さない
                throw RenderError.cancelled
            }
            let want = min(8192, totalFrames - written)
            do {
                try engine.renderOffline(want, to: buffer)
            } catch {
                throw RenderError.renderFailed
            }
            if buffer.frameLength == 0 { break }
            try file.write(from: buffer)
            written += buffer.frameLength
        }
        engine.stop()
        return url
    }
}
