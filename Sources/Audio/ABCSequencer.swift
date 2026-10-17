import Foundation

/// One sounding event, in quarter-note beats from tune start (repeat-expanded).
public struct PlaybackEvent: Sendable {
    public var elementID: Int      // ABCNote.id for cursor highlighting
    public var midi: Int           // pitch, or GM drum number on percussion tracks
    public var startBeat: Double
    public var durationBeats: Double
    public var velocity: Double    // 0-127

    public init(elementID: Int, midi: Int, startBeat: Double, durationBeats: Double, velocity: Double) {
        self.elementID = elementID
        self.midi = midi
        self.startBeat = startBeat
        self.durationBeats = durationBeats
        self.velocity = velocity
    }
}

public struct PlaybackTrack: Sendable {
    public var voiceID: String
    public var name: String
    public var isPercussion: Bool
    public var events: [PlaybackEvent]

    public init(voiceID: String, name: String, isPercussion: Bool, events: [PlaybackEvent]) {
        self.voiceID = voiceID
        self.name = name
        self.isPercussion = isPercussion
        self.events = events
    }
}

public struct TempoPoint: Sendable {
    public var beat: Double             // quarter-note beats from start
    public var quarterNoteBPM: Double

    public init(beat: Double, quarterNoteBPM: Double) {
        self.beat = beat
        self.quarterNoteBPM = quarterNoteBPM
    }
}

/// 拍位置での拍子変更(MIDI エクスポートの拍子メタイベント用)
public struct MeterPoint: Sendable {
    public var beat: Double
    public var meter: ABCMeter

    public init(beat: Double, meter: ABCMeter) {
        self.beat = beat
        self.meter = meter
    }
}

public struct PlaybackSequence: Sendable {
    public var tracks: [PlaybackTrack]
    /// Sorted by beat, first at beat 0. Rebuild the index on public mutations too.
    public var tempoMap: [TempoPoint] {
        didSet { tempoSeconds = Self.accumulatedSeconds(tempoMap) }
    }
    /// Elapsed seconds at each tempo boundary, shared by both conversion directions.
    private var tempoSeconds: [TimeInterval]
    public var meterMap: [MeterPoint]   // sorted, beat 0 はヘッダ拍子が入る
    public var totalBeats: Double

    public init(tracks: [PlaybackTrack], tempoMap: [TempoPoint], totalBeats: Double,
                meterMap: [MeterPoint] = []) {
        self.tracks = tracks
        self.tempoMap = tempoMap
        self.tempoSeconds = Self.accumulatedSeconds(tempoMap)
        self.meterMap = meterMap
        self.totalBeats = totalBeats
    }

    private static func accumulatedSeconds(_ points: [TempoPoint]) -> [TimeInterval] {
        guard !points.isEmpty else { return [] }
        var result = [TimeInterval](repeating: 0, count: points.count)
        for i in 1..<points.count {
            result[i] = result[i - 1]
                + (points[i].beat - points[i - 1].beat) * 60.0 / points[i - 1].quarterNoteBPM
        }
        return result
    }

    /// 拍位置 → 秒(speed=100 換算)。累積秒と二分探索で O(log テンポ数)。
    // Keep the constant-tempo fast path inline in scheduling/export loops.
    @inline(__always)
    public func seconds(forBeat beat: Double) -> TimeInterval {
        guard let first = tempoMap.first else { return beat * 0.5 }
        if tempoMap.count == 1 || beat <= first.beat {
            return (beat - first.beat) * 60.0 / first.quarterNoteBPM
        }
        var lo = 1, hi = tempoMap.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if tempoMap[mid].beat < beat { lo = mid + 1 } else { hi = mid }
        }
        let i = lo - 1
        return tempoSeconds[i] + (beat - tempoMap[i].beat) * 60.0 / tempoMap[i].quarterNoteBPM
    }

    /// 秒 → 拍。再生クロックも同じテンポ索引を使う。
    @inline(__always)
    public func beat(forSeconds seconds: TimeInterval) -> Double {
        guard let first = tempoMap.first else { return seconds * 2 }
        if tempoMap.count == 1 || seconds <= 0 {
            return first.beat + seconds * first.quarterNoteBPM / 60.0
        }
        var lo = 1, hi = tempoSeconds.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if tempoSeconds[mid] < seconds { lo = mid + 1 } else { hi = mid }
        }
        let i = lo - 1
        return tempoMap[i].beat + (seconds - tempoSeconds[i]) * tempoMap[i].quarterNoteBPM / 60.0
    }

    /// speed=100 換算の総再生秒
    public var totalSeconds: TimeInterval { seconds(forBeat: totalBeats) }
}

