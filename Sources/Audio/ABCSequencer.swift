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

public struct PlaybackSequence: Sendable {
    public var tracks: [PlaybackTrack]
    public var tempoMap: [TempoPoint]   // sorted, first at beat 0
    public var totalBeats: Double

    public init(tracks: [PlaybackTrack], tempoMap: [TempoPoint], totalBeats: Double) {
        self.tracks = tracks
        self.tempoMap = tempoMap
        self.totalBeats = totalBeats
    }
}

public enum ABCSequencer {
    private static let baseVelocity = 105.0
    /// Each grace note steals a fixed 1/32 beat, placed so the last grace ends
    /// exactly at the parent note's start.
    private static let graceBeats = 1.0 / 32.0

    /// Model → timed events. Expands repeats (|: :|, endings |1 |2), merges ties,
    /// applies tempo map, dynamics decorations, chords, grace notes.
    public static func sequence(_ tune: ABCTune) -> PlaybackSequence {
        // Beat → qnBPM. Beat 0 always carries the tune header tempo; an inline
        // tempo at beat 0 may overwrite it.
        var tempoPoints: [Double: Double] = [0: tune.tempo.quarterNoteBPM]
        var tracks: [PlaybackTrack] = []
        var totalBeats = 0.0
        for voice in tune.voices {
            let result = sequenceVoice(voice, tempoPoints: &tempoPoints)
            totalBeats = max(totalBeats, result.finalBeat)
            tracks.append(result.track)
        }
        for track in tracks {
            for event in track.events {
                totalBeats = max(totalBeats, event.startBeat + event.durationBeats)
            }
        }
        let tempoMap = tempoPoints
            .map { TempoPoint(beat: $0.key, quarterNoteBPM: $0.value) }
            .sorted { $0.beat < $1.beat }
        return PlaybackSequence(tracks: tracks, tempoMap: tempoMap, totalBeats: totalBeats)
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

    private static func sequenceVoice(_ voice: ABCVoice,
                                      tempoPoints: inout [Double: Double])
        -> (track: PlaybackTrack, finalBeat: Double) {
        let measures = splitMeasures(voice)
        var events: [PlaybackEvent] = []
        var beat = 0.0
        var velocity = baseVelocity
        var pendingTies: [Int: Int] = [:]   // midi → index into events
        // Stack of open repeat sections (innermost last). start = measure index
        // of the section's first measure; pass = 1 or 2 (sections replay once).
        var stack: [(start: Int, pass: Int)] = []
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
            if measure.openingEndings.isEmpty || measure.openingEndings.contains(pass) {
                for element in measure.elements {
                    switch element {
                    case .note(let note):
                        emit(note, &events, &beat, &velocity, &pendingTies)
                    case .fieldChange(let change):
                        if case .tempo(let tempo) = change {
                            tempoPoints[beat] = tempo.quarterNoteBPM
                        }
                    case .bar:
                        break
                    }
                }
            }
            if let bar = measure.closingBar {
                switch bar.kind {
                case .repeatStart:
                    stack.append((start: i + 1, pass: 1))
                case .repeatEnd:
                    // :| with no matching |: → repeat from the beginning.
                    if stack.isEmpty { stack.append((start: 0, pass: 1)) }
                    if stack[stack.count - 1].pass == 1 {
                        stack[stack.count - 1].pass = 2
                        i = stack[stack.count - 1].start
                        continue
                    }
                    lastPass = stack.removeLast().pass
                case .repeatBoth:
                    if stack.isEmpty { stack.append((start: 0, pass: 1)) }
                    if stack[stack.count - 1].pass == 1 {
                        stack[stack.count - 1].pass = 2
                        i = stack[stack.count - 1].start
                        continue
                    }
                    lastPass = stack.removeLast().pass
                    // The |: half opens a fresh section.
                    stack.append((start: i + 1, pass: 1))
                case .plain, .double, .final:
                    break
                }
            }
            i += 1
        }
        let track = PlaybackTrack(voiceID: voice.id, name: voice.name,
                                  isPercussion: voice.isPercussion, events: events)
        return (track, beat)
    }

    /// Emits one note element: grace events, then per-pitch events with tie merging.
    private static func emit(_ note: ABCNote,
                             _ events: inout [PlaybackEvent],
                             _ beat: inout Double,
                             _ velocity: inout Double,
                             _ pendingTies: inout [Int: Int]) {
        let dur = note.duration.value * 4
        if note.isRest {
            // A rest breaks any pending tie chain and advances the clock.
            pendingTies.removeAll()
            beat += dur
            return
        }
        var noteVelocity = velocity
        var accented = false
        for decoration in note.decorations {
            switch decoration {
            case .dynamic(let v, _):
                velocity = Double(v)        // persists for the voice
                noteVelocity = velocity
            case .accent:
                accented = true
            default:
                break
            }
        }
        if accented { noteVelocity = min(127, noteVelocity * 1.15) }

        // Grace notes: each takes 1/32 beat, the LAST one ending exactly at the
        // main note start. Clamped to ≥ 0.
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

        // Main pitches: extend a pending tied event of the same midi, else attack.
        var covered = Set<Int>()
        for pitch in note.pitches {
            covered.insert(pitch.midi)
            if let index = pendingTies[pitch.midi] {
                events[index].durationBeats += dur
                if !note.tieStart {
                    pendingTies.removeValue(forKey: pitch.midi)
                }
            } else {
                events.append(PlaybackEvent(elementID: note.id, midi: pitch.midi,
                                            startBeat: beat, durationBeats: dur,
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
}
