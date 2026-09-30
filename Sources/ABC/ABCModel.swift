import Foundation

/// 正規化された有理数。音価(全音符=1)や拍子の表現に使う。
public struct ABCFraction: Hashable, Comparable, Sendable, CustomStringConvertible {
    public private(set) var num: Int
    public private(set) var den: Int

    public init(_ num: Int, _ den: Int) {
        precondition(den != 0, "denominator must not be zero")
        let n = den < 0 ? -num : num
        let d = abs(den)
        let g = ABCFraction.gcd(abs(n), d)
        self.num = n / g
        self.den = d / g
    }

    public var value: Double { Double(num) / Double(den) }
    public var isZero: Bool { num == 0 }
    public var description: String { den == 1 ? "\(num)" : "\(num)/\(den)" }

    public static func + (a: ABCFraction, b: ABCFraction) -> ABCFraction {
        ABCFraction(a.num * b.den + b.num * a.den, a.den * b.den)
    }
    public static func - (a: ABCFraction, b: ABCFraction) -> ABCFraction {
        ABCFraction(a.num * b.den - b.num * a.den, a.den * b.den)
    }
    public static func * (a: ABCFraction, b: ABCFraction) -> ABCFraction {
        ABCFraction(a.num * b.num, a.den * b.den)
    }
    public static func * (a: ABCFraction, b: Int) -> ABCFraction {
        ABCFraction(a.num * b, a.den)
    }
    public static func / (a: ABCFraction, b: ABCFraction) -> ABCFraction {
        ABCFraction(a.num * b.den, a.den * b.num)
    }
    public static func == (a: ABCFraction, b: ABCFraction) -> Bool {
        a.num == b.num && a.den == b.den
    }
    public static func < (a: ABCFraction, b: ABCFraction) -> Bool {
        a.num * b.den < b.num * a.den
    }
    public static func <= (a: ABCFraction, b: ABCFraction) -> Bool {
        a.num * b.den <= b.num * a.den
    }
    public static func > (a: ABCFraction, b: ABCFraction) -> Bool {
        a.num * b.den > b.num * a.den
    }
    public static func >= (a: ABCFraction, b: ABCFraction) -> Bool {
        a.num * b.den >= b.num * a.den
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? max(1, a) : gcd(b, a % b)
    }
}

/// 書き込まれた臨時記号。midi への反映はパーサ済み。描画用に保持する。
public enum ABCAccidental: String, Sendable {
    case sharp, flat, natural, doubleSharp, doubleFlat

    /// 半音変化量
    public var semitones: Int {
        switch self {
        case .sharp: return 1
        case .flat: return -1
        case .natural: return 0
        case .doubleSharp: return 2
        case .doubleFlat: return -2
        }
    }
}

public enum ABCClef: Sendable {
    case treble, bass, alto, tenor, percussion

    /// 五線の最下線に相当する diatonic step(C4=0)。step→五線上の段位置変換に使う。
    /// treble: E4(2), bass: G2(-10), alto: F3(-4), tenor: D3(-6)
    public var bottomLineStep: Int {
        switch self {
        case .treble: return 2
        case .bass: return -10
        case .alto: return -4
        case .tenor: return -6
        case .percussion: return 2
        }
    }
}

/// 調号。accidentals は描画順(シャープ系は F,C,G,D,A,E,B / フラット系は B,E,A,D,G,C,F)。
public struct ABCKeySignature: Sendable {
    /// 表示名("C"、"Dm"、"Bb" など)
    public var display: String
    /// 調号として五線に描く臨時記号。letter は C=0,D=1,...B=6 の音名。
    public var accidentals: [(letter: Int, accidental: ABCAccidental)]
    /// K:C perc など打楽器調
    public var isPercussion: Bool

    public init(display: String, accidentals: [(letter: Int, accidental: ABCAccidental)], isPercussion: Bool = false) {
        self.display = display
        self.accidentals = accidentals
        self.isPercussion = isPercussion
    }

    public static let cMajor = ABCKeySignature(display: "C", accidentals: [])
}

public struct ABCMeter: Sendable {
    public enum Style: Sendable {
        case common                // C
        case cut                   // C|
        case fraction(num: Int, den: Int)
        case none                  // M:none
    }
    public var style: Style

    /// 1小節の長さ(全音符=1)。4/4→1, 3/4→3/4, 6/8→3/4
    public var measureLength: ABCFraction
    /// ビームのまとめ単位(複合拍子は3/8、それ以外は分母音符)。自動ビームに使う。
    public var beamUnit: ABCFraction
    /// 表示用文字列("4/4", "C", "C|", "")
    public var display: String

    public static let commonTime = ABCMeter(style: .common, measureLength: ABCFraction(1, 1),
                                            beamUnit: ABCFraction(1, 4), display: "C")

    public init(style: Style, measureLength: ABCFraction, beamUnit: ABCFraction, display: String) {
        self.style = style
        self.measureLength = measureLength
        self.beamUnit = beamUnit
        self.display = display
    }

