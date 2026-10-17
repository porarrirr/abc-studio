import Foundation

/// Exercises the timing work shared by playback prefetch and WAV export.
/// Compile with the app's ABCModel, ABCParser and ABCSequencer sources, using -O.
@main
enum TempoBenchmark {
    @inline(never)
    static func eventTiming(_ sequence: PlaybackSequence, repeats: Int) -> Double {
        var checksum = 0.0
        for _ in 0..<repeats {
            for track in sequence.tracks {
                for event in track.events {
                    let start = sequence.seconds(forBeat: event.startBeat)
                    let end = sequence.seconds(forBeat: event.startBeat + event.durationBeats)
                    checksum += start + (end - start)
                }
            }
        }
        return checksum
    }

    static func main() {
        for (measures, changingTempo) in [(16, true), (256, true), (1024, true), (1024, false)] {
            let body = (0..<measures).map {
                (changingTempo ? "[Q:1/4=\(80 + $0 % 81)] " : "") + "C D E F |"
            }.joined(separator: "\n")
            let source = "X:1\nT:Tempo benchmark\nM:4/4\nL:1/4\nK:C\n" + body
            let book = ABCParser.parse(source)
            precondition(!book.diagnostics.contains { $0.severity == .error })
            let sequence = ABCSequencer.sequence(book.tunes[0])
            let repeats = 100
            var samples: [Double] = []
            var checksum = eventTiming(sequence, repeats: 1)
            for _ in 0..<7 {
                let start = ProcessInfo.processInfo.systemUptime
                checksum += eventTiming(sequence, repeats: repeats)
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            print("measures=\(measures) tempos=\(sequence.tempoMap.count) events=\(sequence.tracks.reduce(0) { $0 + $1.events.count }) repeats=\(repeats) median_ms=\(String(format: "%.3f", samples.sorted()[3])) checksum=\(String(format: "%.6f", checksum))")
        }
    }
}
