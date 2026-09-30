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
        let assignedTracks: [(PlaybackTrack, Instrument)] = sequence.tracks.flatMap { track in
            let instrument = instruments[track.voiceID] ?? (track.isPercussion ? Instruments.all[6] : Instruments.all[0])
            if instrument.id == "cello_bass" {
                // 同梱合成音色と同じ二楽器を、MIDIでは独立チャンネルで鳴らす。
                return [(track, instrument), (track, Instruments.byID("contrabass")!)]
            }
            return [(track, instrument)]
        }
        for (track, instrument) in assignedTracks {
            let channel: UInt8
            if instrument.isDrums {
                channel = 9
            } else {
                channel = melodicChannel
                melodicChannel = min(15, melodicChannel + 1)
                if melodicChannel == 9 { melodicChannel = 10 }
            }
            chunks.append(chunk(voiceTrackData(track, channel: channel,
                                               instrument: instrument)))
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
            // 拍子メタイベント FF 58 04 nn dd cc bb(dd は分母の log2)
            for point in sequence.meterMap {
                if let (num, denPow) = MIDIWriter.timeSignatureBytes(point.meter) {
                    events.append((tick(of: point.beat),
                                   [0xFF, 0x58, 0x04, num, denPow, 24, 8]))
                }
            }
            // テンポイベントと拍子イベントをマージするため tick 順に揃える
            events.sort { $0.tick < $1.tick }
            return encode(events)
        }

        func voiceTrackData(_ track: PlaybackTrack, channel: UInt8,
                            instrument: Instrument) -> Data {
            var events: [(tick: UInt32, order: Int, bytes: [UInt8])] = []
            // トラック名
            let nameBytes = Array(track.name.utf8)
            events.append((0, 0, [0xFF, 0x03] + varLen(nameBytes.count) + nameBytes))
            if !instrument.isDrums, (0...127).contains(instrument.program) {
                events.append((0, 1, [0xC0 | channel, UInt8(instrument.program)]))
            }
            for e in track.events {
                let on = tick(of: e.startBeat)
                let off = tick(of: e.startBeat + e.durationBeats)
                let note = UInt8(max(0, min(127, instrument.soundingNote(e.midi))))
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

    /// SMF 拍子メタイベントの (分子, 分母の log2)。分母が2の冪でない拍子は出力しない。
    private static func timeSignatureBytes(_ meter: ABCMeter) -> (num: UInt8, denPow: UInt8)? {
        let pair: (Int, Int)?
        switch meter.style {
        case .common: pair = (4, 4)
        case .cut: pair = (2, 2)
        case .fraction(let n, let d): pair = (n, d)
        case .none: pair = nil
        }
        guard let (n, d) = pair, n > 0, n <= 255, d > 0, d <= 256, d & (d - 1) == 0 else {
            return nil
        }
        var pow = 0, v = d
        while v > 1 { v >>= 1; pow += 1 }
        return (UInt8(n), UInt8(pow))
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
