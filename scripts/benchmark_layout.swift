import Foundation

@main struct Benchmark {
    static func main() {
        let source = "X:1\nT:Layout benchmark\nM:4/4\nL:1/4\nK:C\n" + String(repeating: "C D E F | G A B c | ", count: 64)
        let tune = ABCBeaming.apply(to: ABCParser.parse(source)).tunes[0]
        func median(_ run: () -> EngravedScore) -> Double {
            var times: [Double] = []
            for _ in 0..<5 {
                let start = ProcessInfo.processInfo.systemUptime
                let score = run()
                times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                precondition(!score.shapes.isEmpty)
            }
            return times.sorted()[2]
        }
        let cache = ScoreLayoutCache()
        let baseline = median { ScoreEngraver.engrave(tune, width: 390) }
        let reused = median { cache.score(for: tune, width: 390, zoom: 1) }
        print(String(format: "layout512notes=%.3fms cached=%.3fms", baseline, reused))
    }
}