public enum ABCSequencer {
    private static let baseVelocity = 105.0
    /// Each grace note steals a fixed 1/32 beat, placed so the last grace ends
    /// exactly at the parent note's start.
    private static let graceBeats = 1.0 / 32.0

    /// フェルマータのテンポ倍率(瞬間的なテンポ低下で「伸ばし」を表現する)
    private static let fermataTempoScale = 0.6

    /// Model → timed events. Expands repeats (|: :|, endings |1 |2 |3...), merges ties,
    /// applies tempo map, dynamics decorations, chords, grace notes.
    /// Fermatas are realised as tempo-map dips so every voice holds together.
    public static func sequence(_ tune: ABCTune) -> PlaybackSequence {
        // Beat → qnBPM. Beat 0 always carries the tune header tempo; an inline
        // tempo at beat 0 may overwrite it.
        var tempoPoints: [Double: Double] = [0: tune.tempo.quarterNoteBPM]
        var meterPoints: [(beat: Double, meter: ABCMeter)] = []
        var tracks: [PlaybackTrack] = []
        var totalBeats = 0.0
        var fermatas: [(start: Double, end: Double)] = []
        for voice in tune.voices {
            let result = sequenceVoice(voice, tempoPoints: &tempoPoints, meterPoints: &meterPoints)
            totalBeats = max(totalBeats, result.finalBeat)
            tracks.append(result.track)
            fermatas += result.fermatas
        }
        for track in tracks {
            for event in track.events {
                totalBeats = max(totalBeats, event.startBeat + event.durationBeats)
            }
        }
        applyFermatas(fermatas, to: &tempoPoints)
        let tempoMap = tempoPoints
            .map { TempoPoint(beat: $0.key, quarterNoteBPM: $0.value) }
            .sorted { $0.beat < $1.beat }
        // 拍子変化は全声部を横断して集約(同一拍の重複は後勝ち)。beat 0 はヘッダ拍子をシードする。
        var meterByBeat: [Double: ABCMeter] = [:]
        for p in meterPoints { meterByBeat[p.beat] = p.meter }
        if meterByBeat[0] == nil { meterByBeat[0] = tune.meter }
        let meterMap = meterByBeat
            .map { MeterPoint(beat: $0.key, meter: $0.value) }
            .sorted { $0.beat < $1.beat }
        return PlaybackSequence(tracks: tracks, tempoMap: tempoMap, totalBeats: totalBeats,
                                meterMap: meterMap)
    }

    /// フェルマータ区間をテンポマップのディップに変換する。
    /// 拍位置は変えず秒だけ伸びるため、全パートの同期が保たれる。
    private static func applyFermatas(_ ranges: [(start: Double, end: Double)],
                                      to tempoPoints: inout [Double: Double]) {
        let sorted = ranges.sorted { $0.start < $1.start }
        var merged: [(start: Double, end: Double)] = []
        for r in sorted where r.end > r.start {
            if let last = merged.last, r.start <= last.end + 1e-9 {
                merged[merged.count - 1].end = max(last.end, r.end)
            } else {
                merged.append(r)
            }
        }
        /// 「beat 以下で最大の拍位置」のテンポを引く
        func tempo(at beat: Double) -> Double {
            var best = -Double.infinity
            var bpm = 120.0
            for (b, v) in tempoPoints where b <= beat + 1e-9 && b > best {
                best = b
                bpm = v
            }
            return bpm
        }
        for r in merged {
            // 復帰テンポはディップを書き込む前に読む(先に書くと自身の値を拾う)
            let restore = tempo(at: r.end)
            tempoPoints[r.start] = tempo(at: r.start) * fermataTempoScale
            tempoPoints[r.end] = restore
        }
    }

