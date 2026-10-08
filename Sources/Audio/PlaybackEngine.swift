import Foundation
import AVFoundation
import Combine
import Darwin

/// Native playback engine: one AVAudioPlayerNode per track → auxMixer → reverb
/// → mainMixer. Beats are mapped to seconds via the sequence's tempo map, then
/// compressed by the speed factor (100 = nominal). Buffers are scheduled at
/// a shared player timeline so pause/seek/speed can
/// reschedule, and only a lookahead window is kept scheduled so memory and
/// startup cost stay bounded for long tunes.
public final class PlaybackEngine: ObservableObject {
    @Published public private(set) var isPlaying = false
    @Published public private(set) var progress: Double = 0   // 0...1 of totalBeats
    /// Total duration in seconds at speed=100.
    public private(set) var duration: TimeInterval = 0

    /// (active element ids, anchor element id for cursor) on the main queue.
    public var onCursor: ((Set<Int>, Int?) -> Void)?
    /// On the main queue, when playback reaches the end.
    public var onFinish: (() -> Void)?
    /// On the main queue, when an audio interruption (call, Siri…) or route
    /// loss pauses playback. Lets the UI update its status text.
    public var onAutoPause: (() -> Void)?

    /// 曲の末尾で先頭に戻って繰り返す。
    public var loopEnabled = false

