import Foundation
import AVFoundation

@main struct Benchmark {
    static func main() {
        func timed(_ run: () -> Void) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            run()
            return (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        var check: Float = 0
        func consume(_ b: AVAudioPCMBuffer?) {
            guard let b else { fatalError("Missing sample") }
            check += b.floatChannelData![0][Int(b.frameLength)/2]
        }
        let cold = SoundFontPlayer()
        let coldMs = timed {
            for midi in 60..<72 { consume(cold.makeBuffer(dir: "acoustic_grand_piano", midi: midi, seconds: 0.5, velocity: 80)) }
        }
        let player = SoundFontPlayer()
        for midi in 60..<72 { consume(player.makeBuffer(dir: "acoustic_grand_piano", midi: midi, seconds: 0.5, velocity: 80)) }
        var unique: [Double] = [], repeated: [Double] = []
        for run in 0..<3 {
            unique.append(timed {
                for i in 0..<72 {
                    consume(player.makeBuffer(dir: "acoustic_grand_piano", midi: 60 + i % 12,
                                               seconds: 0.31 + Double(i + run*72) * 0.0037, velocity: 75))
                }
            })
            repeated.append(timed {
                for i in 0..<72 {
                    consume(player.makeBuffer(dir: "acoustic_grand_piano", midi: 60 + i % 12,
                                               seconds: 0.5, velocity: 80))
                }
            })
        }
        print(String(format: "cold12=%.3fms unique72=%.3fms repeated72=%.3fms checksum=%.7f", coldMs, unique.sorted()[1], repeated.sorted()[1], check))
    }
}