    // MARK: - Measure splitting

    /// Elements between bar lines. The closing bar ends the measure; a bar's
    /// `endings` list opens an ending section for the FOLLOWING measures.
    private struct Measure {
        var elements: [ABCElement]      // notes and fieldChanges only
        var closingBar: ABCBar?
        var openingEndings: [Int]       // endings in effect when this measure starts
    }

    private static func splitMeasures(_ voice: ABCVoice) -> [Measure] {
        var measures: [Measure] = []
        var current: [ABCElement] = []
        var pendingEndings: [Int] = []
        for element in voice.elements {
            if case .bar(let bar) = element {
                // :|2 のように小節線直後に付く括弧番号は、空の幻影小節を
                // 作らず「次の小節を開く番号」としてだけ扱う。
                if current.isEmpty, !bar.endings.isEmpty {
                    pendingEndings = bar.endings
                    continue
                }
                measures.append(Measure(elements: current, closingBar: bar,
                                        openingEndings: pendingEndings))
                current = []
                if !bar.endings.isEmpty {
                    // This bar opens a new ending section for following measures.
                    pendingEndings = bar.endings
                } else if bar.kind == .repeatStart || bar.kind == .repeatEnd || bar.kind == .repeatBoth {
                    // A repeat boundary closes any open ending section.
                    pendingEndings = []
                }
            } else {
                current.append(element)
            }
        }
        if !current.isEmpty {
            measures.append(Measure(elements: current, closingBar: nil,
                                    openingEndings: pendingEndings))
        }
        return measures
    }

    // MARK: - Expansion + emission

    /// 直後に続くエンディング測定(1番・2番…)の番号集合を返す。
    /// openingEndings を持つ小節が連続している範囲を走査する。
    private static func endingRun(_ measures: [Measure], from index: Int)
        -> (endings: Set<Int>, lastIndex: Int) {
        var endings = Set<Int>()
        var j = index
        while j < measures.count, !measures[j].openingEndings.isEmpty {
            endings.formUnion(measures[j].openingEndings)
            j += 1
        }
        return (endings, j - 1)
    }

