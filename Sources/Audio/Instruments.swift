import Foundation

/// General MIDI のプログラム番号は0始まり。128は打楽器キット。
public struct Instrument: Hashable, Sendable {
    public var id: String
    public var label: String
    public var program: Int
    public var icon: String
    public var soundFontDir: String
    public var category: String = "その他"
    public var aliases: [String] = []
    /// 単独の無音程打楽器は、譜面の高さによらずこのGMキーを鳴らす。
    public var percussionNote: Int? = nil
    public var isDrums: Bool { program == 128 }
    public func soundingNote(_ midi: Int) -> Int { percussionNote ?? midi }
}

public enum Instruments {
    public static let categories = ["鍵盤", "弦楽器", "木管楽器", "金管楽器", "ギター・ベース", "有音程打楽器", "打楽器", "声楽", "電子楽器"]
    public static let all: [Instrument] = [
        Instrument(id: "piano", label: "ピアノ", program: 0, icon: "♫", soundFontDir: "acoustic_grand_piano", category: "鍵盤", aliases: ["piano", "pianoforte", "ピアノ"]),
        Instrument(id: "guitar", label: "クラシックギター", program: 24, icon: "♫", soundFontDir: "acoustic_guitar_nylon", category: "ギター・ベース", aliases: ["classical guitar", "nylon guitar", "guitar", "chitarra", "ギター"]),
        Instrument(id: "violin", label: "バイオリン", program: 40, icon: "𝄞", soundFontDir: "violin", category: "弦楽器", aliases: ["violin", "violino", "violini", "violon", "fiddle", "バイオリン", "ヴァイオリン", "vn", "vln"]),
        Instrument(id: "flute", label: "フルート", program: 73, icon: "♫", soundFontDir: "flute", category: "木管楽器", aliases: ["flute", "flauto", "flauti", "flöte", "フルート", "fl"]),
        Instrument(id: "trumpet", label: "トランペット", program: 56, icon: "♫", soundFontDir: "trumpet", category: "金管楽器", aliases: ["trumpet", "tromba", "trombe", "trompette", "トランペット", "tp", "tpt"]),
        Instrument(id: "bass", label: "エレキベース", program: 33, icon: "𝄢", soundFontDir: "electric_bass_finger", category: "ギター・ベース", aliases: ["electric bass", "bass guitar", "bass", "エレキベース", "ベース"]),
        Instrument(id: "drums", label: "ドラム／打楽器セット", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["drum", "drums", "drum kit", "percussion", "batteria", "打楽器", "ドラム"]),
        Instrument(id: "choir", label: "合唱", program: 52, icon: "♫", soundFontDir: "choir_aahs", category: "声楽", aliases: ["choir", "chorus", "coro", "voice", "vocal", "soprano", "alto voice", "tenor voice", "baritone voice", "合唱", "声楽"]),
        Instrument(id: "viola", label: "ビオラ", program: 41, icon: "𝄞", soundFontDir: "viola", category: "弦楽器", aliases: ["viola", "viole", "ビオラ", "ヴィオラ", "va"]),
        Instrument(id: "cello", label: "チェロ", program: 42, icon: "𝄢", soundFontDir: "cello", category: "弦楽器", aliases: ["cello", "violoncello", "violoncelli", "violoncelle", "チェロ", "vc"]),
        Instrument(id: "contrabass", label: "コントラバス", program: 43, icon: "𝄢", soundFontDir: "contrabass", category: "弦楽器", aliases: ["contrabass", "contrabbasso", "contrabbassi", "double bass", "upright bass", "string bass", "basso", "bassi", "コントラバス", "ウッドベース", "cb", "db"]),
        Instrument(id: "cello_bass", label: "チェロ＋コントラバス", program: 42, icon: "𝄢", soundFontDir: "cello_contrabass", category: "弦楽器", aliases: ["violoncello e basso", "violoncelli e bassi", "cello and bass", "チェロとコントラバス"]),
        Instrument(id: "pizzicato", label: "ピチカート弦楽器", program: 45, icon: "𝄞", soundFontDir: "pizzicato_strings", category: "弦楽器", aliases: ["pizzicato", "pizz", "ピチカート"]),
        Instrument(id: "tremolo_strings", label: "トレモロ弦楽器", program: 44, icon: "𝄞", soundFontDir: "tremolo_strings", category: "弦楽器", aliases: ["tremolo strings", "トレモロ弦楽器"]),
        Instrument(id: "strings", label: "弦楽合奏", program: 48, icon: "𝄞", soundFontDir: "string_ensemble_1", category: "弦楽器", aliases: ["string ensemble", "strings", "archi", "弦楽合奏"]),
        Instrument(id: "harp", label: "ハープ", program: 46, icon: "𝄞", soundFontDir: "orchestral_harp", category: "弦楽器", aliases: ["harp", "arpa", "harfe", "ハープ"]),
        Instrument(id: "piccolo", label: "ピッコロ", program: 72, icon: "♫", soundFontDir: "piccolo", category: "木管楽器", aliases: ["piccolo", "ottavino", "ピッコロ", "picc"]),
        Instrument(id: "oboe", label: "オーボエ", program: 68, icon: "♫", soundFontDir: "oboe", category: "木管楽器", aliases: ["oboe", "oboi", "hautbois", "オーボエ", "ob"]),
        Instrument(id: "english_horn", label: "イングリッシュホルン", program: 69, icon: "♫", soundFontDir: "english_horn", category: "木管楽器", aliases: ["english horn", "cor anglais", "corno inglese", "イングリッシュホルン"]),
        Instrument(id: "bassoon", label: "ファゴット", program: 70, icon: "𝄢", soundFontDir: "bassoon", category: "木管楽器", aliases: ["bassoon", "fagotto", "fagotti", "fagott", "basson", "ファゴット", "バスーン", "bn", "bsn", "fg"]),
        Instrument(id: "clarinet", label: "クラリネット", program: 71, icon: "♫", soundFontDir: "clarinet", category: "木管楽器", aliases: ["clarinet", "clarinetto", "clarinetti", "klarinette", "クラリネット", "cl"]),
        Instrument(id: "soprano_sax", label: "ソプラノサックス", program: 64, icon: "♫", soundFontDir: "soprano_sax", category: "木管楽器", aliases: ["soprano sax", "soprano saxophone", "ソプラノサックス"]),
        Instrument(id: "alto_sax", label: "アルトサックス", program: 65, icon: "♫", soundFontDir: "alto_sax", category: "木管楽器", aliases: ["alto sax", "alto saxophone", "saxophone", "sax", "アルトサックス", "サックス"]),
        Instrument(id: "tenor_sax", label: "テナーサックス", program: 66, icon: "♫", soundFontDir: "tenor_sax", category: "木管楽器", aliases: ["tenor sax", "tenor saxophone", "テナーサックス"]),
        Instrument(id: "baritone_sax", label: "バリトンサックス", program: 67, icon: "♫", soundFontDir: "baritone_sax", category: "木管楽器", aliases: ["baritone sax", "baritone saxophone", "バリトンサックス"]),
        Instrument(id: "recorder", label: "リコーダー", program: 74, icon: "♫", soundFontDir: "recorder", category: "木管楽器", aliases: ["recorder", "blockflöte", "リコーダー"]),
        Instrument(id: "horn", label: "ホルン", program: 60, icon: "♫", soundFontDir: "french_horn", category: "金管楽器", aliases: ["french horn", "horn", "corno", "corni", "ホルン", "hn"]),
        Instrument(id: "trombone", label: "トロンボーン", program: 57, icon: "♫", soundFontDir: "trombone", category: "金管楽器", aliases: ["trombone", "tromboni", "トロンボーン", "tb", "tbn"]),
        Instrument(id: "tuba", label: "チューバ", program: 58, icon: "♫", soundFontDir: "tuba", category: "金管楽器", aliases: ["tuba", "tube", "チューバ", "テューバ"]),
        Instrument(id: "muted_trumpet", label: "ミュートトランペット", program: 59, icon: "♫", soundFontDir: "muted_trumpet", category: "金管楽器", aliases: ["muted trumpet", "trumpet muted", "ミュートトランペット"]),
        Instrument(id: "electric_piano", label: "エレクトリックピアノ", program: 4, icon: "♫", soundFontDir: "electric_piano_1", category: "鍵盤", aliases: ["electric piano", "rhodes", "エレクトリックピアノ", "エレピ"]),
        Instrument(id: "fm_piano", label: "FMエレクトリックピアノ", program: 5, icon: "♫", soundFontDir: "electric_piano_2", category: "鍵盤", aliases: ["fm piano", "fm electric piano"]),
        Instrument(id: "harpsichord", label: "チェンバロ", program: 6, icon: "♫", soundFontDir: "harpsichord", category: "鍵盤", aliases: ["harpsichord", "cembalo", "clavicembalo", "clavecin", "チェンバロ"]),
        Instrument(id: "clavinet", label: "クラビネット", program: 7, icon: "♫", soundFontDir: "clavinet", category: "鍵盤", aliases: ["clavinet", "クラビネット"]),
        Instrument(id: "celesta", label: "チェレスタ", program: 8, icon: "♫", soundFontDir: "celesta", category: "鍵盤", aliases: ["celesta", "célesta", "チェレスタ"]),
        Instrument(id: "organ", label: "パイプオルガン", program: 19, icon: "♫", soundFontDir: "church_organ", category: "鍵盤", aliases: ["pipe organ", "church organ", "organ", "organo", "オルガン"]),
        Instrument(id: "jazz_organ", label: "ジャズオルガン", program: 16, icon: "♫", soundFontDir: "drawbar_organ", category: "鍵盤", aliases: ["hammond", "drawbar organ", "jazz organ", "ハモンド"]),
        Instrument(id: "accordion", label: "アコーディオン", program: 21, icon: "♫", soundFontDir: "accordion", category: "鍵盤", aliases: ["accordion", "fisarmonica", "アコーディオン"]),
        Instrument(id: "steel_guitar", label: "アコースティックギター（スチール）", program: 25, icon: "♫", soundFontDir: "acoustic_guitar_steel", category: "ギター・ベース", aliases: ["steel guitar", "acoustic guitar", "アコースティックギター"]),
        Instrument(id: "jazz_guitar", label: "ジャズギター", program: 26, icon: "♫", soundFontDir: "electric_guitar_jazz", category: "ギター・ベース", aliases: ["jazz guitar", "ジャズギター"]),
        Instrument(id: "electric_guitar", label: "エレキギター", program: 27, icon: "♫", soundFontDir: "electric_guitar_clean", category: "ギター・ベース", aliases: ["electric guitar", "エレキギター"]),
        Instrument(id: "muted_guitar", label: "ミュートギター", program: 28, icon: "♫", soundFontDir: "electric_guitar_muted", category: "ギター・ベース", aliases: ["muted guitar", "ミュートギター"]),
        Instrument(id: "distortion_guitar", label: "ディストーションギター", program: 30, icon: "♫", soundFontDir: "distortion_guitar", category: "ギター・ベース", aliases: ["distortion guitar", "ディストーションギター"]),
        Instrument(id: "acoustic_bass", label: "アコースティックベース（撥弦）", program: 32, icon: "𝄢", soundFontDir: "acoustic_bass", category: "ギター・ベース", aliases: ["acoustic bass", "アコースティックベース"]),
        Instrument(id: "picked_bass", label: "ピックベース", program: 34, icon: "𝄢", soundFontDir: "electric_bass_pick", category: "ギター・ベース", aliases: ["picked bass", "pick bass", "ピックベース"]),
        Instrument(id: "fretless_bass", label: "フレットレスベース", program: 35, icon: "𝄢", soundFontDir: "fretless_bass", category: "ギター・ベース", aliases: ["fretless bass", "フレットレスベース"]),
        Instrument(id: "banjo", label: "バンジョー", program: 105, icon: "♫", soundFontDir: "banjo", category: "ギター・ベース", aliases: ["banjo", "バンジョー"]),
        Instrument(id: "timpani", label: "ティンパニ", program: 47, icon: "♫", soundFontDir: "timpani", category: "有音程打楽器", aliases: ["timpani", "timpano", "pauken", "ティンパニ"]),
        Instrument(id: "glockenspiel", label: "グロッケンシュピール", program: 9, icon: "♫", soundFontDir: "glockenspiel", category: "有音程打楽器", aliases: ["glockenspiel", "glock", "グロッケン", "鉄琴"]),
        Instrument(id: "vibraphone", label: "ビブラフォン", program: 11, icon: "♫", soundFontDir: "vibraphone", category: "有音程打楽器", aliases: ["vibraphone", "vibes", "vibrafono", "ビブラフォン", "ヴィブラフォン"]),
        Instrument(id: "marimba", label: "マリンバ", program: 12, icon: "♫", soundFontDir: "marimba", category: "有音程打楽器", aliases: ["marimba", "マリンバ"]),
        Instrument(id: "xylophone", label: "シロフォン", program: 13, icon: "♫", soundFontDir: "xylophone", category: "有音程打楽器", aliases: ["xylophone", "xilofono", "シロフォン", "木琴"]),
        Instrument(id: "tubular_bells", label: "チューブラーベル", program: 14, icon: "♫", soundFontDir: "tubular_bells", category: "有音程打楽器", aliases: ["tubular bells", "chimes", "campane", "チューブラーベル", "チャイム"]),
        Instrument(id: "dulcimer", label: "ダルシマー", program: 15, icon: "♫", soundFontDir: "dulcimer", category: "有音程打楽器", aliases: ["dulcimer", "cimbalom", "ダルシマー"]),
        Instrument(id: "steel_drums", label: "スティールパン", program: 114, icon: "♫", soundFontDir: "steel_drums", category: "有音程打楽器", aliases: ["steel drums", "steel pan", "スティールパン"]),
        Instrument(id: "woodblock", label: "ウッドブロック（有音程）", program: 115, icon: "♫", soundFontDir: "woodblock", category: "有音程打楽器", aliases: ["pitched woodblock", "有音程ウッドブロック"]),
        Instrument(id: "taiko", label: "太鼓（有音程）", program: 116, icon: "♫", soundFontDir: "taiko_drum", category: "有音程打楽器", aliases: ["taiko", "太鼓"]),
        Instrument(id: "bass_drum", label: "大太鼓", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["bass drum", "gran cassa", "grancassa", "grosse caisse", "大太鼓"], percussionNote: 36),
        Instrument(id: "snare", label: "小太鼓", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["snare drum", "snare", "side drum", "tamburo piccolo", "小太鼓", "スネア"], percussionNote: 38),
        Instrument(id: "cymbal", label: "シンバル", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["cymbal", "cymbals", "piatti", "シンバル"], percussionNote: 49),
        Instrument(id: "ride_cymbal", label: "ライドシンバル", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["ride cymbal", "ライドシンバル"], percussionNote: 51),
        Instrument(id: "hi_hat", label: "ハイハット", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["hi hat", "hihat", "hi-hat", "ハイハット"], percussionNote: 42),
        Instrument(id: "tambourine", label: "タンバリン", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["tambourine", "tamburello", "タンバリン"], percussionNote: 54),
        Instrument(id: "triangle", label: "トライアングル", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["triangle", "triangolo", "トライアングル"], percussionNote: 81),
        Instrument(id: "cowbell", label: "カウベル", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["cowbell", "カウベル"], percussionNote: 56),
        Instrument(id: "conga", label: "コンガ", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["conga", "コンガ"], percussionNote: 64),
        Instrument(id: "bongo", label: "ボンゴ", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["bongo", "ボンゴ"], percussionNote: 60),
        Instrument(id: "timbales", label: "ティンバレス", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["timbales", "ティンバレス"], percussionNote: 65),
        Instrument(id: "claves", label: "クラベス", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["claves", "クラベス"], percussionNote: 75),
        Instrument(id: "wood_block", label: "ウッドブロック", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["wood block", "woodblock", "ウッドブロック"], percussionNote: 76),
        Instrument(id: "castanets", label: "カスタネット（Fluid拡張）", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["castanets", "castagnette", "カスタネット"], percussionNote: 85),
        Instrument(id: "maracas", label: "マラカス", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["maracas", "マラカス"], percussionNote: 70),
        Instrument(id: "cabasa", label: "カバサ", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["cabasa", "カバサ"], percussionNote: 69),
        Instrument(id: "guiro", label: "ギロ", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["guiro", "ギロ"], percussionNote: 74),
        Instrument(id: "vibraslap", label: "ビブラスラップ", program: 128, icon: "✳", soundFontDir: "percussion", category: "打楽器", aliases: ["vibraslap", "ビブラスラップ"], percussionNote: 58),
        Instrument(id: "synth_lead", label: "シンセサイザー（リード）", program: 80, icon: "♫", soundFontDir: "lead_1_square", category: "電子楽器", aliases: ["synth lead", "synthesizer", "synth", "シンセサイザー"]),
        Instrument(id: "synth_pad", label: "シンセサイザー（パッド）", program: 88, icon: "♫", soundFontDir: "pad_1_new_age", category: "電子楽器", aliases: ["synth pad", "pad", "シンセパッド"]),
        Instrument(id: "synth_strings", label: "シンセストリングス", program: 50, icon: "♫", soundFontDir: "synth_strings_1", category: "電子楽器", aliases: ["synth strings", "シンセストリングス"]),
    ]

    public static func byID(_ id: String) -> Instrument? {
        all.first { $0.id == id }
    }

    /// 長い楽器名を優先し、単語境界を照合する。ViolaとViolin、BassoonとBassを混同しない。
    public static func guess(forPartName name: String) -> Instrument {
        namedInstrument(forPartName: name) ?? all[0]
    }

    public static func namedInstrument(forPartName name: String) -> Instrument? {
        let normalized = normalize(name)
        let matches = all.flatMap { instrument in
            instrument.aliases.map { (instrument, normalize($0)) }
        }.sorted { $0.1.count > $1.1.count }
        for (instrument, alias) in matches {
            let pattern = "(?<![a-z])" + NSRegularExpression.escapedPattern(for: alias) + "(?![a-z])"
            if normalized.range(of: pattern, options: .regularExpression) != nil { return instrument }
        }
        return nil
    }

    private static func normalize(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[-_.]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