    private let engine = AVAudioEngine()
    private var makePlayerNode: () -> AVAudioPlayerNode = { AVAudioPlayerNode() }
    private var playerNodes: [AVAudioPlayerNode] = []
    private var sequence: PlaybackSequence?
    private var trackInstruments: [Instrument] = []
    /// voiceID → 0.0...1.0 (パート音量とミュート/ソロ反映済み)
    private var trackGains: [String: Float] = [:]
    private let soundFont = SoundFontPlayer()
    /// Shared ambience: playerNodes → auxMixer → reverb → limiter → mainMixer.
    /// Effects have a single input bus, so the tracks must be summed by a
    /// mixer node first; a light hall makes the dry samples sit in a room,
    /// and the dynamics processor keeps dense passages from clipping.
    private let auxMixer = AVAudioMixerNode()
    private let reverb = AVAudioUnitReverb()
    private let limiter = AVAudioUnitEffect(audioComponentDescription:
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
    private var effectsConnected = false
    private var speedPercent = 100
    private var positionBeat: Double = 0     // committed position (pause/seek/load)

    // Timing state for the current run (since last scheduleEvents).
    private var anchorUptime: TimeInterval = 0             // fallback clock basis
    private var startSec100: TimeInterval = 0              // seconds(forBeat: run start)
    private var timer: DispatchSourceTimer?
    private var sessionConfigured = false
    private let leadIn: TimeInterval = 0.08

    /// 先読みスケジューリングの窓(出力秒)。この先のイベントは随時追加される。
    private let lookaheadSec: TimeInterval = 12
    /// トラックごとの次にスケジュールするイベント index(events は時系列順)。
    private var schedIdx: [Int] = []
    /// すでにスケジュール済みの範囲(sec100 領域の上限)。
    private var schedHorizon: TimeInterval = 0

    /// 直近の再生位置(割り込み時に lastRenderTime が死んだ後でも退避できるよう)。
    private var lastBeat: Double = 0
    /// アイドル時のエンジン停止ディレイ(リバーブの残響を切らないよう猶予を持たせる)。
    private var shutdownWork: DispatchWorkItem?
    /// 割り込み開始時に再生中だった(終了時に自動再開するかの判定用)。
    private var resumeAfterInterrupt = false
    private var observersInstalled = false
    /// ブロックベースのセッション監視トークン(deinit で正しく解除するため保持)。
    private var sessionObservers: [NSObjectProtocol] = []
    /// トラックごとの最長イベント拍数(emitCursor の走査窓の下限計算用)。
    private var maxDurBeats: [Double] = []

    // MARK: - Buffer prefetch (バッファ生成の先読み)

    /// makeBuffer のイベント単位の加工(トリム+ゲイン+フェード)は重いため、
    /// スケジュール窓の先を専用キューで先読みしておき、メインスレッドでは
    /// 参照とスケジュールだけを行う。バッファ内容は再生位置に依存しないので
    /// シークしても有効なまま(速度変更と曲変更でのみ無効化する)。
    private struct PrepKey: Hashable { let track: Int; let event: Int }
    private let prepQueue = DispatchQueue(label: "jp.porari.abcstudio.bufferprep",
                                          qos: .userInitiated)
    private let prepLock = NSLock()
    private var preparedBuffers: [PrepKey: AVAudioPCMBuffer] = [:]
    private var preparedBytes = 0
    private var prepGeneration = 0
    private var prepInFlight = false      // メインスレッドのみから読み書き
    /// スケジュール窓の先にどれだけ準備するか(実時間秒)
    private let prefetchAheadSec: TimeInterval = 16
    private let prefetchMaxBytes = 120 * 1024 * 1024

    private static let sampleRate = SoundFontPlayer.sampleRate
    private static let hostTicksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    public init() {}

    /// Allows scheduling to be observed without depending on audio output latency.
    init(makePlayerNode: @escaping () -> AVAudioPlayerNode) {
        self.makePlayerNode = makePlayerNode
    }

    deinit {
        stopTimer()
        shutdownWork?.cancel()
        // addObserver(forName:...using:) は返り値のトークンで解除する
        for o in sessionObservers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Loading

    /// Prepares audio for a sequence. `instruments` maps voiceID → Instrument;
    /// missing voices fall back to piano (drums for percussion tracks).
    public func load(_ sequence: PlaybackSequence, instruments: [String: Instrument]) {
        haltNodes()
        stopTimer()
        isPlaying = false
        self.sequence = sequence
        for node in playerNodes { engine.detach(node) }
        if !effectsConnected {
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = 18
            engine.attach(auxMixer)
            engine.attach(reverb)
            engine.attach(limiter)
            engine.connect(auxMixer, to: reverb, format: soundFont.format)
            engine.connect(reverb, to: limiter, format: soundFont.format)
            engine.connect(limiter, to: engine.mainMixerNode, format: soundFont.format)
            configureLimiter()
            effectsConnected = true
        }
        playerNodes = sequence.tracks.map { _ in makePlayerNode() }
        for node in playerNodes {
            engine.attach(node)
            engine.connect(node, to: auxMixer, format: soundFont.format)
        }
        trackInstruments = sequence.tracks.map { track in
            instruments[track.voiceID]
                ?? (track.isPercussion
                    ? (Instruments.byID("drums") ?? Instruments.all[0])
                    : Instruments.all[0])
        }
        // Spread ensemble tracks slightly so the mix isn't dead-center;
        // percussion and the lead voice stay in the middle.
        for (i, node) in playerNodes.enumerated() {
            node.pan = Self.trackPan(index: i,
                                     isPercussion: trackInstruments[i].isDrums)
        }
        applyTrackGains()
        duration = seconds(forBeat: sequence.totalBeats)
        positionBeat = 0
        lastBeat = 0
        progress = 0
        schedIdx = []
        schedHorizon = 0
        maxDurBeats = sequence.tracks.map { $0.events.map(\.durationBeats).max() ?? 0 }
        invalidatePrepared()
        kickPrefetch()   // 再生開始を待たずに冒頭のバッファを先読みする
    }

    /// 読み込み失敗時に旧曲の再生状態を完全に破棄する。
    public func unload() {
        stop()
        sequence = nil
        for node in playerNodes { engine.detach(node) }
        playerNodes = []
        trackInstruments = []
        trackGains = [:]
        schedIdx = []
        schedHorizon = 0
        maxDurBeats = []
        invalidatePrepared()
        duration = 0
    }

    /// Gentle master-bus limiting: only catches peaks that would clip,
    /// leaving normal passages untouched (compression threshold ≈ -6 dBFS,
    /// ceiling ≈ -1 dBFS, fast attack / moderate release).
    private func configureLimiter() {
        func set(_ address: AUParameterAddress, _ value: Float) {
            limiter.auAudioUnit.parameterTree?
                .parameter(withAddress: address)?.value = value
        }
        set(0, -6)      // Compression Threshold (dB)
        set(1, 5)       // Headroom (dB): output ceiling = threshold + headroom
        set(4, 0.004)   // Attack Time (s)
        set(5, 0.12)    // Release Time (s)
        set(6, 0)       // Master Gain (dB)
    }

    /// Alternating ±spread for tracks past the lead voice (index 0), keeping
    /// percussion centred. Returns a player-node pan in -1...1.
    static func trackPan(index: Int, isPercussion: Bool) -> Float {
        guard index > 0, !isPercussion else { return 0 }
        let table: [Float] = [-0.22, 0.22, -0.35, 0.35, -0.14, 0.14, -0.28, 0.28]
        return table[(index - 1) % table.count]
    }

    // MARK: - Volume

    /// voiceID → 0...1。パート音量とミュート/ソロを反映した値を受け取る。
    public func setTrackGains(_ gains: [String: Float]) {
        trackGains = gains
        applyTrackGains()
    }

    private func applyTrackGains() {
        guard let seq = sequence else { return }
        for (i, track) in seq.tracks.enumerated() where i < playerNodes.count {
            let gain = trackGains[track.voiceID] ?? 1
            playerNodes[i].volume = gain.isFinite ? min(1, max(0, gain)) : 1
        }
    }

    /// マスター音量 0...1(デフォルト 1)
    public func setMasterVolume(_ volume: Float) {
        engine.mainMixerNode.outputVolume = min(1, max(0, volume))
    }

    // MARK: - Transport

    /// Start or resume from the current position.
    public func play() {
        guard let seq = sequence, seq.totalBeats > 0, !isPlaying else { return }
        shutdownWork?.cancel()
        activateSession()
        startEngineIfNeeded()
        if positionBeat >= seq.totalBeats { positionBeat = 0 }
        haltNodes()   // 自然終了直後の余韻バッファなど、残っている queue を掃除
        scheduleEvents(fromBeat: positionBeat)
        isPlaying = true
        startTimer()
        kickPrefetch()
    }

    public func pause() {
        pauseInternal(at: currentBeat())
    }

    /// 指定拍での一時停止(割り込み時は clock が死んでいることがあるので明示する)
    private func pauseInternal(at beat: Double) {
        guard isPlaying else { return }
        if let seq = sequence {
            positionBeat = min(max(0, beat), seq.totalBeats)
        } else {
            positionBeat = 0
        }
        haltNodes()
        isPlaying = false
        stopTimer()
        emitCursor(at: positionBeat)
        releaseAudio()
        kickPrefetch()   // 再開位置の先を先読みしておく
    }

    /// Reset to 0.
    public func stop() {
        haltNodes()
        stopTimer()
        isPlaying = false
        positionBeat = 0
        lastBeat = 0
        progress = 0
        emitCursor(at: nil)
        releaseAudio()
    }

    /// Works while playing or paused.
    public func seek(toFraction fraction: Double) {
        guard let seq = sequence, seq.totalBeats > 0 else { return }
        let beat = min(1, max(0, fraction)) * seq.totalBeats
        positionBeat = beat
        progress = beat / seq.totalBeats
        if isPlaying {
            haltNodes()
            scheduleEvents(fromBeat: beat)
        }
        emitCursor(at: beat)
        kickPrefetch()
    }

    /// 楽譜上の音符(要素ID)の位置へシークする。再生中・停止中の両方で動作。
    public func seekToElement(_ elementID: Int) {
        guard let seq = sequence, seq.totalBeats > 0 else { return }
        var found: Double?
        for track in seq.tracks {
            for event in track.events where event.elementID == elementID {
                found = min(found ?? .infinity, event.startBeat)
            }
        }
        if let beat = found { seek(toFraction: beat / seq.totalBeats) }
    }

    /// 50...200, preserves position (reschedules while playing).
    public func setSpeed(_ percent: Int) {
        let nextSpeed = min(200, max(50, percent))
        // バッファ長は速度依存なので先読み済みのものは全て作り直し
        invalidatePrepared()
        guard isPlaying else {
            speedPercent = nextSpeed
            kickPrefetch()
            return
        }
        let beat = currentBeat() // 変更前の速度で再生位置を確定する
        speedPercent = nextSpeed
        positionBeat = beat
        haltNodes()
        scheduleEvents(fromBeat: beat)
        kickPrefetch()
    }

    // MARK: - Tempo map (piecewise-linear beats ↔ seconds at speed 100)

    private func seconds(forBeat beat: Double) -> TimeInterval {
        sequence?.seconds(forBeat: beat) ?? beat * 0.5
    }

    private func beat(forSeconds sec100: TimeInterval) -> Double {
        guard let seq = sequence, let first = seq.tempoMap.first else {
            return sec100 * 2
        }
        var seconds = 0.0
        var prev = first
        for point in seq.tempoMap.dropFirst() {
            let segment = (point.beat - prev.beat) * 60.0 / prev.quarterNoteBPM
            if sec100 <= seconds + segment {
                return prev.beat + (sec100 - seconds) * prev.quarterNoteBPM / 60.0
            }
            seconds += segment
            prev = point
        }
        return prev.beat + (sec100 - seconds) * prev.quarterNoteBPM / 60.0
    }

    // MARK: - Scheduling (lookahead window)

    /// (Re)starts scheduling at `beat`: slices overlapping events, then fills
    /// only the lookahead window; `timerTick` tops the window up as it slides.
    private func scheduleEvents(fromBeat beat: Double) {
        guard let seq = sequence else { return }
        let rate = Double(speedPercent) / 100
        startSec100 = seconds(forBeat: beat)
        schedHorizon = startSec100 + lookaheadSec * rate
        // stop() resets every player timeline to sample zero. Queue the initial
        // buffers before starting any node, since decoding can exceed leadIn.
        schedIdx = []
        for (index, track) in seq.tracks.enumerated() {
            var k = 0
            // events are emitted in start order; skip everything fully past.
            while k < track.events.count
                    && track.events[k].startBeat + track.events[k].durationBeats <= beat {
                k += 1
            }
            // Events overlapping the position: play the remaining subrange.
            while k < track.events.count && track.events[k].startBeat < beat {
                schedule(track.events[k], track: index, eventIndex: k, tailOf: beat)
                k += 1
            }
            // Fill the lookahead window.
            while k < track.events.count
                    && seconds(forBeat: track.events[k].startBeat) < schedHorizon {
                schedule(track.events[k], track: index, eventIndex: k, tailOf: nil)
                k += 1
            }
            schedIdx.append(k)
        }
        // All tracks share the same zero, including tracks whose first note is
        // a rest. Later lookahead batches retain these absolute sample times.
        anchorUptime = ProcessInfo.processInfo.systemUptime + leadIn
        let startTime = AVAudioTime(hostTime: mach_absolute_time()
                                   &+ UInt64(leadIn * Self.hostTicksPerSecond))
        for node in playerNodes { node.play(at: startTime) }
    }

    /// 再生中にタイマーから呼ばれ、lookahead 窓の先までイベントを追加する。
    private func topUp() {
        guard let seq = sequence else { return }
        let rate = Double(speedPercent) / 100
        let horizon = seconds(forBeat: currentBeat()) + lookaheadSec * rate
        guard horizon > schedHorizon else { return }
        schedHorizon = horizon
        for (index, track) in seq.tracks.enumerated() where index < schedIdx.count {
            var k = schedIdx[index]
            while k < track.events.count
                    && seconds(forBeat: track.events[k].startBeat) < horizon {
                schedule(track.events[k], track: index, eventIndex: k, tailOf: nil)
                k += 1
            }
            schedIdx[index] = k
        }
        kickPrefetch()
    }

    /// Schedules one event on its track's player node. `tailOf` is set when the
    /// event started before the play position — only its remaining part plays.
    /// バッファは先読み済みのものを優先し、ミス時のみこの場で生成する。
    private func schedule(_ event: PlaybackEvent, track index: Int, eventIndex: Int,
                          tailOf beat: Double?) {
        guard index < playerNodes.count, index < trackInstruments.count else { return }
        let rate = Double(speedPercent) / 100
        let instrument = trackInstruments[index]
        let endBeat = event.startBeat + event.durationBeats
        let offsetSec = (seconds(forBeat: event.startBeat) - startSec100) / rate
        let eventSec = (seconds(forBeat: endBeat) - seconds(forBeat: event.startBeat)) / rate
        let prepKey = PrepKey(track: index, event: eventIndex)
        prepLock.lock()
        let prepared = preparedBuffers.removeValue(forKey: prepKey)
        if let prepared {
            preparedBytes -= Int(prepared.frameCapacity) * Int(prepared.format.channelCount) * MemoryLayout<Float>.size
        }
        prepLock.unlock()
        guard let buffer = prepared ?? soundFont.makeBuffer(dir: instrument.soundFontDir,
                                                          midi: instrument.soundingNote(event.midi),
                                                          seconds: eventSec,
                                                          velocity: event.velocity) else {
            return    // missing soundfont → skip this event's audio
        }
        let time = AVAudioTime(
            sampleTime: AVAudioFramePosition((max(0, offsetSec) * Self.sampleRate).rounded()),
            atRate: Self.sampleRate)
        if let beat = beat, event.startBeat < beat {
            // Event overlaps the position: play the remaining subrange.
            // (AVAudioPlayerNode has no buffer-based scheduleSegment, so
            // we slice off the elapsed head ourselves.)
            let elapsedSec = (startSec100 - seconds(forBeat: event.startBeat)) / rate
            let startFrame = AVAudioFramePosition((elapsedSec * Self.sampleRate).rounded())
            guard startFrame >= 0, startFrame < AVAudioFramePosition(buffer.frameLength),
                  let tail = subBuffer(buffer, from: startFrame) else {
                return
            }
            playerNodes[index].scheduleBuffer(tail, at: time, options: [],
                                              completionHandler: nil)
        } else {
            playerNodes[index].scheduleBuffer(buffer, at: time, options: [],
                                              completionHandler: nil)
        }
    }

    /// Current playhead position in beats, from the player node's audio timeline
    /// (falling back to the wall clock if the render timeline isn't up yet).
    private func currentBeat() -> Double {
        var elapsed = ProcessInfo.processInfo.systemUptime - anchorUptime
        if let node = playerNodes.first,
           let renderTime = node.lastRenderTime,
           let playerTime = node.playerTime(forNodeTime: renderTime) {
            elapsed = TimeInterval(playerTime.sampleTime) / playerTime.sampleRate
        }
        if elapsed < 0 { elapsed = 0 }
        let rate = Double(speedPercent) / 100
        return beat(forSeconds: startSec100 + elapsed * rate)
    }

    // MARK: - Cursor timer (~30Hz on main)

    private func startTimer() {
        stopTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0 / 30.0,
                       repeating: 1.0 / 30.0, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.timerTick() }
        self.timer = timer
        timer.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func timerTick() {
        guard isPlaying, let seq = sequence else { return }
        topUp()
        let beat = currentBeat()
        lastBeat = beat
        if beat >= seq.totalBeats {
            if loopEnabled {
                // 末尾で先頭へ: スケジュール状態をリセットして続行
                positionBeat = 0
                lastBeat = 0
                haltNodes()
                scheduleEvents(fromBeat: 0)
                progress = 0
                emitCursor(at: nil)
                kickPrefetch()
                return
            }
            // 自然終了: 最終音のバッファ末尾(サステイン+フェード+リバーブ)を
            // 鳴らし切るため、ノード停止・エンジン停止・セッション解放を遅らせる。
            // 残りはスケジュール済みバッファが自然に鳴り終わるのに任せる。
            isPlaying = false
            stopTimer()
            positionBeat = seq.totalBeats
            progress = 1
            emitCursor(at: seq.totalBeats)
            releaseAudio(after: soundFont.sustainTail + soundFont.releaseFade + 0.3)
            let finish = onFinish
            DispatchQueue.main.async { finish?() }
            return
        }
        progress = beat / seq.totalBeats
        emitCursor(at: beat)
    }

    /// Emits (active ids, anchor). Pass nil beat for an empty cursor.
    /// イベントは startBeat 昇順。最長音価を下限として二分探索で走査範囲を絞り、
    /// 長い曲でも 30Hz のタイマーが全イベントを舐めないようにする。
    private func emitCursor(at beat: Double?) {
        var ids = Set<Int>()
        var anchor: Int?
        if let seq = sequence, let beat = beat {
            var latestStart = -Double.infinity
            var recent: Int?
            for (ti, track) in seq.tracks.enumerated() {
                let events = track.events
                let maxDur = ti < maxDurBeats.count ? maxDurBeats[ti] : 0
                // startBeat <= beat - maxDur のイベントは既に終了している
                let lo = events.lowerBound { $0.startBeat >= beat - maxDur }
                // startBeat <= beat の末尾(最後に開始したイベント)
                let hi = events.lowerBound { $0.startBeat > beat }
                var k = lo
                while k < hi {
                    let e = events[k]
                    if beat < e.startBeat + e.durationBeats {
                        ids.insert(e.elementID)
                        if anchor == nil { anchor = e.elementID }
                    }
                    k += 1
                }
                if hi > 0 {
                    let e = events[hi - 1]
                    if e.startBeat >= latestStart {
                        latestStart = e.startBeat
                        recent = e.elementID
                    }
                }
            }
            if anchor == nil { anchor = recent }
        }
        let callback = onCursor
        let deliver: () -> Void = { callback?(ids, anchor) }
        if Thread.isMainThread { deliver() }
        else { DispatchQueue.main.async(execute: deliver) }
    }

    /// Copies frames [start, end) of a buffer into a fresh buffer, applying a
    /// short fade-in so a mid-sample cut doesn't click.
    private func subBuffer(_ buffer: AVAudioPCMBuffer, from start: AVAudioFramePosition)
        -> AVAudioPCMBuffer? {
        let frames = AVAudioFramePosition(buffer.frameLength) - start
        guard frames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: soundFont.format,
                                         frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        out.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(soundFont.format.channelCount) {
            memcpy(out.floatChannelData![channel],
                   buffer.floatChannelData![channel] + Int(start),
                   Int(frames) * MemoryLayout<Float>.size)
        }
        // ~6ms のフェードインを先頭に焼いてクリック音を防ぐ
        let ramp = min(Int(frames), 256)
        for channel in 0..<Int(soundFont.format.channelCount) {
            let data = out.floatChannelData![channel]
            for i in 0..<ramp { data[i] *= Float(i) / Float(ramp) }
        }
        return out
    }

    // MARK: - Buffer prefetch implementation

    /// スケジュール窓の先(停止中は再開位置の先)のバッファをバックグラウンドで用意する。
    /// メインスレッドでのみ呼ぶこと(prepInFlight / schedHorizon / positionBeat を読む)。
    private func kickPrefetch() {
        guard !prepInFlight, let seq = sequence else { return }
        prepInFlight = true
        let gen = prepGeneration
        let rate = Double(speedPercent) / 100
        // 再生中はスケジュール窓の末端から、停止中は再開位置から先読みする
        let head = isPlaying ? schedHorizon : seconds(forBeat: positionBeat)
        let limit = head + prefetchAheadSec * rate
        let instruments = trackInstruments
        prepQueue.async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { [weak self] in self?.prepInFlight = false } }
            var batch: [(PrepKey, AVAudioPCMBuffer)] = []
            for (ti, track) in seq.tracks.enumerated() {
                guard ti < instruments.count else { continue }
                let inst = instruments[ti]
                var k = track.events.lowerBound {
                    seq.seconds(forBeat: $0.startBeat) >= head
                }
                while k < track.events.count {
                    let e = track.events[k]
                    if seq.seconds(forBeat: e.startBeat) >= limit { break }
                    self.prepLock.lock()
                    let stale = self.prepGeneration != gen
                    let have = self.preparedBuffers[PrepKey(track: ti, event: k)] != nil
                    let full = self.preparedBytes >= self.prefetchMaxBytes
                    self.prepLock.unlock()
                    if stale || full { return }
                    if !have {
                        let sec = (seq.seconds(forBeat: e.startBeat + e.durationBeats)
                                   - seq.seconds(forBeat: e.startBeat)) / rate
                        if let buf = self.soundFont.makeBuffer(dir: inst.soundFontDir,
                                                               midi: inst.soundingNote(e.midi), seconds: sec,
                                                               velocity: e.velocity) {
                            batch.append((PrepKey(track: ti, event: k), buf))
                        }
                    }
                    k += 1
                    if batch.count >= 24 { self.flushPrep(&batch, gen: gen) }
                }
            }
            self.flushPrep(&batch, gen: gen)
        }
    }