    private static func sequenceVoice(_ voice: ABCVoice,
                                      tempoPoints: inout [Double: Double],
                                      meterPoints: inout [(beat: Double, meter: ABCMeter)])
        -> (track: PlaybackTrack, finalBeat: Double, fermatas: [(start: Double, end: Double)]) {
        let measures = splitMeasures(voice)
        var events: [PlaybackEvent] = []
        var beat = 0.0
        var velocity = baseVelocity
        var pendingTies: [Int: Int] = [:]   // midi → index into events
        var fermatas: [(start: Double, end: Double)] = []
        var openHairpin: (start: Double, velocity: Double, up: Bool)?
        var hairpins: [(start: Double, end: Double, v0: Double, v1: Double, up: Bool)] = []
        // 装飾音の上方隣音などを調に沿って解決するため、声部の現在の調を追跡する
        var keyAcc: [Int: Int] = [:]
        for a in voice.keySignature.accidentals { keyAcc[a.letter] = a.accidental.semitones }
        // Stack of open repeat sections (innermost last). start = measure index
        // of the section's first measure; end = last measure of the ending run
        // that followed its :| (nil = unknown / unclosed).
        var stack: [(start: Int, pass: Int, end: Int?)] = []
        // Pass of the most recently closed section; trailing ending measures
        // (|2 …) that follow a :| still need to compare against that pass.
        var lastPass = 1
        var i = 0
        var iterations = 0
        let maxIterations = measures.count * 64 + 256
        while true {
            if i >= measures.count {
                // Unclosed |: → treat the last bar as :| and replay once.
                if let idx = stack.lastIndex(where: { $0.pass == 1 }) {
                    stack[idx].pass = 2
                    stack = Array(stack[0...idx])
                    i = stack[idx].start
                    continue
                }
                break
            }
            iterations += 1
            if iterations > maxIterations { break }
            let measure = measures[i]
            let pass = stack.last?.pass ?? lastPass
            let played = measure.openingEndings.isEmpty || measure.openingEndings.contains(pass)
            if played {
                for element in measure.elements {
                    switch element {
                    case .note(let note):
                        emit(note, &events, &beat, &velocity, &pendingTies,
                             &fermatas, &openHairpin, &hairpins, keyAcc)
                    case .fieldChange(let change):
                        switch change {
                        case .tempo(let tempo):
                            tempoPoints[beat] = tempo.quarterNoteBPM
                        case .meter(let meter):
                            meterPoints.append((beat, meter))
                        case .key(let key):
                            keyAcc = [:]
                            for a in key.accidentals { keyAcc[a.letter] = a.accidental.semitones }
                        case .noteLength:
                            break   // 基本音長の変更は各音符の duration に反映済み
                        }
                    case .bar:
                        break
                    }
                }
            }
            // Bars inside a skipped ending belong to the pass that plays it —
            // they must not trigger while skipped.
            var jumped = false
            if played, let bar = measure.closingBar {
                switch bar.kind {
                case .repeatStart:
                    stack.append((start: i + 1, pass: 1, end: nil))
                case .repeatEnd, .repeatBoth:
                    // :| with no matching |: → repeat from the beginning.
                    if stack.isEmpty { stack.append((start: 0, pass: 1, end: nil)) }
                    let run = endingRun(measures, from: i + 1)
                    var top = stack[stack.count - 1]
                    if top.end == nil { top.end = run.lastIndex }
                    // More passes needed while an ending number above the
                    // current pass exists; with no endings, replay once.
                    let maxPass = max(2, run.endings.max() ?? 0)
                    if top.pass < maxPass {
                        top.pass += 1
                        stack[stack.count - 1] = top
                        i = top.start
                        jumped = true
                    } else {
                        lastPass = stack.removeLast().pass
                        // The |: half of :|: opens a fresh section.
                        if bar.kind == .repeatBoth {
                            stack.append((start: i + 1, pass: 1, end: nil))
                        }
                    }
                case .plain, .double, .final:
                    break
                }
            }
            if jumped { continue }
            if var top = stack.last {
                // Reached an ending that doesn't belong to this pass, but a
                // later ending remains → take the next pass now.
                if i + 1 < measures.count {
                    let next = measures[i + 1].openingEndings
                    if !next.isEmpty && !next.contains(top.pass) {
                        let run = endingRun(measures, from: i + 1)
                        // このパスのエンディングが run 内に残っているなら
                        // まだ進んでよい(飛び越さない)。自分の番が済んで
                        // さらに先の番号があるときだけ次パスへジャンプする。
                        if !run.endings.contains(top.pass),
                           let nextPass = run.endings.filter({ $0 > top.pass }).min() {
                            if top.end == nil { top.end = run.lastIndex }
                            top.pass = nextPass
                            stack[stack.count - 1] = top
                            i = top.start
                            continue
                        }
                    }
                }
                // Section fully played out past its ending run → close it.
                if let end = stack.last?.end, i >= end {
                    lastPass = stack.removeLast().pass
                }
            }
            i += 1
        }
        applyHairpins(hairpins, to: &events)
        let track = PlaybackTrack(voiceID: voice.id, name: voice.name,
                                  isPercussion: voice.isPercussion, events: events)
        return (track, beat, fermatas)
    }

