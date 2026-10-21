import Foundation
import CoreGraphics

@main struct UIBenchmark {
    static func median(_ run: () -> Int) -> Double {
        var times: [Double] = []
        var checksum = 0
        for _ in 0..<7 {
            let start = ProcessInfo.processInfo.systemUptime
            checksum += run()
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        precondition(checksum > 0)
        return times.sorted()[3]
    }

    static func main() {
        let voices = (0..<8).map { "v\($0)" }
        var abc = "X:1\nT:UI benchmark\nM:4/4\nL:1/8\n%%score " + voices.joined(separator: " ") + "\n"
        for voice in voices { abc += "V:\(voice) name=\"Part \(voice)\"\n" }
        abc += "K:C\n"
        for voice in voices { abc += "[V:\(voice)] " + String(repeating: "CDEF GABc | cBAG FEDC | ", count: 4) + "\n" }
        let tune = ABCBeaming.apply(to: ABCParser.parse(abc)).tunes[0]
        let score = ScoreEngraver.engrave(tune, width: 390)
        let system = 0
        let ids = score.targets.filter { $0.value.system == system }.keys.sorted()
        let band = score.systems[system].band
        let ctx = CGContext(data: nil, width: Int(band.width.rounded(.up)),
                            height: Int(band.height.rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let columns = Dictionary(grouping: ids) { Int((score.targets[$0]!.rect.midX * 10).rounded()) }
            .sorted { $0.key < $1.key }.map { Set($0.value) }
        let frames = 120
        let full = median {
            for frame in 0..<frames {
                let active = columns[frame % columns.count]
                let id = active.min()!
                ScorePainter.drawYDown(score, in: ctx, highlight: active, cursorID: id, system: system)
            }
            return frames
        }
        // The unchanged staff Canvas retains its display list. Measure the two
        // Canvas layers invalidated by playback, excluding GPU composition.
        let layered = median {
            for frame in 0..<frames {
                let active = columns[frame % columns.count]
                let id = active.min()!
                ScorePainter.drawCursorYDown(score, in: ctx, cursorID: id, system: system)
                ScorePainter.drawHighlightsYDown(score, in: ctx, highlight: active, system: system)
            }
            return frames
        }
        print(String(format: "cursor120frames full=%.3fms layers=%.3fms reduction=%.2f%%", full, layered, 100 * (1 - layered / full)))

        let source = String(repeating: "V:one name=\"Violin\"\nCDEF GABc | % comment\n", count: 2500)
        let location = (source as NSString).range(of: "GABc").location
        let whole = median {
            var spans = 0
            for _ in 0..<50 {
                spans += SourceSyntax.plan(in: source).spans.count
                    + source.components(separatedBy: .newlines).count
            }
            return spans
        }
        let incremental = median {
            var spans = 0
            for _ in 0..<50 {
                spans += SourceSyntax.plan(in: source, editedRange: NSRange(location: location, length: 1)).spans.count
                    + SourceSyntax.lineCount(in: source)
            }
            return spans
        }
        print(String(format: "syntax50edits full=%.3fms line=%.3fms reduction=%.2f%%", whole, incremental, 100 * (1 - incremental / whole)))
    }
}
