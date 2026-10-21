import Foundation
import AVFoundation
import Darwin

private final class TimingNode: AVAudioPlayerNode, @unchecked Sendable {
    var scheduledStart: UInt64?
    override func scheduleBuffer(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime?,
                                 options: AVAudioPlayerNodeBufferOptions = [],
                                 completionHandler: AVAudioNodeCompletionHandler? = nil) {}
    override func play(at when: AVAudioTime?) { scheduledStart = when?.hostTime }
    override func stop() {}
}

@main struct StartupBenchmark {
    static func main() throws {
        let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let tune = ABCBeaming.apply(to: ABCParser.parse(source)).tunes[0]
        let sequence = ABCSequencer.sequence(tune)
        let instruments = Dictionary(uniqueKeysWithValues: tune.voices.map {
            ($0.id, Instruments.namedInstrument(forPartName: $0.name) ?? Instruments.all[0])
        })
        let wait = Double(CommandLine.arguments[2])!
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let tickToMs = Double(info.numer) / Double(info.denom) / 1e6
        var results: [Double] = []
        for _ in 0..<7 {
            // Retain every track and observe their common scheduled start.
            var nodes: [TimingNode] = []
            let measured = PlaybackEngine(makePlayerNode: {
                let n = TimingNode(); nodes.append(n); return n
            })
            measured.load(sequence, instruments: instruments)
            RunLoop.current.run(until: Date().addingTimeInterval(wait))
            let tap = mach_absolute_time()
            measured.play()
            let returned = mach_absolute_time()
            let deadline = Date().addingTimeInterval(15)
            while nodes.first?.scheduledStart == nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
            guard let start = nodes.first?.scheduledStart else { fatalError("Startup timed out") }
            precondition(nodes.allSatisfy { $0.scheduledStart == start })
            results.append(Double(start - tap) * tickToMs)
            fputs(String(format: "run=%d play-return=%.3fms scheduled=%.3fms\n", results.count, Double(returned - tap) * tickToMs, results.last!), stderr)
            measured.stop()
        }
        print("tracks=\(sequence.tracks.count) events=\(sequence.tracks.reduce(0) { $0 + $1.events.count }) idle=\(wait)s")
        print("tap-to-scheduled-audio-ms: \(results.map { String(format: "%.3f", $0) }.joined(separator: ", ")) median=\(String(format: "%.3f", results.sorted()[3]))")
    }
}