    /// ヘアピン(クレッシェンド/デクレッシェンド)を区間内のイベントのベロシティに
    /// 線形補間で適用する。終点の強弱指定がなければ既定の変化量を使う。
    private static func applyHairpins(
        _ hairpins: [(start: Double, end: Double, v0: Double, v1: Double, up: Bool)],
        to events: inout [PlaybackEvent]) {
        for h in hairpins where h.end > h.start {
            let v1 = h.v1 != h.v0 ? h.v1 : (h.up ? min(127, h.v0 * 1.3) : h.v0 * 0.75)
            for k in events.indices {
                let e = events[k]
                guard e.startBeat >= h.start, e.startBeat < h.end else { continue }
                let t = (e.startBeat - h.start) / (h.end - h.start)
                events[k].velocity = min(127, max(1, h.v0 + (v1 - h.v0) * t))
            }
        }
    }

    /// トリル/モルデントの装飾単位(拍)。四分音符=1。
    private static let ornamentUnit = 0.125

    /// Emits one note element: grace events, then per-pitch events with tie
    /// merging. Realises trill/mordent/roll ornaments and staccato, records
    /// fermata ranges and hairpin spans for post-processing.
    /// 装飾とグレースは休符にも適用する(フェルマータ付き休符 `Hz` など)。
    private static func emit(_ note: ABCNote,
                             _ events: inout [PlaybackEvent],
                             _ beat: inout Double,
                             _ velocity: inout Double,
                             _ pendingTies: inout [Int: Int],
                             _ fermatas: inout [(start: Double, end: Double)],
                             _ openHairpin: inout (start: Double, velocity: Double, up: Bool)?,
                             _ hairpins: inout [(start: Double, end: Double, v0: Double, v1: Double, up: Bool)],
                             _ keyAcc: [Int: Int]) {
        let dur = note.duration.value * 4
        var noteVelocity = velocity
        var accented = false
        var staccato = false
        var trill = false
        var mordent = false
        var roll = false
        for decoration in note.decorations {
            switch decoration {
            case .dynamic(let v, _):
                velocity = Double(v)        // persists for the voice
                noteVelocity = velocity
            case .accent:
                accented = true
            case .staccato:
                staccato = true
            case .fermata:
                fermatas.append((start: beat, end: beat + dur))
            case .trill:
                trill = true
            case .mordent:
                mordent = true
            case .roll:
                roll = true
            case .crescendoStart:
                openHairpin = (start: beat, velocity: velocity, up: true)
            case .diminuendoStart:
                openHairpin = (start: beat, velocity: velocity, up: false)
            case .crescendoEnd, .diminuendoEnd:
                if let h = openHairpin, beat > h.start {
                    hairpins.append((start: h.start, end: beat,
                                     v0: h.velocity, v1: velocity, up: h.up))
                }
                openHairpin = nil
            default:
                break
            }
        }
        if accented { noteVelocity = min(127, noteVelocity * 1.15) }

        // Grace notes: each takes 1/32 beat, the LAST one ending exactly at the
        // main note start. Clamped to ≥ 0. 親が休符でも(珍しいが)鳴らす。
        let graceCount = note.graceNotes.count
        for (j, grace) in note.graceNotes.enumerated() {
            let end = beat - Double(graceCount - 1 - j) * graceBeats
            let start = max(0, end - graceBeats)
            let graceDur = end - start
            guard graceDur > 0 else { continue }
            for pitch in grace.pitches {
                events.append(PlaybackEvent(elementID: note.id, midi: pitch.midi,
                                            startBeat: start, durationBeats: graceDur,
                                            velocity: noteVelocity))
            }
        }

        if note.isRest {
            // A rest breaks any pending tie chain and advances the clock.
            // 装飾(フェルマータ・強弱・ヘアピン)は上で既に適用済み。
            pendingTies.removeAll()
            beat += dur
            return
        }

        // スタッカートは発音時間だけ短くし、拍(次の音符位置)は変えない
        let soundingDur = staccato ? dur * 0.55 : dur

        // Main pitches: extend a pending tied event of the same midi, else attack.
        var covered = Set<Int>()
        for (pitchIndex, pitch) in note.pitches.enumerated() {
            covered.insert(pitch.midi)
            if let index = pendingTies[pitch.midi] {
                events[index].durationBeats += dur
                if !note.tieStart {
                    pendingTies.removeValue(forKey: pitch.midi)
                }
            } else if trill {
                emitTrill(noteID: note.id, midi: pitch.midi,
                          upperMidi: upperNeighbor(pitch, keyAcc: keyAcc),
                          at: beat, dur: soundingDur,
                          velocity: noteVelocity, into: &events)
            } else if mordent {
                emitMordent(noteID: note.id, midi: pitch.midi,
                            upperMidi: upperNeighbor(pitch, keyAcc: keyAcc),
                            at: beat, dur: soundingDur,
                            velocity: noteVelocity, into: &events)
            } else {
                // ロール(アルペジオ)は和音の各音をわずかにずらして鳴らす
                let offset = (roll && note.pitches.count > 1)
                    ? Double(pitchIndex) * ornamentUnit / 2 : 0
                let start = beat + offset
                let length = max(0.01, soundingDur - offset)
                events.append(PlaybackEvent(elementID: note.id, midi: pitch.midi,
                                            startBeat: start, durationBeats: length,
                                            velocity: noteVelocity))
                if note.tieStart {
                    pendingTies[pitch.midi] = events.count - 1
                }
            }
        }
        // Tie chains not continued by this note's pitches are broken.
        pendingTies = pendingTies.filter { covered.contains($0.key) }
        beat += dur
    }

