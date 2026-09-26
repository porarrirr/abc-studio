import Foundation

/// PlaybackSequence → Standard MIDI File (format 1, division 480 ticks/qn)。
/// テンポマップはトラック0の tempo イベント、各パートは個別トラック。
/// 打楽器パートはチャンネル10(index 9)に振る。
public enum MIDIWriter {
    private static let division: UInt32 = 480

    public static func data(for sequence: PlaybackSequence,
                            instruments: [String: Instrument]) -> Data {
        var chunks: [Data] = []
        chunks.append(chunk(tempoTrackData()))
        var melodicChannel: UInt8 = 0
        for track in sequence.tracks {
            let channel: UInt8
            if track.isPercussion {
                channel = 9
            } else {
                channel = melodicChannel
                melodicChannel = min(15, melodicChannel + 1)
                if melodicChannel == 9 { melodicChannel = 10 }
            }
            let instrument = instruments[track.voiceID] ?? Instruments.all[0]
            chunks.append(chunk(voiceTrackData(track, channel: channel,
                                               program: instrument.program)))
        }

        var out = Data()
        out.append(contentsOf: "MThd".utf8)
        out.appendBE(UInt32(6))
        out.appendBE(UInt16(1))                    // format 1
        out.appendBE(UInt16(chunks.count))
        out.appendBE(UInt16(division))
        for c in chunks { out.append(c) }
        return out

        // --- helpers ---

        func tempoTrackData() -> Data {
            var events: [(tick: UInt32, bytes: [UInt8])] = []
            for point in sequence.tempoMap {
                let mpq = UInt32((60_000_000.0 / point.quarterNoteBPM).rounded())
                events.append((tick(of: point.beat),
                               [0xFF, 0x51, 0x03,
                                UInt8((mpq >> 16) & 0xFF),
                                UInt8((mpq >> 8) & 0xFF),
                                UInt8(mpq & 0xFF)]))
            }
            return encode(events)
        }

        func voiceTrackData(_ track: PlaybackTrack, channel: UInt8,
                            program: Int) -> Data {
            var events: [(tick: UInt32, order: Int, bytes: [UInt8])] = []
            // トラック名
            let nameBytes = Array(track.name.utf8)
            events.append((0, 0, [0xFF, 0x03] + varLen(nameBytes.count) + nameBytes))
            if !track.isPercussion, (0...127).contains(program) {
                events.append((0, 1, [0xC0 | channel, UInt8(program)]))
            }
            for e in track.events {
                let on = tick(of: e.startBeat)
                let off = tick(of: e.startBeat + e.durationBeats)
                let note = UInt8(max(0, min(127, e.midi)))
                let vel = UInt8(max(1, min(127, Int(e.velocity.rounded()))))
                events.append((on, 2, [0x90 | channel, note, vel]))
                events.append((off, 1, [0x80 | channel, note, 0x40]))
            }
            // 同時刻では note-off を先に(同音名の連続で重ならないよう)
            events.sort { ($0.tick, $0.order) < ($1.tick, $1.order) }
            return encode(events.map { ($0.tick, $0.bytes) })
        }

        func tick(of beat: Double) -> UInt32 {
            UInt32(max(0, (beat * Double(division)).rounded()))
        }

        func encode(_ events: [(tick: UInt32, bytes: [UInt8])]) -> Data {
            var data = Data()
            var last: UInt32 = 0
            for e in events {
                data.append(contentsOf: varLen(Int(e.tick - last)))
                data.append(contentsOf: e.bytes)
                last = e.tick
            }
            data.append(contentsOf: varLen(0))
            data.append(contentsOf: [0xFF, 0x2F, 0x00])
            return data
        }

        func chunk(_ body: Data) -> Data {
            var d = Data()
            d.append(contentsOf: "MTrk".utf8)
            d.appendBE(UInt32(body.count))
            d.append(body)
            return d
        }
    }

    /// MIDI 可変長数量
    private static func varLen(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var bytes: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            bytes.insert(UInt8(0x80 | (v & 0x7F)), at: 0)
            v >>= 7
        }
        return bytes
    }
}

private extension Data {
    /// ビッグエンディアンで整数を追加
    mutating func appendBE(_ v: UInt32) {
        append(contentsOf: [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                            UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
    mutating func appendBE(_ v: UInt16) {
        append(contentsOf: [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
}