    public init(num: Int, den: Int) {
        let length = ABCFraction(num, den)
        let compound = num % 3 == 0 && den >= 8 && num > 3
        self.init(style: .fraction(num: num, den: den), measureLength: length,
                  beamUnit: compound ? ABCFraction(3, den) : ABCFraction(1, den),
                  display: "\(num)/\(den)")
    }
}

/// Q: テンポ指定。unit 音符が bpm 回/分。
public struct ABCTempo: Sendable {
    public var unit: ABCFraction
    public var bpm: Double
    public var text: String?        // "Allegro" など曲想表示
    public init(unit: ABCFraction = ABCFraction(1, 4), bpm: Double = 120, text: String? = nil) {
        self.unit = unit; self.bpm = bpm; self.text = text
    }
    /// 1拍(四分音符)あたりの bpm 換算
    public var quarterNoteBPM: Double { bpm * (unit.value / 0.25) }
}

public enum ABCRestKind: Sendable {
    case none        // 音符(休符ではない)
    case normal      // z
    case measure     // Z(全休符・複数小節休符。duration=小節数×小節長)
    case invisible   // x(音を出さず空白のみ)
    case spacer      // y(描画スペースのみ)
}

/// 音符の見た目タイプ(符頭/符尾の種別)。duration とは別:連符等で実音価と表示がずれる。
public enum ABCNoteGlyph: Sendable {
    case whole, half, quarter, eighth, sixteenth, thirtySecond, sixtyFourth

    /// 基本音価(全音符=1)
    public var baseDuration: ABCFraction {
        switch self {
        case .whole: return ABCFraction(1, 1)
        case .half: return ABCFraction(1, 2)
        case .quarter: return ABCFraction(1, 4)
        case .eighth: return ABCFraction(1, 8)
        case .sixteenth: return ABCFraction(1, 16)
        case .thirtySecond: return ABCFraction(1, 32)
        case .sixtyFourth: return ABCFraction(1, 64)
        }
    }
    /// 符尾フラグ数(ビーム/フラグ描画用)。quarter 以下は 0。
    public var flagCount: Int {
        switch self {
        case .whole, .half, .quarter: return 0
        case .eighth: return 1
        case .sixteenth: return 2
        case .thirtySecond: return 3
        case .sixtyFourth: return 4
        }
    }
}

/// 1つの音高。step は中央のC(C4)=0 の全音階ステップ(C=0,D=1,...B=6,c=7,...)。
public struct ABCPitch: Sendable {
    /// 全音階ステップ(C4=0)。五線位置の計算に使う。
    public var step: Int
    /// 絶対半音高(C4=60)。調号・書き込み臨時記号を反映済み。percussion 声部では GM ドラム番号。
    public var midi: Int
    /// 書き込まれた臨時記号(調号由来は含まない)。描画判定に使う。
    public var accidental: ABCAccidental?

    public init(step: Int, midi: Int, accidental: ABCAccidental? = nil) {
        self.step = step; self.midi = midi; self.accidental = accidental
    }
}

/// 装飾記号(主要なもののみ)
public enum ABCDecoration: Sendable {
    case staccato, accent, tenuto, fermata, trill, mordent, roll, upbow, downbow, breath, crescendoStart, crescendoEnd, diminuendoStart, diminuendoEnd
    /// !ppp! などの強弱記号(音量値 0-127 目安)
    case dynamic(velocity: Int, label: String)
}

public struct ABCTuplet: Sendable {
    public var n: Int          // (3 → 3連符
    public var isFirst: Bool   // 連符グループ先頭
    public var isLast: Bool    // 連符グループ末尾
}

public struct ABCLyric: Sendable {
    public var syllable: String
    public var hyphenAfter: Bool    // 後続音節との間にハイフン
    public var underscoreAfter: Bool // メリスマ伸ばし(_)
}

/// 音符または休符。id は曲内で一意(カーソル/ハイライト対応付けに使う)。
public struct ABCNote: Sendable {
    public var id: Int
    /// 和音なら複数。休符なら空。
    public var pitches: [ABCPitch]
    public var rest: ABCRestKind
    /// 符頭タイプ(表示用)
    public var glyph: ABCNoteGlyph
    /// 付点数(表示用)
    public var dots: Int
    /// 実際に鳴る長さ(全音符=1)。連符・ broken rhythm を反映済み。
    public var duration: ABCFraction
    /// タイで次の同じ高さの音に繋がる
    public var tieStart: Bool
    /// 開始/終了するスラーの数(0=なし)
    public var slurStarts: Int
    public var slurEnds: Int
    /// ビームグループの先頭/末尾
    public var beamStart: Bool
    public var beamEnd: Bool
    /// 直前に空白がある(ABC では空白がビームを切断する)。自動ビームの境界に使う。
    public var spaceBefore: Bool
    /// 装飾
    public var decorations: [ABCDecoration]
    /// コード記号("G7" など、五線上部に表示)
    public var chordSymbol: String?
    /// 歌詞音節(w: 行から割当)
    public var lyric: ABCLyric?
    /// 前打音
    public var graceNotes: [ABCNote]
    /// 連符情報(グループ内の各音符に付く)
    public var tuplet: ABCTuplet?
    /// この要素のソース範囲(ファイル全体のUTF-8オフセット、ソースジャンプ用)
    public var sourceStart: Int
    public var sourceEnd: Int
    /// ファイル基準のソース行番号(1始まり、診断ジャンプ用)
    public var line: Int