    /// 生成済みバッファをまとめて辞書へ流す(ロック回数を減らすためバッチ)。
    private func flushPrep(_ batch: inout [(PrepKey, AVAudioPCMBuffer)], gen: Int) {
        guard !batch.isEmpty else { return }
        prepLock.lock()
        if gen == prepGeneration {
            for (key, buf) in batch {
                preparedBuffers[key] = buf
                preparedBytes += Int(buf.frameCapacity) * Int(buf.format.channelCount)
                    * MemoryLayout<Float>.size
            }
        }
        prepLock.unlock()
        batch.removeAll(keepingCapacity: true)
    }

    /// 曲変更・速度変更で先読みバッファを無効化する。
    /// generation を進めることで処理中のワーカーも途中で止まる。
    private func invalidatePrepared() {
        prepLock.lock()
        prepGeneration += 1
        preparedBuffers.removeAll()
        preparedBytes = 0
        prepLock.unlock()
    }

    // MARK: - Engine plumbing

    private func haltNodes() {
        for node in playerNodes { node.stop() }   // clears pending buffers
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[PlaybackEngine] engine failed to start: \(error)")
        }
    }

    /// 再生が止まったらセッションを解放し、エンジンを停止する。
    /// `delay` は残響・バッファ末尾を鳴らし切るための追加猶予(曲の自然終了用)。
    private func releaseAudio(after delay: TimeInterval = 0) {
        shutdownWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPlaying else { return }
            #if os(iOS)
            if self.sessionConfigured {
                try? AVAudioSession.sharedInstance()
                    .setActive(false, options: .notifyOthersOnDeactivation)
            }
            #endif
            if self.engine.isRunning { self.engine.stop() }
        }
        shutdownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + delay, execute: work)
    }

    private func configureSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            print("[PlaybackEngine] audio session configuration failed: \(error)")
        }
        installSessionObservers()
        #endif
    }

    private func activateSession() {
        #if os(iOS)
        configureSession()
        sessionConfigured = true
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[PlaybackEngine] audio session activation failed: \(error)")
        }
        #endif
    }

    /// 電話・Siri 等の割り込みと、イヤホン抜去等のルート変更で一時停止する。
    /// 割り込み終了時に shouldResume が立っていれば自動再開する。
    private func installSessionObservers() {
        #if os(iOS)
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        sessionObservers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                switch type {
                case .began:
                    // 描画系のクロックは既に止まっているので、直近タイマー値を退避
                    let wasPlaying = self.isPlaying
                    self.resumeAfterInterrupt = wasPlaying
                    self.pauseInternal(at: self.lastBeat)
                    if wasPlaying { self.onAutoPause?() }
                case .ended:
                    let options = AVAudioSession.InterruptionOptions(
                        rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                    if self.resumeAfterInterrupt, options.contains(.shouldResume) {
                        self.play()
                    }
                    self.resumeAfterInterrupt = false
                @unknown default:
                    break
                }
            })
        sessionObservers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
                // 停止中のルート変更で「一時停止」表示にならないよう再生中のみ報告
                if reason == .oldDeviceUnavailable, self.isPlaying {
                    self.pauseInternal(at: self.lastBeat)
                    self.onAutoPause?()
                }
            })
        #endif
    }
}

private extension Array where Element == PlaybackEvent {
    /// startBeat 昇順の配列で、述語が初めて真になる index(二分探索)。
    /// 返り値は「第2区画の先頭」— それより前は全て述語が偽。
    func lowerBound(_ belongsInSecondPartition: (PlaybackEvent) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if belongsInSecondPartition(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}
