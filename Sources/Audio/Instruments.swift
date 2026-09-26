import Foundation

/// 音色定義。program は General MIDI のプログラム番号(0始まり)。128 は打楽器。
public struct Instrument: Hashable, Sendable {
    public var id: String
    public var label: String
    public var program: Int
    public var icon: String
    /// バンドル内の音色ディレクトリ名(SoundFont/<dir>/<音名>.mp3)
    public var soundFontDir: String

    public var isDrums: Bool { program == 128 }
}

public enum Instruments {
    public static let all: [Instrument] = [
        Instrument(id: "piano",   label: "ピアノ",   program: 0,   icon: "♩", soundFontDir: "acoustic_grand_piano-mp3"),
        Instrument(id: "guitar",  label: "ギター",   program: 24,  icon: "♮", soundFontDir: "acoustic_guitar_nylon-mp3"),
        Instrument(id: "violin",  label: "バイオリン", program: 40, icon: "𝄞", soundFontDir: "violin-mp3"),
        Instrument(id: "flute",   label: "フルート", program: 73,  icon: "♫", soundFontDir: "flute-mp3"),
        Instrument(id: "trumpet", label: "トランペット", program: 56, icon: "♬", soundFontDir: "trumpet-mp3"),
        Instrument(id: "bass",    label: "ベース",   program: 33,  icon: "𝄢", soundFontDir: "electric_bass_finger-mp3"),
        Instrument(id: "drums",   label: "ドラム",   program: 128, icon: "✳", soundFontDir: "percussion-mp3"),
        Instrument(id: "choir",   label: "合唱",     program: 52,  icon: "♪", soundFontDir: "choir_aahs-mp3"),
    ]

    public static func byID(_ id: String) -> Instrument? {
        all.first { $0.id == id }
    }

    /// パート名から音色を推測(app.js の guessInstrument 相当)
    public static func guess(forPartName name: String) -> Instrument {
        let n = name.lowercased()
        if n.contains("guitar") || n.contains("ギター") { return all[1] }
        if n.contains("violin") || n.contains("fiddle") || n.contains("バイオリン") { return all[2] }
        if n.contains("flute") || n.contains("フルート") { return all[3] }
        if n.contains("trumpet") || n.contains("トランペット") { return all[4] }
        if n.contains("bass") || n.contains("ベース") { return all[5] }
        if n.contains("drum") || n.contains("percussion") || n.contains("ドラム") { return all[6] }
        if n.contains("choir") || n.contains("voice") || n.contains("vocal") || n.contains("合唱") { return all[7] }
        return all[0]
    }
}

/// MIDI 番号と音色ファイル名の相互変換。C4=60 を基準。
public enum MIDINoteName {
    private static let sharps = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    /// MIDI 番号 → ファイル名に使う音名(フラット系表記、C4=60)。例: 42 → "Gb2" ... 42=F#2→Gb2
    public static func name(for midi: Int) -> String {
        let octave = midi / 12 - 1
        return sharps[max(0, min(127, midi)) % 12] + String(octave)
    }
}