    /// 主音の上方隣音の midi。主音の上の音名(diatonic step+1)に調号の臨時記号を適用する。
    /// 小節内の書き込み臨時記号はモデルに残っていないため、調号のみを見る。
    private static func upperNeighbor(_ pitch: ABCPitch, keyAcc: [Int: Int]) -> Int {
        let step2 = pitch.step + 1
        let li = ((step2 % 7) + 7) % 7          // 音名 0-6 (C-B)
        let oct = (step2 - li) / 7              // floor division(負の step 対応)
        let natural = [0, 2, 4, 5, 7, 9, 11][li]
        return 60 + oct * 12 + natural + (keyAcc[li] ?? 0)
    }

    /// トリルを主音と上方隣音の32分相当(ornamentUnit)の交替として実演奏化する。
    private static func emitTrill(noteID: Int, midi: Int, upperMidi: Int, at beat: Double,
                                  dur: Double, velocity: Double,
                                  into events: inout [PlaybackEvent]) {
        var t = 0.0
        var upper = false
        while t < dur - 1e-9 {
            let seg = min(ornamentUnit, dur - t)
            events.append(PlaybackEvent(elementID: noteID, midi: upper ? upperMidi : midi,
                                        startBeat: beat + t, durationBeats: seg,
                                        velocity: velocity))
            upper.toggle()
            t += seg
        }
    }

    /// モルデントを 主音→上方隣音→主音 の短い区切りとして実演奏化する。
    private static func emitMordent(noteID: Int, midi: Int, upperMidi: Int, at beat: Double,
                                    dur: Double, velocity: Double,
                                    into events: inout [PlaybackEvent]) {
        let seg = min(ornamentUnit, dur / 3)
        guard seg > 0 else { return }
        events.append(PlaybackEvent(elementID: noteID, midi: midi,
                                    startBeat: beat, durationBeats: seg,
                                    velocity: velocity))
        events.append(PlaybackEvent(elementID: noteID, midi: upperMidi,
                                    startBeat: beat + seg, durationBeats: seg,
                                    velocity: velocity))
        events.append(PlaybackEvent(elementID: noteID, midi: midi,
                                    startBeat: beat + seg * 2, durationBeats: dur - seg * 2,
                                    velocity: velocity))
    }
}