    public init(id: Int, pitches: [ABCPitch], rest: ABCRestKind, glyph: ABCNoteGlyph,
                dots: Int, duration: ABCFraction, tieStart: Bool = false,
                slurStarts: Int = 0, slurEnds: Int = 0,
                beamStart: Bool = false, beamEnd: Bool = false,
                decorations: [ABCDecoration] = [], chordSymbol: String? = nil,
                lyric: ABCLyric? = nil, graceNotes: [ABCNote] = [],
                tuplet: ABCTuplet? = nil, sourceStart: Int = 0, sourceEnd: Int = 0, line: Int = 0,
                spaceBefore: Bool = false) {
        self.id = id; self.pitches = pitches; self.rest = rest; self.glyph = glyph
        self.dots = dots; self.duration = duration; self.tieStart = tieStart
        self.slurStarts = slurStarts; self.slurEnds = slurEnds
        self.beamStart = beamStart; self.beamEnd = beamEnd
        self.spaceBefore = spaceBefore
        self.decorations = decorations; self.chordSymbol = chordSymbol
        self.lyric = lyric; self.graceNotes = graceNotes; self.tuplet = tuplet
        self.sourceStart = sourceStart; self.sourceEnd = sourceEnd; self.line = line
    }

    /// 休符またはスペーサか
    public var isRest: Bool { rest != .none }
}

/// 小節線
public struct ABCBar: Sendable {
    public enum Kind: Sendable {
        case plain         // |
        case double        // || (細線2本)
        case final         // |] (細線+太線、終止線)
        case repeatStart   // |:
        case repeatEnd     // :|
        case repeatBoth    // :|: または ::
    }
    public var kind: Kind
    /// 繰返しの括弧番号(|1 → [1]、|1,2 → [1,2])。この小節線の直後が括弧開始。
    public var endings: [Int]
    public var line: Int

    public init(kind: Kind, endings: [Int] = [], line: Int = 0) {
        self.kind = kind; self.endings = endings; self.line = line
    }
}

/// 曲中のインラインフィールド変更 [M:3/4] [K:G] [Q:1/4=120] [L:1/8]
public enum ABCFieldChange: Sendable {
    case meter(ABCMeter)
    case key(ABCKeySignature)
    case tempo(ABCTempo)
    case noteLength(ABCFraction)
}

public enum ABCElement: Sendable {
    case note(ABCNote)
    case bar(ABCBar)
    case fieldChange(ABCFieldChange)
}

/// 1声部。elements は時系列順。小節線も含む。
public struct ABCVoice: Sendable {
    public var id: String
    /// 表示名(V: の name=、なければ id)
    public var name: String
    public var clef: ABCClef
    /// 声部開始時の調号
    public var keySignature: ABCKeySignature
    public var elements: [ABCElement]

    public var isPercussion: Bool {
        clef == .percussion || keySignature.isPercussion
    }
}

/// 1曲。複数曲ファイルの場合は ABCBook.tunes の1要素。
public struct ABCTune: Sendable {
    /// 0始まりの曲番号
    public var index: Int
    /// この曲のソーステキスト(X:〜末尾)
    public var source: String
    /// ファイル先頭からの行オフセット(診断の行番号をファイル基準にするため)
    public var lineOffset: Int
    public var title: String
    public var composer: String
    public var meter: ABCMeter
    public var tempo: ABCTempo
    public var defaultNoteLength: ABCFraction
    /// 表示/再生順の声部(%%score の順、なければ出現順)
    public var voices: [ABCVoice]

    /// 音符のある声部が存在するか
    public var hasNotes: Bool {
        voices.contains { v in v.elements.contains { if case .note(let n) = $0 { return !n.isRest || n.rest == .measure }; return false } }
    }
}

public struct ABCDiagnostic: Sendable {
    public enum Severity: Sendable { case error, warning }
    public var severity: Severity
    /// ファイル基準の1始まり行番号。0=曲全体
    public var line: Int
    /// 1始まり桁位置。0=なし
    public var column: Int
    public var message: String
    /// ソース行の内容(表示用)
    public var context: String

    public init(severity: Severity, line: Int, column: Int = 0, message: String, context: String = "") {
        self.severity = severity; self.line = line; self.column = column
        self.message = message; self.context = context
    }
}

/// パース結果。複数曲を含む。
public struct ABCBook: Sendable {
    public var tunes: [ABCTune]
    public var diagnostics: [ABCDiagnostic]
    public init(tunes: [ABCTune], diagnostics: [ABCDiagnostic]) {
        self.tunes = tunes; self.diagnostics = diagnostics
    }
}
