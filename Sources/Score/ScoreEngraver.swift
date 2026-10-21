import CoreGraphics
import CoreText
import Foundation
import os

// MARK: - Public API

public enum ScoreInk: Sendable { case primary, accent, faint }
public enum ScoreTextAnchor: Sendable { case leading, center, trailing }

public enum EngravedShape {
    case fill(CGPath, ScoreInk)
    case stroke(CGPath, lineWidth: CGFloat, ScoreInk)
    case text(String, size: CGFloat, bold: Bool, rect: CGRect, anchor: ScoreTextAnchor, ink: ScoreInk)

    func translated(dy: CGFloat) -> EngravedShape {
        var t = CGAffineTransform(translationX: 0, y: dy)
        switch self {
        case .fill(let p, let ink): return .fill(p.copy(using: &t) ?? p, ink)
        case .stroke(let p, let lw, let ink): return .stroke(p.copy(using: &t) ?? p, lineWidth: lw, ink)
        case .text(let s, let size, let bold, let rect, let anchor, let ink):
            return .text(s, size: size, bold: bold, rect: rect.offsetBy(dx: 0, dy: dy), anchor: anchor, ink: ink)
        }
    }

    /// 描画される範囲の概算(y-down 座標)
    var bounds: CGRect {
        switch self {
        case .fill(let p, _): return p.boundingBoxOfPath
        case .stroke(let p, let lw, _): return p.boundingBoxOfPath.insetBy(dx: -lw / 2, dy: -lw / 2)
        case .text(_, let size, _, let rect, _, _):
            return CGRect(x: rect.minX, y: rect.midY - size * 0.62, width: rect.width, height: size * 1.24)
        }
    }
}

/// Retains a few recent layouts when the score tab is removed from the view
/// tree. Geometry and source are part of the key so edits and rotation rebuild.
final class ScoreLayoutCache {
    static let shared = ScoreLayoutCache()
    private final class Entry {
        let score: EngravedScore
        init(_ score: EngravedScore) { self.score = score }
    }
    private let entries = NSCache<NSString, Entry>()

    init() {
        entries.countLimit = 3
        entries.totalCostLimit = 60_000 // bound retained drawing shapes
    }

    func cachedScore(for tune: ABCTune, width: CGFloat, zoom: Double) -> EngravedScore? {
        let key = "\(tune.index)#\(width)#\(zoom)#\(tune.source)" as NSString
        return entries.object(forKey: key)?.score
    }

    func score(for tune: ABCTune, width: CGFloat, zoom: Double,
               engrave: (ABCTune, CGFloat) -> EngravedScore = {
                   ScoreEngraver.engrave($0, width: $1)
               }) -> EngravedScore {
        let key = "\(tune.index)#\(width)#\(zoom)#\(tune.source)" as NSString
        if let entry = entries.object(forKey: key) { return entry.score }
        let score = engrave(tune, width / zoom).scaled(by: zoom)
        entries.setObject(Entry(score), forKey: key, cost: score.shapes.count)
        return score
    }
}

/// 音符要素 id → 位置。rect = カーソル列・タップ判定領域、shapeRange = 色替えする図形
/// (符頭・休符)、system = その音符がある段の番号。
public struct CursorTarget {
    public var rect: CGRect
    public var shapeRange: Range<Int>
    public var system: Int
    public init(rect: CGRect, shapeRange: Range<Int>, system: Int = 0) {
        self.rect = rect
        self.shapeRange = shapeRange
        self.system = system
    }
}

/// 1 段(システム)。band は段の占有帯で、全段の band が上から隙間なく並ぶ
/// (段ごとに切り出して描画・スクロール追従するため)。
public struct EngravedSystem {
    public var band: CGRect
    /// 最上段五線の第 5 線(上端)の y
    public var staffTop: CGFloat
    /// 最下段五線の第 1 線(下端)の y
    public var staffBottom: CGFloat
    /// この段に属する図形の範囲(EngravedScore.shapes の index)
    public var shapeRange: Range<Int>
}

public struct EngravedScore {
    public var size: CGSize
    public var shapes: [EngravedShape]
    public var targets: [Int: CursorTarget]
    public var systems: [EngravedSystem]
    public init(size: CGSize, shapes: [EngravedShape], targets: [Int: CursorTarget],
                systems: [EngravedSystem] = []) {
        self.size = size
        self.shapes = shapes
        self.targets = targets
        self.systems = systems
    }

    /// 全ジオメトリを k 倍にした新しいスコアを返す。
    /// 表示ズーム用: engrave の width を viewWidth/k にしてから k 倍すると、
    /// 出力幅は viewWidth のまま譜面だけが拡大される。
    public func scaled(by k: CGFloat) -> EngravedScore {
        if k == 1 { return self }
        var t = CGAffineTransform(scaleX: k, y: k)
        let newShapes: [EngravedShape] = shapes.map { shape in
            switch shape {
            case .fill(let p, let ink):
                return .fill(p.copy(using: &t) ?? p, ink)
            case .stroke(let p, let lw, let ink):
                return .stroke(p.copy(using: &t) ?? p, lineWidth: lw * k, ink)
            case .text(let str, let size, let bold, let rect, let anchor, let ink):
                return .text(str, size: size * k, bold: bold, rect: rect.applying(t),
                             anchor: anchor, ink: ink)
            }
        }
        let newTargets = targets.mapValues {
            CursorTarget(rect: $0.rect.applying(t), shapeRange: $0.shapeRange, system: $0.system)
        }
        let newSystems = systems.map {
            EngravedSystem(band: $0.band.applying(t), staffTop: $0.staffTop * k,
                           staffBottom: $0.staffBottom * k, shapeRange: $0.shapeRange)
        }
        return EngravedScore(size: CGSize(width: size.width * k, height: size.height * k),
                             shapes: newShapes, targets: newTargets, systems: newSystems)
    }

    /// 点を含む音符ターゲット(近いもの優先)
    public func target(near point: CGPoint, in system: Int? = nil) -> Int? {
        var best: (id: Int, dist: CGFloat)?
        for (id, t) in targets where system == nil || t.system == system {
            let r = t.rect.insetBy(dx: -10, dy: -6)
            guard r.contains(point) else { continue }
            let d = abs(r.midX - point.x) + abs(r.midY - point.y) * 0.25
            if best == nil || d < best!.dist { best = (id, d) }
        }
        return best?.id
    }
}

// MARK: - Fonts

private final class FontBundleToken {}

/// テキスト用のシステムフォント
enum ScoreFonts {
    private static var cache: [String: CTFont] = [:]
    private static let lock = NSLock()

    static func font(size: CGFloat, bold: Bool) -> CTFont {
        let key = "\(size)|\(bold)"
        lock.lock(); defer { lock.unlock() }
        if let f = cache[key] { return f }
        let base = CTFontCreateWithName(".AppleSystemUIFont" as CFString, size, nil)
        var f = base
        if bold, let b = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .boldTrait, .boldTrait) {
            f = b
        }
        cache[key] = f
        return f
    }

    static func width(_ string: String, size: CGFloat, bold: Bool) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, bold: bold)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

/// 楽譜記号用の SMuFL フォント Bravura(SIL OFL 1.1、Sources/Fonts に同梱)。
/// SMuFL の規約でフォントサイズ = 五線の高さ(4 スペース)。
enum MusicFont {
    static let logger = Logger(subsystem: "jp.porari.abcstudio", category: "score")

    private static let descriptor: CTFontDescriptor? = {
        guard let url = Bundle(for: FontBundleToken.self).url(forResource: "Bravura", withExtension: "otf"),
              let data = try? Data(contentsOf: url),
              let desc = CTFontManagerCreateFontDescriptorFromData(data as CFData) else {
            logger.error("Bravura.otf をバンドルから読み込めません。楽譜記号は描画されません。")
            return nil
        }
        return desc
    }()

    static var isAvailable: Bool { descriptor != nil }

    struct Glyph {
        let path: CGPath      // フォント座標(y-up、原点=ベースライン)
        let bounds: CGRect
    }

    private static var cache: [String: Glyph] = [:]
    private static let lock = NSLock()

    static func glyph(_ codepoint: UInt32, size: CGFloat) -> Glyph? {
        guard let descriptor else { return nil }
        let key = "\(codepoint)|\(size)"
        lock.lock(); defer { lock.unlock() }
        if let g = cache[key] { return g }
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        var chars = Array(String(UnicodeScalar(codepoint)!).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count),
              let path = CTFontCreatePathForGlyph(font, glyphs[0], nil) else {
            logger.error("Bravura にグリフ U+\(String(codepoint, radix: 16)) がありません")
            return nil
        }
        let g = Glyph(path: path, bounds: path.boundingBoxOfPath)
        cache[key] = g
        return g
    }
}

/// 使用する SMuFL コードポイント
private enum SMuFL {
    static let gClef: UInt32 = 0xE050, cClef: UInt32 = 0xE05C, fClef: UInt32 = 0xE062
    static let unpitchedPercussionClef: UInt32 = 0xE069
    static let timeSig0: UInt32 = 0xE080, timeSigCommon: UInt32 = 0xE08A, timeSigCut: UInt32 = 0xE08B
    static let noteheadWhole: UInt32 = 0xE0A2, noteheadHalf: UInt32 = 0xE0A3
    static let noteheadBlack: UInt32 = 0xE0A4, noteheadX: UInt32 = 0xE0A9
    static let augmentationDot: UInt32 = 0xE1E7
    static let metNoteHalfUp: UInt32 = 0xE1D3, metNoteQuarterUp: UInt32 = 0xE1D5
    static let metNote8thUp: UInt32 = 0xE1D7, metAugmentationDot: UInt32 = 0xE1FC
    static let flagsUp: [UInt32] = [0xE240, 0xE242, 0xE244, 0xE246]
    static let flagsDown: [UInt32] = [0xE241, 0xE243, 0xE245, 0xE247]
    static let flat: UInt32 = 0xE260, natural: UInt32 = 0xE261, sharp: UInt32 = 0xE262
    static let doubleSharp: UInt32 = 0xE263, doubleFlat: UInt32 = 0xE264
    static let accentAbove: UInt32 = 0xE4A0, accentBelow: UInt32 = 0xE4A1
    static let staccatoAbove: UInt32 = 0xE4A2, staccatoBelow: UInt32 = 0xE4A3
    static let tenutoAbove: UInt32 = 0xE4A4, tenutoBelow: UInt32 = 0xE4A5
    static let fermataAbove: UInt32 = 0xE4C0, breathMark: UInt32 = 0xE4CE
    static let restWhole: UInt32 = 0xE4E3, restHalf: UInt32 = 0xE4E4, restQuarter: UInt32 = 0xE4E5
    static let rest8th: UInt32 = 0xE4E6, rest16th: UInt32 = 0xE4E7
    static let rest32nd: UInt32 = 0xE4E8, rest64th: UInt32 = 0xE4E9
    static let dynamicLetters: [Character: UInt32] = [
        "p": 0xE520, "m": 0xE521, "f": 0xE522, "r": 0xE523, "s": 0xE524, "z": 0xE525, "n": 0xE526,
    ]
    static let trill: UInt32 = 0xE566, turn: UInt32 = 0xE567, mordent: UInt32 = 0xE56C
    static let downBow: UInt32 = 0xE610, upBow: UInt32 = 0xE612
    static let tuplet0: UInt32 = 0xE880
}

// MARK: - ScoreEngraver

public enum ScoreEngraver {
    /// width = レイアウト幅(pt)。出力の幅は常に width になり、横にはみ出さない。
    /// header = 曲名・作曲者を上部に描く(書き出し用。画面ではアプリ側に表示する)。
    public static func engrave(_ tune: ABCTune, width: CGFloat, header: Bool = false) -> EngravedScore {
        Engine(tune: tune, width: width, header: header).run()
    }
}

// MARK: - Internal engine

private enum VItem {
    case note(ABCNote)
    case field(ABCFieldChange)
}

private struct VMeasure {
    var items: [VItem] = []
    var startBar: ABCBar?      // bar at left edge (leading |: etc)
    var endBar: ABCBar?        // bar at right edge
}

private struct VBracket {
    var startMeasure: Int
    var endMeasure: Int        // inclusive; bracket spans left edge of start..right edge of end
    var label: String
}

private struct VPlan {
    var measures: [VMeasure]
    var keyAt: [ABCKeySignature]      // key in effect at start of each measure
    var meterAt: [ABCMeter]
    var brackets: [VBracket]
}

private struct HeadPos {
    var p: Int          // half-space offset above bottom line (line = even)
    var cy: CGFloat
    var x: CGFloat      // center x of this head (seconds may be offset)
    var xHead: Bool     // percussion "x" notehead
}

private struct PlacedNote {
    var note: ABCNote
    var x: CGFloat              // head center x of the main column
    var heads: [HeadPos]
    var stemUp: Bool
    var stemX: CGFloat          // stem center x
    var tipY: CGFloat           // stem tip y (before beam adjust)
    var restCenterX: CGFloat    // for rests
    var topCy: CGFloat
    var botCy: CGFloat
}

private enum GlyphAlign { case origin, center, right }

private final class Engine {
    let tune: ABCTune
    let width: CGFloat
    let header: Bool

    // geometry constants (points)。行(五線)内の座標は五線上端 = 0 のローカル座標で組み、
    // 行の上下の実寸が決まってから所定の位置へ平行移動する。
    let s: CGFloat = 8                      // staff space
    var staffH: CGFloat { s * 4 }
    var headW: CGFloat { s * 1.18 }         // Bravura noteheadBlack の幅
    let stemW: CGFloat = 1.0
    let staffLineW: CGFloat = 0.9
    let leftPad: CGFloat = 14
    let rightPad: CGFloat = 10
    /// 段と段の間の余白
    var systemGap: CGFloat { s * 3.4 }
    /// 同じ段の五線どうしの最小余白(記号のはみ出しを除いた空き)
    var staffGap: CGFloat { s * 1.4 }
    /// パート名欄(先頭段のみ)。実際の名前列幅に合わせ、上限あり。
    let labelCol: CGFloat

    var shapes: [EngravedShape] = []
    var targets: [Int: CursorTarget] = [:]
    private var systemsOut: [EngravedSystem] = []

    // 行単位の一時データ(ローカル座標)
    private var rowTargetIDs: [Int] = []
    private var rowLyrics: [(x: CGFloat, text: String, hyphen: Bool, extendTo: CGFloat?)] = []
    private var rowChords: [(x: CGFloat, text: String)] = []

    // per-voice persistent connector state (ローカル y、x は段をまたぐと -1 に戻す)
    private struct TiePend { var step: Int; var x: CGFloat; var cy: CGFloat; var above: Bool }
    private struct SlurPend { var x: CGFloat; var y: CGFloat; var above: Bool }
    private struct HairpinPend { var cresc: Bool; var x: CGFloat }
    private var ties: [[TiePend]] = []
    private var slurs: [[SlurPend]] = []
    private var hairpins: [[HairpinPend]] = []
    private var accMap: [Int: [(x: CGFloat, cy: CGFloat, acc: ABCAccidental)]] = [:]

    init(tune: ABCTune, width: CGFloat, header: Bool) {
        self.tune = tune
        self.width = width
        self.header = header
        // パート名は複数パートのときだけ表示する
        let nameW = tune.voices.count > 1
            ? tune.voices.map { ScoreFonts.width(Self.voiceLabel($0), size: 10, bold: false) }.max() ?? 0
            : 0
        self.labelCol = nameW > 0 ? min(nameW + 8, 8 * 8.5) : 0
    }

    private static func voiceLabel(_ v: ABCVoice) -> String { v.name.isEmpty ? v.id : v.name }

    // MARK: clef tables (diatonic bottom-line step, C4 = 0) — ABCClef.bottomLineStep 参照

    private func clefWidth(_ clef: ABCClef) -> CGFloat {
        switch clef {
        case .treble: return s * 3.3
        case .bass: return s * 3.4
        case .alto, .tenor: return s * 3.3
        case .percussion: return s * 2.2
        }
    }

    private func letter(of step: Int) -> Int { ((step % 7) + 7) % 7 }

    /// key-signature staff position (half-space offset p above bottom line) per LETTER (C=0..B=6),
    /// per clef. Values follow the standard engraving layout tables.
    private func keyPos(_ letter: Int, _ acc: ABCAccidental, _ clef: ABCClef) -> Int {
        switch clef {
        case .bass:
            // sharps F3 C3 G3 D3 A2 E3 B2 ; flats B2 E3 A2 D3 G2 C3 F2
            switch acc {
            case .sharp: return [3, 4, 5, 6, 7, 1, 2][letter]
            case .flat:  return [3, 4, 5, -1, 0, 1, 2][letter]
            default: return 4
            }
        case .alto:
            // sharps F4 C4 G4 D4 A3 E4 B3 ; flats B3 E4 A3 D4 G3 C4 F3
            switch acc {
            case .sharp: return [4, 5, 6, 7, 8, 2, 3][letter]
            case .flat:  return [4, 5, 6, 0, 1, 2, 3][letter]
            default: return 4
            }
        case .tenor:
            // sharps F3 C4 G3 D4 A3 E4 B3 ; flats B3 E4 A3 D4 G3 C4 F3
            switch acc {
            case .sharp: return [6, 7, 8, 2, 3, 4, 5][letter]
            case .flat:  return [6, 7, 8, 2, 3, 4, 5][letter]
            default: return 4
            }
        default: // treble, percussion
            // sharps F5 C5 G5 D5 A4 E5 B4 ; flats B4 E5 A4 D5 G4 C5 F4
            switch acc {
            case .sharp: return [5, 6, 7, 8, 9, 3, 4][letter]
            case .flat:  return [5, 6, 7, 1, 2, 3, 4][letter]
            default: return 4
            }
        }
    }

    // MARK: plan building

    private func buildPlan(_ v: ABCVoice) -> VPlan {
        var measures: [VMeasure] = []
        var cur = VMeasure()
        for el in v.elements {
            switch el {
            case .note(let n): cur.items.append(.note(n))
            case .fieldChange(let f): cur.items.append(.field(f))
            case .bar(let b):
                if cur.items.isEmpty && cur.startBar == nil && cur.endBar == nil {
                    cur.startBar = b          // attaches to the left edge of the upcoming measure
                } else {
                    cur.endBar = b
                    measures.append(cur)
                    cur = VMeasure()
                }
            }
        }
        if !cur.items.isEmpty || cur.startBar != nil || cur.endBar != nil || measures.isEmpty {
            measures.append(cur)
        }

        // key/meter at start of each measure
        var keyAt = [ABCKeySignature](repeating: v.keySignature, count: measures.count)
        var meterAt = [ABCMeter](repeating: tune.meter, count: measures.count)
        var k = v.keySignature
        var mtr = tune.meter
        for (i, m) in measures.enumerated() {
            keyAt[i] = k
            meterAt[i] = mtr
            for item in m.items {
                if case .field(let f) = item {
                    switch f {
                    case .key(let nk): k = nk
                    case .meter(let nm): mtr = nm
                    default: break
                    }
                }
            }
        }

        // volta brackets
        var brackets: [VBracket] = []
        for (i, m) in measures.enumerated() {
            let candidates: [(Int, ABCBar)] = [(i, m.startBar), (i + 1, m.endBar)].compactMap { idx, b in
                guard let b, !b.endings.isEmpty else { return nil }
                return (idx, b)
            }
            for (startIdx, bar) in candidates {
                // find end: next measure whose endBar is a closing repeat/final, or whose bar starts a new ending
                var end = measures.count - 1
                var j = startIdx
                inner: while j < measures.count {
                    let mm = measures[j]
                    if j > startIdx {
                        if let sb = mm.startBar, !sb.endings.isEmpty { end = j - 1; break inner }
                    }
                    if let eb = mm.endBar {
                        if !eb.endings.isEmpty && j >= startIdx { end = j; break inner }
                        switch eb.kind {
                        case .repeatEnd, .repeatBoth, .final: end = j; break inner
                        default: break
                        }
                    }
                    j += 1
                }
                let label = bar.endings.map(String.init).joined(separator: ",") + "."
                brackets.append(VBracket(startMeasure: startIdx, endMeasure: max(startIdx, end), label: label))
            }
        }
        return VPlan(measures: measures, keyAt: keyAt, meterAt: meterAt, brackets: brackets)
    }

    // MARK: width estimation

    private func keySigWidth(_ key: ABCKeySignature) -> CGFloat {
        key.isPercussion || key.accidentals.isEmpty ? 0 : CGFloat(key.accidentals.count) * s * 1.0 + s * 0.5
    }

    private func fieldWidth(_ f: ABCFieldChange) -> CGFloat {
        switch f {
        case .key(let k): return keySigWidth(k) + s * 1.4
        case .meter: return s * 2.6
        case .tempo, .noteLength: return 0
        }
    }

    /// 符頭の左に置くもの(臨時記号・前打音)の幅
    private func leadWidth(_ n: ABCNote) -> CGFloat {
        let nAcc = n.pitches.filter { $0.accidental != nil }.count
        return (nAcc > 0 ? CGFloat(min(2, nAcc)) * s * 0.95 + s * 0.2 : 0)
            + (n.graceNotes.isEmpty ? 0 : CGFloat(n.graceNotes.count) * s * 0.8 + s * 0.2)
    }

    /// 音価に応じた間隔(次の発音までの時間 d、全音符=1)
    private func durationSpace(_ d: Double) -> CGFloat {
        (1.4 + 2.9 * sqrt(max(0.03, d))) * s
    }

    /// 音価に関係なく必要な幅(符頭+付点・歌詞・コード記号が隣と重ならない)
    private func bodyMin(_ n: ABCNote) -> CGFloat {
        var w = s * 2.0 + CGFloat(n.dots) * s * 0.5
        if n.rest == .measure { w = max(w, s * 4) }
        if let ly = n.lyric, !ly.syllable.isEmpty {
            w = max(w, ScoreFonts.width(ly.syllable, size: 10, bold: false) + s * (ly.hyphenAfter ? 1.6 : 0.8))
        }
        if let cs = n.chordSymbol, !cs.isEmpty {
            w = max(w, ScoreFonts.width(cs, size: 11, bold: true) + s * 0.8)
        }
        return w
    }

    /// 1 小節ぶんの全パート共通の時間グリッド。同時に鳴る音符は同じ x に揃う。
    private struct MeasureGrid {
        var onsets: [ABCFraction] = []
        var index: [ABCFraction: Int] = [:]
        var pre: [CGFloat] = []     // 発音位置の前に置く拍子・調号変更
        var lead: [CGFloat] = []    // 臨時記号・前打音
        var body: [CGFloat] = []    // 符頭から次の発音位置まで
        var tail: CGFloat = 0       // 小節末の拍子・調号変更
        var fixed: CGFloat { pre.reduce(0, +) + lead.reduce(0, +) + tail }
        var natural: CGFloat { fixed + body.reduce(0, +) }
    }

    private func buildGrid(_ mi: Int, plans: [VPlan]) -> MeasureGrid {
        var pre: [ABCFraction: CGFloat] = [:], lead: [ABCFraction: CGFloat] = [:], minBody: [ABCFraction: CGFloat] = [:]
        var end = ABCFraction(0, 1)
        var tail: CGFloat = 0
        for plan in plans where mi < plan.measures.count {
            var t = ABCFraction(0, 1)
            var pending: CGFloat = 0
            for item in plan.measures[mi].items {
                switch item {
                case .field(let f):
                    pending += fieldWidth(f)
                case .note(let n):
                    pre[t] = max(pre[t] ?? 0, pending)
                    pending = 0
                    lead[t] = max(lead[t] ?? 0, leadWidth(n))
                    minBody[t] = max(minBody[t] ?? 0, bodyMin(n))
                    t = t + n.duration
                }
            }
            tail = max(tail, pending)
            end = max(end, t)
        }
        var g = MeasureGrid()
        g.onsets = pre.keys.sorted()
        g.tail = tail
        for (i, t) in g.onsets.enumerated() {
            g.index[t] = i
            let next = i + 1 < g.onsets.count ? g.onsets[i + 1] : end
            g.pre.append(pre[t] ?? 0)
            g.lead.append(lead[t] ?? 0)
            g.body.append(max(durationSpace((next - t).value), minBody[t] ?? 0))
        }
        return g
    }

    private var grids: [MeasureGrid] = []
    /// 小節頭に開始リピート等があるか(どれかのパートにあれば全パートで同じだけ空ける)
    private var startBarAt: [Bool] = []
    private var measurePadL: CGFloat { s * 0.8 }
    private var measurePadR: CGFloat { s * 0.6 }
    private var startBarW: CGFloat { s * 1.0 }

    // MARK: main entry

    func run() -> EngravedScore {
        let voices = tune.voices
        guard !voices.isEmpty else {
            return EngravedScore(size: CGSize(width: width, height: 80), shapes: [], targets: [:])
        }
        let plans = voices.map(buildPlan)
        ties = [[TiePend]](repeating: [], count: voices.count)
        slurs = [[SlurPend]](repeating: [], count: voices.count)
        hairpins = [[HairpinPend]](repeating: [], count: voices.count)

        let M = plans.map { $0.measures.count }.max() ?? 0
        grids = (0..<M).map { buildGrid($0, plans: plans) }
        startBarAt = (0..<M).map { mi in
            plans.contains { mi < $0.measures.count && $0.measures[mi].startBar != nil }
        }
        let gridW: [CGFloat] = (0..<M).map { mi in
            var w = measurePadL + measurePadR + grids[mi].natural
            if startBarAt[mi] { w += startBarW }
            return max(w, s * 3.0)
        }

        // furniture width needed if a system starts at measure boundary b
        func furnitureWidth(_ b: Int) -> CGFloat {
            var w: CGFloat = 0
            for (vi, v) in voices.enumerated() {
                let key = b < plans[vi].keyAt.count ? plans[vi].keyAt[b] : v.keySignature
                var f = s * 0.5 + clefWidth(v.clef)
                if !v.isPercussion { f += keySigWidth(key) }
                w = max(w, f)
            }
            return w
        }

        // ---- pack measures into systems ----
        struct Sys { var start: Int; var end: Int; var lineStart: CGFloat; var startX: CGFloat; var avail: CGFloat }
        var systems: [Sys] = []
        var m = 0
        while m < M {
            let first = systems.isEmpty
            let lineStart = leftPad + (first ? labelCol : 0)
            let startX = lineStart + furnitureWidth(m) + (first ? s * 3.0 : 0) + s * 0.3
            let avail = width - rightPad - startX
            var used: CGFloat = 0
            var e = m
            while e < M {
                let mw = gridW[e]
                if e > m && used + mw > avail { break }
                used += mw
                e += 1
            }
            systems.append(Sys(start: m, end: max(e, m + 1), lineStart: lineStart, startX: startX, avail: avail))
            m = max(e, m + 1)
        }

        // ---- header (書き出し用) ----
        var contentTop = s * 1.5
        if header {
            if !tune.title.isEmpty {
                emitText(tune.title, size: 18, bold: true,
                         rect: CGRect(x: leftPad, y: s * 1.5, width: width - leftPad - rightPad, height: 24),
                         anchor: .center, ink: .primary)
                contentTop = s * 1.5 + 30
            }
            if !tune.composer.isEmpty {
                emitText(tune.composer, size: 11, bold: false,
                         rect: CGRect(x: leftPad, y: contentTop, width: width - leftPad - rightPad, height: 14),
                         anchor: .trailing, ink: .primary)
                contentTop += 20
            }
        }

        // ---- emit systems ----
        var bandStart: CGFloat = 0
        for (si, sys) in systems.enumerated() {
            let sysShapeStart = si == 0 ? 0 : shapes.count
            // 小節幅: 余りは均等に配り、足りなければ(1 小節が入りきらない)比例で縮める
            var widths = (sys.start..<sys.end).map { gridW[$0] }
            let total = widths.reduce(0, +)
            let isLast = si == systems.count - 1
            if total > sys.avail {
                widths = widths.map { $0 * sys.avail / total }
            } else if !(isLast && total < sys.avail * 0.6) {
                // 最終段が短いときは引き伸ばさない(間延びを防ぐ)
                let extra = (sys.avail - total) / CGFloat(widths.count)
                widths = widths.map { $0 + extra }
            }
            var mX: [CGFloat] = []
            var cur = sys.startX
            for w in widths { mX.append(cur); cur += w }
            let sysRight = cur

            var cursorY = si == 0 ? contentTop : bandStart + systemGap / 2
            var rowTops: [CGFloat] = []
            for (vi, v) in voices.enumerated() {
                let rowStart = shapes.count
                let top = emitRow(vi: vi, voice: v, plan: plans[vi], sys: (sys.start, sys.end),
                                  si: si, lineStart: sys.lineStart, mX: mX, widths: widths,
                                  sysRight: sysRight)
                let rowTop = cursorY + (vi == 0 ? 0 : staffGap) - top.minY
                translate(rowStart..<shapes.count, dy: rowTop)
                for id in rowTargetIDs {
                    guard var t = targets[id] else { continue }
                    t.rect = t.rect.offsetBy(dx: 0, dy: rowTop)
                    t.system = si
                    targets[id] = t
                }
                rowTops.append(rowTop)
                cursorY = rowTop + top.maxY
            }

            // 段頭の縦線と、複数パートならブラケット
            if voices.count > 1, let t0 = rowTops.first, let t1 = rowTops.last {
                let p = CGMutablePath()
                p.addRect(CGRect(x: sys.lineStart - 0.5, y: t0, width: 1.1, height: t1 + staffH - t0))
                shapes.append(.fill(p, .primary))
                let b = CGMutablePath()
                b.addRect(CGRect(x: sys.lineStart - s * 0.85, y: t0 - s * 0.35,
                                 width: s * 0.4, height: t1 + staffH - t0 + s * 0.7))
                shapes.append(.fill(b, .primary))
            }

            let bandEnd = cursorY + systemGap / 2
            systemsOut.append(EngravedSystem(
                band: CGRect(x: 0, y: bandStart, width: width, height: bandEnd - bandStart),
                staffTop: rowTops.first ?? 0, staffBottom: (rowTops.last ?? 0) + staffH,
                shapeRange: sysShapeStart..<shapes.count))
            bandStart = bandEnd
        }

        return EngravedScore(size: CGSize(width: width, height: bandStart),
                             shapes: shapes, targets: targets, systems: systemsOut)
    }

    /// 1 段の 1 パートをローカル座標(五線上端 = 0)で描く。
    /// 戻り値は行の縦の占有範囲(minY = 上端、maxY = 下端。どちらもローカル)。
    private func emitRow(vi: Int, voice v: ABCVoice, plan: VPlan, sys: (start: Int, end: Int),
                         si: Int, lineStart: CGFloat, mX: [CGFloat], widths: [CGFloat],
                         sysRight: CGFloat) -> (minY: CGFloat, maxY: CGFloat) {
        let rowStart = shapes.count
        rowTargetIDs = []
        rowLyrics = []
        rowChords = []

        // staff lines
        let lines = CGMutablePath()
        for l in 0..<5 {
            let ly = CGFloat(l) * s
            lines.move(to: CGPoint(x: lineStart, y: ly))
            lines.addLine(to: CGPoint(x: sysRight, y: ly))
        }
        shapes.append(.stroke(lines, lineWidth: staffLineW, .primary))

        // voice name (first system)
        if si == 0 && labelCol > 0 {
            emitText(Self.voiceLabel(v), size: 10, bold: false,
                     rect: CGRect(x: leftPad - 4, y: staffH / 2 - 7, width: labelCol - 8, height: 14),
                     anchor: .trailing, ink: .primary)
        }

        // furniture: clef + key + meter
        var fx = lineStart + s * 0.5
        emitClef(v.clef, x: fx)
        fx += clefWidth(v.clef)
        if !v.isPercussion {
            let key = sys.start < plan.keyAt.count ? plan.keyAt[sys.start] : v.keySignature
            emitKeySig(key, clef: v.clef, x: fx)
            fx += keySigWidth(key)
        }
        if si == 0 {
            let meter = sys.start < plan.meterAt.count ? plan.meterAt[sys.start] : tune.meter
            emitMeter(meter, centerX: fx + s * 1.2)
        }

        // 前の段から持ち越したタイ・スラー・ヘアピンは段頭から描く
        let continueX = (mX.first ?? fx) + s * 0.2
        for i in ties[vi].indices where ties[vi][i].x < 0 { ties[vi][i].x = continueX }
        for i in slurs[vi].indices where slurs[vi][i].x < 0 { slurs[vi][i].x = continueX }
        for i in hairpins[vi].indices where hairpins[vi][i].x < 0 { hairpins[vi][i].x = continueX }

        // measures
        var accState: [Int: ABCAccidental] = [:]
        var curKey = sys.start < plan.keyAt.count ? plan.keyAt[sys.start] : v.keySignature
        for mi in sys.start..<sys.end where mi < plan.measures.count {
            let meas = plan.measures[mi]
            let mx0 = mX[mi - sys.start]
            let mx1 = mx0 + widths[mi - sys.start]
            accState = [:]
            if let sb = meas.startBar { emitBar(sb, x: mx0) }
            emitMeasure(vi: vi, plan: plan, mi: mi, x0: mx0 + (startBarAt[mi] ? startBarW : 0), x1: mx1,
                        accState: &accState, curKey: &curKey)
            if let eb = meas.endBar {
                emitBar(eb, x: mx1)
            } else if mi == plan.measures.count - 1 {
                emitBar(ABCBar(kind: .final), x: mx1)
            }
        }

        // 次の段へ持ち越す連結線: 段末まで半分描き、次の段頭から続ける
        for i in ties[vi].indices {
            let tp = ties[vi][i]
            emitArc(x0: tp.x, y0: tp.cy, x1: sysRight - s * 0.3, y1: tp.cy, above: tp.above, thin: true)
            ties[vi][i].x = -1
        }
        for i in slurs[vi].indices {
            let sp = slurs[vi][i]
            emitArc(x0: sp.x, y0: sp.y, x1: sysRight - s * 0.3, y1: sp.y, above: sp.above, thin: false)
            slurs[vi][i].x = -1
        }
        for i in hairpins[vi].indices {
            let hp = hairpins[vi][i]
            emitHairpin(cresc: hp.cresc, x0: hp.x, x1: sysRight - s * 0.5, y: staffH + s * 2.2)
            hairpins[vi][i].x = -1
        }

        // ここまでの占有範囲を測り、上にコード記号・括弧・テンポ、下に歌詞を積む
        var bb = CGRect(x: lineStart, y: 0, width: 1, height: staffH)
        for i in rowStart..<shapes.count { bb = bb.union(shapes[i].bounds) }
        var top = min(bb.minY, -s * 0.5)
        var bottom = max(bb.maxY, staffH + s * 0.5)

        if !rowChords.isEmpty {
            let cy = top - s * 0.3 - 14
            for c in rowChords {
                emitText(c.text, size: 11, bold: true,
                         rect: CGRect(x: c.x - 40, y: cy, width: 80, height: 14),
                         anchor: .center, ink: .primary)
            }
            top = cy
        }

        let rowBrackets = plan.brackets.filter { $0.endMeasure >= sys.start && $0.startMeasure < sys.end }
        if !rowBrackets.isEmpty {
            let by = top - s * 0.8
            for b in rowBrackets {
                let lo = max(b.startMeasure, sys.start)
                let hi = min(b.endMeasure, sys.end - 1)
                guard lo <= hi, lo - sys.start < mX.count, hi - sys.start < mX.count else { continue }
                let bx0 = lo == b.startMeasure ? mX[lo - sys.start] + 1 : lineStart + 2
                let bx1 = mX[hi - sys.start] + widths[hi - sys.start] - 2
                let p = CGMutablePath()
                p.move(to: CGPoint(x: bx0, y: by + s * 1.6))
                p.addLine(to: CGPoint(x: bx0, y: by))
                p.addLine(to: CGPoint(x: bx1, y: by))
                if hi == b.endMeasure { p.addLine(to: CGPoint(x: bx1, y: by + s * 1.2)) }
                shapes.append(.stroke(p, lineWidth: 1, .primary))
                if lo == b.startMeasure {
                    emitText(b.label, size: 10, bold: true,
                             rect: CGRect(x: bx0 + 4, y: by + 2, width: s * 3, height: 12),
                             anchor: .leading, ink: .primary)
                }
            }
            top = by - 1
        }

        if si == 0 && vi == 0 {
            let ty = top - s * 0.4 - 16
            emitTempo(tune.tempo, x: lineStart + s * 0.5, top: ty)
            top = ty
        }

        if !rowLyrics.isEmpty {
            let ly = bottom + s * 0.4
            for ev in rowLyrics {
                let w = ScoreFonts.width(ev.text, size: 10, bold: false)
                emitText(ev.text, size: 10, bold: false,
                         rect: CGRect(x: ev.x - w / 2, y: ly, width: w + 2, height: 13),
                         anchor: .leading, ink: .primary)
                if ev.hyphen {
                    emitText("-", size: 10, bold: false,
                             rect: CGRect(x: ev.x + w / 2 + s * 0.3, y: ly, width: 10, height: 13),
                             anchor: .leading, ink: .faint)
                }
                if let ext = ev.extendTo, ext > ev.x + w / 2 + 4 {
                    let p = CGMutablePath()
                    p.move(to: CGPoint(x: ev.x + w / 2 + 2, y: ly + 11))
                    p.addLine(to: CGPoint(x: ext, y: ly + 11))
                    shapes.append(.stroke(p, lineWidth: 0.8, .primary))
                }
            }
            bottom = ly + 15
        }
        return (top, bottom)
    }

    private func translate(_ range: Range<Int>, dy: CGFloat) {
        for i in range { shapes[i] = shapes[i].translated(dy: dy) }
    }

    private func tempoString(_ t: ABCTempo) -> String {
        t.bpm == t.bpm.rounded() ? "\(Int(t.bpm))" : String(format: "%.1f", t.bpm)
    }

    /// テンポ表示(曲想テキスト + 音符 = bpm)。top = 表示の上端。
    private func emitTempo(_ t: ABCTempo, x: CGFloat, top: CGFloat) {
        var cx = x
        let mid = top + 8
        if let txt = t.text, !txt.isEmpty {
            emitText(txt, size: 12, bold: true,
                     rect: CGRect(x: cx, y: mid - 7, width: ScoreFonts.width(txt, size: 12, bold: true) + 4, height: 14),
                     anchor: .leading, ink: .primary)
            cx += ScoreFonts.width(txt, size: 12, bold: true) + 8
        }
        let (cp, dotted): (UInt32, Bool)
        switch (t.unit.num, t.unit.den) {
        case (1, 2): (cp, dotted) = (SMuFL.metNoteHalfUp, false)
        case (3, 4): (cp, dotted) = (SMuFL.metNoteHalfUp, true)
        case (1, 8): (cp, dotted) = (SMuFL.metNote8thUp, false)
        case (3, 8): (cp, dotted) = (SMuFL.metNoteQuarterUp, true)
        default: (cp, dotted) = (SMuFL.metNoteQuarterUp, false)
        }
        let r = emitGlyph(cp, x: cx, y: mid + s * 0.5, scale: 0.62)
        cx = r.maxX + 2
        if dotted {
            cx = emitGlyph(SMuFL.metAugmentationDot, x: cx, y: mid + s * 0.5, scale: 0.62).maxX + 2
        }
        emitText("= \(tempoString(t))", size: 11, bold: false,
                 rect: CGRect(x: cx + 2, y: mid - 7, width: 60, height: 14),
                 anchor: .leading, ink: .primary)
    }

    // MARK: glyph emit

    /// SMuFL グリフを y-down 座標に置く。y = ベースライン位置。戻り値は置いた範囲。
    @discardableResult
    private func emitGlyph(_ cp: UInt32, x: CGFloat, y: CGFloat, scale: CGFloat = 1,
                           align: GlyphAlign = .origin, ink: ScoreInk = .primary) -> CGRect {
        guard let g = MusicFont.glyph(cp, size: staffH) else { return CGRect(x: x, y: y, width: 0, height: 0) }
        let dx: CGFloat
        switch align {
        case .origin: dx = 0
        case .center: dx = -g.bounds.midX * scale
        case .right: dx = -g.bounds.maxX * scale
        }
        var t = CGAffineTransform(translationX: x + dx, y: y).scaledBy(x: scale, y: -scale)
        guard let p = g.path.copy(using: &t) else { return .zero }
        shapes.append(.fill(p, ink))
        return p.boundingBoxOfPath
    }

    private func glyphWidth(_ cp: UInt32, scale: CGFloat = 1) -> CGFloat {
        (MusicFont.glyph(cp, size: staffH)?.bounds.width ?? 0) * scale
    }

    // MARK: staff furniture

    private func emitClef(_ clef: ABCClef, x: CGFloat) {
        switch clef {
        case .treble: emitGlyph(SMuFL.gClef, x: x, y: s * 3)          // G 線
        case .bass: emitGlyph(SMuFL.fClef, x: x, y: s * 1)            // F 線
        case .alto: emitGlyph(SMuFL.cClef, x: x, y: s * 2)            // 第 3 線 = C4
        case .tenor: emitGlyph(SMuFL.cClef, x: x, y: s * 1)           // 第 4 線 = C4
        case .percussion: emitGlyph(SMuFL.unpitchedPercussionClef, x: x + s * 0.3, y: s * 2)
        }
    }

    private func emitKeySig(_ key: ABCKeySignature, clef: ABCClef, x: CGFloat) {
        guard !key.isPercussion else { return }
        for (i, a) in key.accidentals.enumerated() {
            // keyPos は下線からの半スペース数。音符と同じ式: y = bottom - p·s/2
            let p = keyPos(a.letter, a.accidental, clef)
            let cy = staffH - CGFloat(p) * (s / 2)
            emitGlyph(accidentalCP(a.accidental), x: x + CGFloat(i) * s * 1.0, y: cy)
        }
    }

    private func accidentalCP(_ acc: ABCAccidental) -> UInt32 {
        switch acc {
        case .sharp: return SMuFL.sharp
        case .flat: return SMuFL.flat
        case .natural: return SMuFL.natural
        case .doubleSharp: return SMuFL.doubleSharp
        case .doubleFlat: return SMuFL.doubleFlat
        }
    }

    /// 数字を SMuFL の拍子記号数字で中央揃えに並べる
    private func emitDigits(_ n: Int, base: UInt32, centerX: CGFloat, y: CGFloat, scale: CGFloat = 1) {
        let cps = String(n).compactMap { $0.wholeNumberValue }.map { base + UInt32($0) }
        let total = cps.reduce(0) { $0 + glyphWidth($1, scale: scale) }
        var x = centerX - total / 2
        for cp in cps {
            let g = MusicFont.glyph(cp, size: staffH)
            emitGlyph(cp, x: x - (g?.bounds.minX ?? 0) * scale, y: y, scale: scale)
            x += glyphWidth(cp, scale: scale)
        }
    }

    private func emitMeter(_ meter: ABCMeter, centerX: CGFloat) {
        switch meter.style {
        case .none:
            break
        case .common:
            emitGlyph(SMuFL.timeSigCommon, x: centerX, y: s * 2, align: .center)
        case .cut:
            emitGlyph(SMuFL.timeSigCut, x: centerX, y: s * 2, align: .center)
        case .fraction(let num, let den):
            emitDigits(num, base: SMuFL.timeSig0, centerX: centerX, y: s * 1)
            emitDigits(den, base: SMuFL.timeSig0, centerX: centerX, y: s * 3)
        }
    }

    private func emitBar(_ bar: ABCBar, x: CGFloat) {
        let thin: CGFloat = 1.1, thick: CGFloat = 3.6
        func vline(_ lx: CGFloat, _ w: CGFloat) {
            let p = CGMutablePath()
            p.addRect(CGRect(x: lx, y: 0, width: w, height: staffH))
            shapes.append(.fill(p, .primary))
        }
        func dots(_ dx: CGFloat) {
            for dy in [1.5, 2.5] {
                let d = CGMutablePath()
                d.addEllipse(in: CGRect(x: dx - 2, y: s * CGFloat(dy) - 2, width: 4, height: 4))
                shapes.append(.fill(d, .primary))
            }
        }
        switch bar.kind {
        case .plain:
            vline(x - thin / 2, thin)
        case .double:
            vline(x - 4, thin); vline(x - thin, thin)
        case .final:
            vline(x - thick - 3.5, thin); vline(x - thick, thick)
        case .repeatStart:
            vline(x, thick); vline(x + thick + 2.5, thin); dots(x + thick + 7)
        case .repeatEnd:
            dots(x - thick - 7); vline(x - thick - 2.5 - thin, thin); vline(x - thick, thick)
        case .repeatBoth:
            dots(x - thick / 2 - 7.5); vline(x - thick / 2 - 3.5, thin); vline(x - thick / 2, thick)
            vline(x + thick / 2 + 2.5, thin); dots(x + thick / 2 + 7)
        }
    }

    // MARK: measure layout & emit

    private func emitMeasure(vi: Int, plan: VPlan, mi: Int, x0: CGFloat, x1: CGFloat,
                             accState: inout [Int: ABCAccidental], curKey: inout ABCKeySignature) {
        let voice = tune.voices[vi]
        let meas = plan.measures[mi]
        guard !meas.items.isEmpty else { return }
        accMap = [:]

        let perc = voice.isPercussion
        let bottom = voice.clef.bottomLineStep

        // ---- pass 1: positions ----
        // 全パート共通の時間グリッドから各発音位置の x を決める。
        // 余った幅は音価ぶんの間隔(body)にだけ配り、臨時記号などの幅は伸ばさない。
        let g = grids[mi]
        let inner0 = x0 + measurePadL
        let innerW = x1 - measurePadR - inner0
        let bodySum = max(g.body.reduce(0, +), 1)
        let bodyScale = max(0.3, (innerW - g.fixed) / bodySum)
        let fixedScale = innerW < g.fixed ? max(0.3, innerW / max(g.natural, 1)) : 1
        var blockX: [CGFloat] = [], headXs: [CGFloat] = []
        var bx = inner0
        for i in g.onsets.indices {
            blockX.append(bx)
            headXs.append(bx + (g.pre[i] + g.lead[i]) * fixedScale + headW / 2)
            bx += (g.pre[i] + g.lead[i]) * fixedScale + g.body[i] * bodyScale
        }
        let tailX = bx
        // 各要素の位置: 音符は符頭中心、フィールド変更はその左端
        var xs: [CGFloat] = []
        var t = ABCFraction(0, 1)
        var fieldOffset: CGFloat = 0
        for item in meas.items {
            let oi = g.index[t]
            switch item {
            case .field(let f):
                xs.append((oi.map { blockX[$0] } ?? tailX) + fieldOffset)
                fieldOffset += fieldWidth(f) * fixedScale
            case .note(let n):
                xs.append(headXs[oi!])
                fieldOffset = 0
                t = t + n.duration
            }
        }

        var placed: [PlacedNote?] = Array(repeating: nil, count: meas.items.count)
        var beamOfItem: [Int: Int] = [:]
        var beamGroups: [[Int]] = []
        var curBeam = -1
        var tupletRanges: [(lo: Int, hi: Int, n: Int)] = []
        var tFirst = -1

        func keyAcc(_ letterIdx: Int) -> ABCAccidental? {
            curKey.accidentals.first { $0.letter == letterIdx }?.accidental
        }

        for (idx, item) in meas.items.enumerated() {
            switch item {
            case .field(let f):
                switch f {
                case .key(let nk):
                    curKey = nk
                    accState = [:]
                    // thin double bar + new key signature
                    let p = CGMutablePath()
                    p.addRect(CGRect(x: xs[idx], y: 0, width: 1, height: staffH))
                    p.addRect(CGRect(x: xs[idx] + 3, y: 0, width: 1, height: staffH))
                    shapes.append(.fill(p, .primary))
                    emitKeySig(nk, clef: voice.clef, x: xs[idx] + s * 0.9)
                case .meter(let nm):
                    emitMeter(nm, centerX: xs[idx] + s * 1.2)
                case .tempo(let t):
                    emitTempo(t, x: xs[idx], top: -s * 3.2)
                case .noteLength:
                    break
                }
            case .note(let n):
                if n.rest == .invisible || n.rest == .spacer {
                    registerTarget(n, x: xs[idx], s0: shapes.count)
                    placed[idx] = PlacedNote(note: n, x: xs[idx], heads: [], stemUp: true,
                                             stemX: 0, tipY: 0, restCenterX: xs[idx],
                                             topCy: 0, botCy: 0)
                    continue
                }

                // beam group tracking
                if n.beamStart { curBeam = beamGroups.count; beamGroups.append([]) }
                if curBeam >= 0 { beamOfItem[idx] = curBeam; beamGroups[curBeam].append(idx) }

                // tuplet tracking
                if let tp = n.tuplet {
                    if tp.isFirst { tFirst = idx }
                    if tp.isLast && tFirst >= 0 { tupletRanges.append((tFirst, idx, tp.n)); tFirst = -1 }
                }

                if n.isRest {
                    let restX = xs[idx]
                    placed[idx] = PlacedNote(note: n, x: restX, heads: [], stemUp: true,
                                             stemX: restX, tipY: 0, restCenterX: restX,
                                             topCy: s * 2, botCy: s * 2)
                    if n.beamEnd { curBeam = -1 }
                    continue
                }

                // note pitch positions
                var heads: [HeadPos] = []
                var accs: [(x: CGFloat, cy: CGFloat, acc: ABCAccidental)] = []
                let sorted = n.pitches.sorted { $0.step < $1.step }
                for pitch in sorted {
                    let pPos: Int
                    var xHead = false
                    if perc {
                        let dm = drumPos(pitch.midi)
                        pPos = dm.p; xHead = dm.x
                    } else {
                        pPos = pitch.step - bottom
                    }
                    let cy = staffH - CGFloat(pPos) * s / 2
                    if !perc, let acc = pitch.accidental {
                        let letterIdx = letter(of: pitch.step)
                        let eff = accState[pitch.step] ?? keyAcc(letterIdx)
                        if acc != eff {
                            accs.append((x: 0, cy: cy, acc: acc))
                        }
                        accState[pitch.step] = acc
                    }
                    heads.append(HeadPos(p: pPos, cy: cy, x: 0, xHead: xHead))
                }
                let headX = xs[idx]

                // stem direction: farthest-from-middle rule
                let maxP = heads.map { $0.p }.max() ?? 4
                let minP = heads.map { $0.p }.min() ?? 4
                let stemUp = (4 - minP) >= (maxP - 4)
                // seconds offset: 隣接する2度は交互に左右へずらす。
                // 上符尾: 通常側=左、ずらした側=右(上位音から上へ向かって交互)。
                // 下符尾: 通常側=右、ずらした側=左(上位音から下へ向かって交互)。
                // 3音以上の連続する2度でも同じ列に隣接符頭が並ばないようにする。
                for hi in 0..<heads.count { heads[hi].x = headX }
                if stemUp {
                    for hi in 1..<heads.count where heads[hi].p - heads[hi - 1].p == 1 {
                        heads[hi].x = heads[hi - 1].x == headX ? headX + headW - stemW : headX
                    }
                } else {
                    for hi in stride(from: heads.count - 2, through: 0, by: -1)
                        where heads[hi + 1].p - heads[hi].p == 1 {
                        heads[hi].x = heads[hi + 1].x == headX ? headX - headW + stemW : headX
                    }
                }
                // accidentals: stacked right-to-left from the head's left edge
                let headLeft = (heads.map { $0.x }.min() ?? headX) - headW / 2
                for ai in accs.indices {
                    accs[ai].x = headLeft - s * 0.2 - CGFloat(ai % 2) * s * 1.0
                }

                let stemX = stemUp ? headX + headW / 2 - stemW / 2 : headX - headW / 2 + stemW / 2
                let topCy = heads.map { $0.cy }.min() ?? 0
                let botCy = heads.map { $0.cy }.max() ?? 0
                var tipY: CGFloat
                if stemUp {
                    tipY = min(botCy - s * 3.5, topCy - s * 2.5, s * 2)
                } else {
                    tipY = max(topCy + s * 3.5, botCy + s * 2.5, s * 2)
                }
                if n.glyph == .whole { tipY = 0 }

                placed[idx] = PlacedNote(note: n, x: headX, heads: heads, stemUp: stemUp,
                                         stemX: stemX, tipY: tipY, restCenterX: 0,
                                         topCy: topCy, botCy: botCy)
                accMap[idx] = accs
                if n.beamEnd { curBeam = -1 }
            }
        }

        // ---- pass 2: beams ----
        struct BeamGeo { var yAtX0: CGFloat; var yAtX1: CGFloat; var x0: CGFloat; var x1: CGFloat; var stemUp: Bool }
        var beamGeo: [Int: BeamGeo] = [:]
        for (bi, members) in beamGroups.enumerated() {
            let pairs: [(Int, PlacedNote)] = members.compactMap { m in placed[m].map { (m, $0) } }
            let notes = pairs.filter { !$0.1.note.isRest }
            guard pairs.count >= 2, notes.count >= 1 else { continue }
            // group direction: note farthest from the middle line decides
            let gMax = notes.flatMap { $0.1.heads.map { $0.p } }.max() ?? 4
            let gMin = notes.flatMap { $0.1.heads.map { $0.p } }.min() ?? 4
            let stemUp = (4 - gMin) >= (gMax - 4)
            // recompute stem x for the group direction
            func stemX(_ pn: PlacedNote) -> CGFloat {
                pn.note.isRest ? pn.restCenterX
                    : (stemUp ? pn.x + headW / 2 - stemW / 2 : pn.x - headW / 2 + stemW / 2)
            }
            guard let firstPair = pairs.first, let lastPair = pairs.last else { continue }
            let fx = stemX(firstPair.1)
            let lx = stemX(lastPair.1)
            guard lx > fx else { continue }
            func reqTip(_ pn: PlacedNote) -> CGFloat {
                stemUp ? min(pn.botCy - s * 3.0, pn.topCy - s * 2.5)
                       : max(pn.topCy + s * 3.0, pn.botCy + s * 2.5)
            }
            guard let firstNote = notes.first, let lastNote = notes.last else { continue }
            let firstRef = stemUp ? firstNote.1.topCy : firstNote.1.botCy
            let lastRef = stemUp ? lastNote.1.topCy : lastNote.1.botCy
            var slope = (lastRef - firstRef) * 0.25
            slope = max(-s * 0.5, min(s * 0.5, slope))
            // 中間の音が両端より外側にある(凹形)ときは水平に
            if notes.count > 2 {
                let inner = notes.dropFirst().dropLast().map { stemUp ? $0.1.topCy : $0.1.botCy }
                let concave = stemUp
                    ? inner.contains { $0 < min(firstRef, lastRef) }
                    : inner.contains { $0 > max(firstRef, lastRef) }
                if concave { slope = 0 }
            }
            var beamAtFirst: CGFloat = stemUp ? .greatestFiniteMagnitude : -.greatestFiniteMagnitude
            for (_, pn) in notes {
                let want = reqTip(pn) - slope * (stemX(pn) - fx) / (lx - fx)
                beamAtFirst = stemUp ? min(beamAtFirst, want) : max(beamAtFirst, want)
            }
            // 符尾は少なくとも中央線まで届かせる
            if stemUp { beamAtFirst = min(beamAtFirst, s * 2 - max(0, slope)) }
            else { beamAtFirst = max(beamAtFirst, s * 2 - min(0, slope)) }
            beamGeo[bi] = BeamGeo(yAtX0: beamAtFirst, yAtX1: beamAtFirst + slope,
                                  x0: fx, x1: lx, stemUp: stemUp)
            for (m, var pn) in pairs {
                pn.stemX = stemX(pn)
                pn.tipY = beamAtFirst + slope * (pn.stemX - fx) / (lx - fx)
                pn.stemUp = stemUp
                placed[m] = pn
            }
        }

        // ---- pass 3: emit glyphs ----
        for (idx, item) in meas.items.enumerated() {
            guard case .note(let n) = item, let pn = placed[idx] else { continue }
            if n.rest == .invisible || n.rest == .spacer { continue }

            if n.isRest {
                let s0 = shapes.count
                emitRest(n, x: pn.restCenterX, measX0: x0, measX1: x1, meter: plan.meterAt[mi])
                registerTarget(n, x: n.rest == .measure ? (x0 + x1) / 2 : pn.restCenterX, s0: s0)
                continue
            }

            for a in accMap[idx] ?? [] {
                emitGlyph(accidentalCP(a.acc), x: a.x, y: a.cy, align: .right)
            }

            if !n.graceNotes.isEmpty {
                let firstHead = (pn.heads.map { $0.x }.min() ?? pn.x) - headW / 2
                let accCount = accMap[idx]?.count ?? 0
                let accLeft = accCount == 0
                    ? firstHead
                    : firstHead - CGFloat(min(2, accCount)) * s * 0.95 - s * 0.2
                emitGrace(n.graceNotes, rightX: accLeft - s * 0.2, bottom: bottom, perc: perc)
            }

            // stems: span every head of the chord up to the tip
            let beamed = beamOfItem[idx].flatMap { beamGeo[$0] } != nil
            if n.glyph != .whole {
                let p = CGMutablePath()
                if pn.stemUp {
                    let from = pn.botCy - s * 0.17
                    p.addRect(CGRect(x: pn.stemX - stemW / 2, y: pn.tipY, width: stemW, height: from - pn.tipY))
                } else {
                    let from = pn.topCy + s * 0.17
                    p.addRect(CGRect(x: pn.stemX - stemW / 2, y: from, width: stemW, height: pn.tipY - from))
                }
                shapes.append(.fill(p, .primary))
            }

            // flags for un-beamed notes
            if !beamed && n.glyph.flagCount > 0 {
                let i = min(n.glyph.flagCount, 4) - 1
                emitGlyph(pn.stemUp ? SMuFL.flagsUp[i] : SMuFL.flagsDown[i],
                          x: pn.stemX - stemW / 2, y: pn.tipY)
            }

            // noteheads (cursor-tracked range)
            let s0 = shapes.count
            let headCP: UInt32
            switch n.glyph {
            case .whole: headCP = SMuFL.noteheadWhole
            case .half: headCP = SMuFL.noteheadHalf
            default: headCP = SMuFL.noteheadBlack
            }
            for h in pn.heads {
                emitGlyph(h.xHead ? SMuFL.noteheadX : headCP, x: h.x, y: h.cy, align: .center)
            }
            // ledger lines (per column so seconds share them)
            let ledgerW = headW + s * 0.8
            for h in pn.heads where h.p < -1 || h.p > 9 {
                var lp = h.p < 0 ? -2 : 10
                while h.p < 0 ? lp >= h.p : lp <= h.p {
                    let p = CGMutablePath()
                    p.addRect(CGRect(x: h.x - ledgerW / 2, y: staffH - CGFloat(lp) * s / 2 - 0.6,
                                     width: ledgerW, height: 1.2))
                    shapes.append(.fill(p, .primary))
                    lp += h.p < 0 ? -2 : 2
                }
            }
            // augmentation dots
            if n.dots > 0 {
                let rightX = (pn.heads.map { $0.x }.max() ?? pn.x) + headW / 2 + s * 0.35
                    + (pn.stemUp && beamed == false && n.glyph.flagCount > 0 ? s * 0.6 : 0)
                var used = Set<Int>()
                for h in pn.heads {
                    var dp = h.p % 2 == 0 ? h.p + 1 : h.p      // 線上なら上の間へ
                    if used.contains(dp) { dp -= 2 }
                    used.insert(dp)
                    for d in 0..<n.dots {
                        emitGlyph(SMuFL.augmentationDot, x: rightX + CGFloat(d) * s * 0.5,
                                  y: staffH - CGFloat(dp) * s / 2)
                    }
                }
            }
            registerTarget(n, x: pn.x, s0: s0)

            if let cs = n.chordSymbol, !cs.isEmpty { rowChords.append((pn.x, cs)) }

            if let ly = n.lyric, !ly.syllable.isEmpty {
                var ext: CGFloat? = nil
                if ly.underscoreAfter {
                    ext = lyricExtendTarget(items: meas.items, placed: placed, from: idx, x1: x1)
                }
                rowLyrics.append((x: pn.x, text: ly.syllable, hyphen: ly.hyphenAfter, extendTo: ext))
            }
        }

        // beams on top of stems
        for (bi, members) in beamGroups.enumerated() {
            guard let g = beamGeo[bi] else { continue }
            let beamThick = s * 0.5
            let dir: CGFloat = g.stemUp ? 1 : -1
            func yAt(_ x: CGFloat) -> CGFloat {
                g.yAtX0 + (g.yAtX1 - g.yAtX0) * (x - g.x0) / (g.x1 - g.x0)
            }
            func beamRect(_ sx0: CGFloat, _ sx1: CGFloat, _ off: CGFloat) {
                let bp = CGMutablePath()
                bp.move(to: CGPoint(x: sx0, y: yAt(sx0) + off))
                bp.addLine(to: CGPoint(x: sx1, y: yAt(sx1) + off))
                bp.addLine(to: CGPoint(x: sx1, y: yAt(sx1) + off + beamThick * dir))
                bp.addLine(to: CGPoint(x: sx0, y: yAt(sx0) + off + beamThick * dir))
                bp.closeSubpath()
                shapes.append(.fill(bp, .primary))
            }
            beamRect(g.x0 - stemW / 2, g.x1 + stemW / 2, 0)
            // secondary beams (partial beams become short stubs)
            for lvl in 2...4 {
                var runStart: Int? = nil
                let off = CGFloat(lvl - 1) * s * 0.75 * dir
                for (k, itemIdx) in members.enumerated() {
                    guard let pn = placed[itemIdx] else { continue }
                    let needs = !pn.note.isRest && pn.note.glyph.flagCount >= lvl
                    if needs && runStart == nil { runStart = k }
                    if (!needs || k == members.count - 1), let rs = runStart {
                        let re = needs ? k : k - 1
                        guard let sp0 = placed[members[rs]], let sp1 = placed[members[re]] else {
                            runStart = nil
                            continue
                        }
                        var sx0 = sp0.stemX - stemW / 2
                        var sx1 = sp1.stemX + stemW / 2
                        if rs == re {
                            // 単独: 前の音があれば左へ、なければ右へ短いビーム
                            if rs > 0 { sx0 = sx1 - s * 1.1 } else { sx1 = sx0 + s * 1.1 }
                        }
                        beamRect(sx0, sx1, off)
                        runStart = nil
                    }
                }
            }
        }

        // decorations / ties / slurs
        for (idx, item) in meas.items.enumerated() {
            guard case .note(let n) = item, let pn = placed[idx] else { continue }
            emitDecorations(n, pn: pn, vi: vi)
            guard !n.isRest else { continue }
            // resolve pending ties whose target is in this note
            var remaining: [TiePend] = []
            for tp in ties[vi] {
                if let h = pn.heads.first(where: { $0.p == tp.step }) {
                    emitArc(x0: tp.x, y0: tp.cy, x1: h.x - headW * 0.6, y1: h.cy,
                            above: tp.above, thin: true)
                } else {
                    remaining.append(tp)
                }
            }
            ties[vi] = remaining
            if n.tieStart {
                let maxStep = pn.heads.map { $0.p }.max() ?? 0
                let minStep = pn.heads.map { $0.p }.min() ?? 0
                for h in pn.heads {
                    let above = pn.heads.count > 1 ? h.p >= (maxStep + minStep) / 2 + 1 : !pn.stemUp
                    ties[vi].append(TiePend(step: h.p, x: h.x + headW * 0.6,
                                            cy: h.cy + (above ? -s * 0.35 : s * 0.35), above: above))
                }
            }
            for _ in 0..<n.slurEnds {
                if !slurs[vi].isEmpty {
                    let sp = slurs[vi].removeLast()
                    let y1 = sp.above ? min(pn.topCy, pn.stemUp ? pn.tipY : pn.topCy) - s * 0.8
                                      : max(pn.botCy, pn.stemUp ? pn.botCy : pn.tipY) + s * 0.8
                    emitArc(x0: sp.x, y0: sp.y, x1: pn.x, y1: y1, above: sp.above, thin: false)
                }
            }
            for _ in 0..<n.slurStarts {
                let above = !pn.stemUp
                slurs[vi].append(SlurPend(x: pn.x,
                                          y: above ? pn.topCy - s * 0.8 : pn.botCy + s * 0.8,
                                          above: above))
            }
        }
        // tuplets: number (and bracket when not fully beamed) on the stem side
        for tr in tupletRanges {
            guard let a = placed[tr.lo], let b = placed[tr.hi] else { continue }
            let members = (tr.lo...tr.hi).compactMap { placed[$0] }.filter { !$0.note.isRest }
            let above = members.first.map { $0.stemUp } ?? true
            let midX = (a.x + b.x) / 2
            let ty: CGFloat
            if above {
                ty = min(members.map { min($0.tipY == 0 ? $0.topCy : $0.tipY, $0.topCy) }.min() ?? 0, 0) - s * 0.7
            } else {
                ty = max(members.map { max($0.tipY, $0.botCy) }.max() ?? staffH, staffH) + s * 1.5
            }
            let beamedAll = (tr.lo...tr.hi).allSatisfy { beamOfItem[$0] != nil } && Set((tr.lo...tr.hi).compactMap { beamOfItem[$0] }).count == 1
            if !beamedAll {
                let x0 = a.x - headW / 2, x1 = b.x + headW / 2
                let hook: CGFloat = above ? s * 0.5 : -s * 0.5
                let by = ty - (above ? s * 0.45 : -s * 0.45) * -1
                let p = CGMutablePath()
                p.move(to: CGPoint(x: x0, y: by + hook)); p.addLine(to: CGPoint(x: x0, y: by))
                p.addLine(to: CGPoint(x: midX - s * 0.7, y: by))
                p.move(to: CGPoint(x: midX + s * 0.7, y: by)); p.addLine(to: CGPoint(x: x1, y: by))
                p.addLine(to: CGPoint(x: x1, y: by + hook))
                shapes.append(.stroke(p, lineWidth: 0.9, .primary))
            }
            emitDigits(tr.n, base: SMuFL.tuplet0, centerX: midX, y: ty + s * 0.45, scale: 0.8)
        }
    }

    private func lyricExtendTarget(items: [VItem], placed: [PlacedNote?], from idx: Int, x1: CGFloat) -> CGFloat {
        for j in (idx + 1)..<items.count {
            if case .note = items[j], let pj = placed[j] { return pj.x }
        }
        return x1 - s
    }

    /// カーソル・タップ用の領域を登録(ローカル座標、行の配置後に平行移動される)
    private func registerTarget(_ n: ABCNote, x: CGFloat, s0: Int) {
        let rect = CGRect(x: x - headW * 0.8, y: -s * 0.75, width: headW * 1.6, height: staffH + s * 1.5)
        targets[n.id] = CursorTarget(rect: rect, shapeRange: s0..<shapes.count)
        rowTargetIDs.append(n.id)
    }

    // MARK: glyphs

    private func emitRest(_ n: ABCNote, x: CGFloat, measX0: CGFloat, measX1: CGFloat, meter: ABCMeter) {
        let cx = n.rest == .measure ? (measX0 + measX1) / 2 : x
        let cp: UInt32
        var y = s * 2
        switch n.glyph {
        case .whole: cp = SMuFL.restWhole; y = s * 1
        case .half: cp = SMuFL.restHalf
        case .quarter: cp = SMuFL.restQuarter
        case .eighth: cp = SMuFL.rest8th
        case .sixteenth: cp = SMuFL.rest16th
        case .thirtySecond: cp = SMuFL.rest32nd
        case .sixtyFourth: cp = SMuFL.rest64th
        }
        let r = emitGlyph(n.rest == .measure ? SMuFL.restWhole : cp, x: cx,
                          y: n.rest == .measure ? s * 1 : y, align: .center)
        if n.rest == .measure {
            let count = (n.duration / meter.measureLength).value
            if count > 1.01 {
                emitDigits(Int(count.rounded()), base: SMuFL.timeSig0, centerX: cx, y: -s * 1.2, scale: 0.8)
            }
        }
        if n.dots > 0 {
            for d in 0..<n.dots {
                emitGlyph(SMuFL.augmentationDot, x: r.maxX + s * 0.3 + CGFloat(d) * s * 0.5, y: s * 1.5)
            }
        }
    }

    private func emitGrace(_ graces: [ABCNote], rightX: CGFloat, bottom: Int, perc: Bool) {
        let sc: CGFloat = 0.62
        let step = s * 0.8
        var gx = rightX - CGFloat(graces.count) * step + step / 2
        var stems: [(x: CGFloat, top: CGFloat)] = []
        for g in graces {
            let ps = g.pitches.map { perc ? drumPos($0.midi).p : $0.step - bottom }
            for p in ps {
                emitGlyph(SMuFL.noteheadBlack, x: gx, y: staffH - CGFloat(p) * s / 2, scale: sc, align: .center)
                if p < -1 || p > 9 {
                    var lp = p < 0 ? -2 : 10
                    while p < 0 ? lp >= p : lp <= p {
                        let l = CGMutablePath()
                        l.addRect(CGRect(x: gx - headW * 0.55, y: staffH - CGFloat(lp) * s / 2 - 0.5,
                                         width: headW * 1.1, height: 1))
                        shapes.append(.fill(l, .primary))
                        lp += p < 0 ? -2 : 2
                    }
                }
            }
            let topCy = staffH - CGFloat(ps.max() ?? 8) * s / 2
            let botCy = staffH - CGFloat(ps.min() ?? 8) * s / 2
            let sx = gx + headW * sc / 2 - 0.4
            stems.append((sx, topCy - s * 2.5))
            let sp = CGMutablePath()
            sp.addRect(CGRect(x: sx - 0.4, y: topCy - s * 2.5, width: 0.8, height: botCy - topCy + s * 2.5))
            shapes.append(.fill(sp, .primary))
            gx += step
        }
        if stems.count >= 2, let firstStem = stems.first, let lastStem = stems.last,
           let y0 = stems.map({ $0.top }).min() {
            let p = CGMutablePath()
            p.addRect(CGRect(x: firstStem.x - 0.4, y: y0, width: lastStem.x - firstStem.x + 0.8, height: s * 0.35))
            shapes.append(.fill(p, .primary))
            for st in stems where st.top > y0 {
                let e = CGMutablePath()
                e.addRect(CGRect(x: st.x - 0.4, y: y0, width: 0.8, height: st.top - y0))
                shapes.append(.fill(e, .primary))
            }
        } else if let st = stems.first {
            emitGlyph(SMuFL.flagsUp[0], x: st.x - 0.4, y: st.top, scale: 0.62)
            // acciaccatura slash
            let sl = CGMutablePath()
            sl.move(to: CGPoint(x: st.x - s * 0.5, y: st.top + s * 1.5))
            sl.addLine(to: CGPoint(x: st.x + s * 0.6, y: st.top + s * 0.5))
            shapes.append(.stroke(sl, lineWidth: 0.9, .primary))
        }
    }

    private func emitDecorations(_ n: ABCNote, pn: PlacedNote, vi: Int) {
        if pn.heads.isEmpty && !n.isRest { return }
        // 符頭側(符尾と反対)に置くアーティキュレーション
        let headSideBelow = pn.stemUp
        let headSideY = headSideBelow ? max(pn.botCy + s * 1.0, staffH + s * 0.6)
                                      : min(pn.topCy - s * 1.0, -s * 0.6)
        // 五線の上に置く記号の基準(符尾・符頭のいずれよりも上)
        let aboveY = min(pn.topCy, pn.stemUp && pn.tipY != 0 ? pn.tipY : pn.topCy, 0) - s * 0.9
        var stackAbove = aboveY
        func nextAbove(_ h: CGFloat) -> CGFloat { let y = stackAbove; stackAbove -= h; return y }
        for d in n.decorations {
            switch d {
            case .staccato:
                emitGlyph(headSideBelow ? SMuFL.staccatoBelow : SMuFL.staccatoAbove, x: pn.x, y: headSideY, align: .center)
            case .accent:
                emitGlyph(headSideBelow ? SMuFL.accentBelow : SMuFL.accentAbove, x: pn.x, y: headSideY, align: .center)
            case .tenuto:
                emitGlyph(headSideBelow ? SMuFL.tenutoBelow : SMuFL.tenutoAbove, x: pn.x, y: headSideY, align: .center)
            case .fermata:
                emitGlyph(SMuFL.fermataAbove, x: pn.x, y: nextAbove(s * 2), align: .center)
            case .trill:
                emitGlyph(SMuFL.trill, x: pn.x, y: nextAbove(s * 1.8), align: .center)
            case .mordent:
                emitGlyph(SMuFL.mordent, x: pn.x, y: nextAbove(s * 1.4), align: .center)
            case .roll:
                emitGlyph(SMuFL.turn, x: pn.x, y: nextAbove(s * 1.4), align: .center)
            case .upbow:
                emitGlyph(SMuFL.upBow, x: pn.x, y: nextAbove(s * 1.8), align: .center)
            case .downbow:
                emitGlyph(SMuFL.downBow, x: pn.x, y: nextAbove(s * 1.6), align: .center)
            case .breath:
                emitGlyph(SMuFL.breathMark, x: pn.x + headW + s * 0.4, y: -s * 0.5, align: .center)
            case .dynamic(_, let label):
                let cps = label.compactMap { SMuFL.dynamicLetters[$0] }
                if cps.count == label.count {
                    let total = cps.reduce(0) { $0 + glyphWidth($1) } + CGFloat(cps.count - 1) * 0.5
                    var x = pn.x - total / 2
                    for cp in cps {
                        let g = MusicFont.glyph(cp, size: staffH)
                        emitGlyph(cp, x: x - (g?.bounds.minX ?? 0), y: staffH + s * 2.6)
                        x += glyphWidth(cp) + 0.5
                    }
                } else {
                    emitText(label, size: 11, bold: true,
                             rect: CGRect(x: pn.x - 25, y: staffH + s * 1.6, width: 50, height: 13),
                             anchor: .center, ink: .primary)
                }
            case .crescendoStart:
                hairpins[vi].append(HairpinPend(cresc: true, x: pn.x))
            case .diminuendoStart:
                hairpins[vi].append(HairpinPend(cresc: false, x: pn.x))
            case .crescendoEnd, .diminuendoEnd:
                if let hp = hairpins[vi].last {
                    var isCrescEnd = false
                    if case .crescendoEnd = d { isCrescEnd = true }
                    if isCrescEnd == hp.cresc {
                        hairpins[vi].removeLast()
                        emitHairpin(cresc: hp.cresc, x0: hp.x, x1: pn.x, y: staffH + s * 2.2)
                    }
                }
            }
        }
    }

    private func emitHairpin(cresc: Bool, x0: CGFloat, x1: CGFloat, y: CGFloat) {
        guard x1 > x0 + s else { return }
        let h = s * 0.45
        let p = CGMutablePath()
        if cresc {
            p.move(to: CGPoint(x: x1, y: y - h)); p.addLine(to: CGPoint(x: x0, y: y))
            p.addLine(to: CGPoint(x: x1, y: y + h))
        } else {
            p.move(to: CGPoint(x: x0, y: y - h)); p.addLine(to: CGPoint(x: x1, y: y))
            p.addLine(to: CGPoint(x: x0, y: y + h))
        }
        shapes.append(.stroke(p, lineWidth: 0.9, .primary))
    }

    /// タイ・スラー: 中央が太い三日月形で塗る
    private func emitArc(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, above: Bool, thin: Bool) {
        guard x1 - x0 > s * 0.5 else { return }
        let span = x1 - x0
        let dir: CGFloat = above ? -1 : 1
        let h = min(s * 0.5 + span * 0.08, thin ? s * 1.2 : s * 2.0) * dir
        let thick = (thin ? s * 0.16 : s * 0.2) * dir
        let c1 = CGPoint(x: x0 + span * 0.25, y: y0 + h * 1.33)
        let c2 = CGPoint(x: x1 - span * 0.25, y: y1 + h * 1.33)
        // 外側の曲線で行き、thick だけ浅い内側の曲線で戻る
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0, y: y0))
        p.addCurve(to: CGPoint(x: x1, y: y1), control1: c1, control2: c2)
        p.addCurve(to: CGPoint(x: x0, y: y0),
                   control1: CGPoint(x: c2.x, y: c2.y - thick * 1.33),
                   control2: CGPoint(x: c1.x, y: c1.y - thick * 1.33))
        p.closeSubpath()
        shapes.append(.fill(p, .primary))
    }

    private func emitText(_ str: String, size: CGFloat, bold: Bool, rect: CGRect,
                          anchor: ScoreTextAnchor, ink: ScoreInk) {
        shapes.append(.text(str, size: size, bold: bold, rect: rect, anchor: anchor, ink: ink))
    }

    // MARK: percussion map

    private func drumPos(_ midi: Int) -> (p: Int, x: Bool) {
        switch midi {
        case 35, 36: return (1, false)           // kick (bottom space)
        case 38, 40, 37: return (5, false)       // snare / clap / side stick
        case 42, 44: return (9, true)            // closed/pedal hat
        case 46: return (9, true)                // open hat
        case 41: return (1, false)               // low floor tom
        case 43: return (2, false)               // high floor tom
        case 45: return (4, false)               // low tom
        case 47: return (6, false)               // mid tom
        case 48, 50: return (7, false)           // high toms
        case 49, 55: return (10, true)           // crash / splash
        case 51, 52, 53, 57: return (8, true)    // ride
        case 56: return (10, true)               // cowbell
        case 54: return (9, true)                // tambourine
        default: return (4, false)
        }
    }
}

// MARK: - ScorePainter

public enum ScorePainter {
    private static var colorCache: [ScoreInk: CGColor] = [:]
    private static let lock = NSLock()

    static func color(_ ink: ScoreInk) -> CGColor {
        lock.lock(); defer { lock.unlock() }
        if let c = colorCache[ink] { return c }
        let c: CGColor
        switch ink {
        case .primary: c = CGColor(red: 0.11, green: 0.13, blue: 0.14, alpha: 1)
        case .accent: c = CGColor(red: 0.251, green: 0.357, blue: 0.780, alpha: 1)
        case .faint: c = CGColor(red: 0.50, green: 0.55, blue: 0.55, alpha: 1)
        }
        colorCache[ink] = c
        return c
    }

    /// Replays an EngravedScore into a CGContext in plain Quartz orientation
    /// (origin bottom-left, y-up) — bitmap / PDF 書き出し用。
    public static func draw(_ score: EngravedScore, in ctx: CGContext,
                            highlight: Set<Int>, cursorID: Int?) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: score.size.height)
        ctx.scaleBy(x: 1, y: -1)
        drawYDown(score, in: ctx, highlight: highlight, cursorID: cursorID, system: nil)
        ctx.restoreGState()
    }

    /// y-down のコンテキストに描く。system を指定するとその段だけを、段の上端を y=0 として描く。
    public static func drawYDown(_ score: EngravedScore, in ctx: CGContext,
                                 highlight: Set<Int>, cursorID: Int?, system: Int?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        var range = 0..<score.shapes.count
        if let si = system, score.systems.indices.contains(si) {
            let sys = score.systems[si]
            range = sys.shapeRange
            ctx.translateBy(x: 0, y: -sys.band.minY)
        }

        var accentShapes: Set<Int> = []
        for id in highlight {
            if let t = score.targets[id], system == nil || t.system == system {
                for i in t.shapeRange { accentShapes.insert(i) }
            }
        }

        drawCursorColumn(score, in: ctx, cursorID: cursorID, system: system)

        for i in range {
            let ink: (ScoreInk) -> CGColor = { color(accentShapes.contains(i) ? .accent : $0) }
            drawShape(score.shapes[i], in: ctx, ink: ink)
        }
    }

    /// The cursor sits below the unchanged score layer.
    static func drawCursorYDown(_ score: EngravedScore, in ctx: CGContext,
                                cursorID: Int?, system: Int) {
        guard score.systems.indices.contains(system) else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: 0, y: -score.systems[system].band.minY)
        drawCursorColumn(score, in: ctx, cursorID: cursorID, system: system)
    }

    /// Draw just the active note shapes, rather than replaying the whole staff.
    static func drawHighlightsYDown(_ score: EngravedScore, in ctx: CGContext,
                                    highlight: Set<Int>, system: Int) {
        guard score.systems.indices.contains(system) else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: 0, y: -score.systems[system].band.minY)
        var indices = Set<Int>()
        for id in highlight {
            if let target = score.targets[id], target.system == system {
                indices.formUnion(target.shapeRange)
            }
        }
        let accent = color(.accent)
        for index in indices.sorted() where score.shapes.indices.contains(index) {
            drawShape(score.shapes[index], in: ctx, ink: { _ in accent })
        }
    }

    private static func drawCursorColumn(_ score: EngravedScore, in ctx: CGContext,
                                         cursorID: Int?, system: Int?) {
        // 再生位置: 鳴っている音符の列を段の全五線にわたって淡く塗る(記譜の下に敷く)
        if let cid = cursorID, let t = score.targets[cid], system == nil || t.system == system,
           score.systems.indices.contains(t.system) {
            let sys = score.systems[t.system]
            let pad = t.rect.height * 0.12
            let col = CGRect(x: t.rect.midX - max(9, t.rect.width * 0.62), y: sys.staffTop - pad,
                             width: max(18, t.rect.width * 1.24), height: sys.staffBottom - sys.staffTop + pad * 2)
            ctx.setFillColor(color(.accent).copy(alpha: 0.16)!)
            ctx.addPath(CGPath(roundedRect: col, cornerWidth: col.width / 3, cornerHeight: col.width / 3, transform: nil))
            ctx.fillPath()
        }
    }

    private static func drawShape(_ shape: EngravedShape, in ctx: CGContext,
                                  ink: (ScoreInk) -> CGColor) {
        switch shape {
        case .fill(let path, let k):
            ctx.setFillColor(ink(k))
            ctx.addPath(path)
            ctx.fillPath()
        case .stroke(let path, let lw, let k):
            ctx.setStrokeColor(ink(k))
            ctx.setLineWidth(lw)
            ctx.setLineCap(.butt)
            ctx.setLineJoin(.miter)
            ctx.addPath(path)
            ctx.strokePath()
        case .text(let str, let size, let bold, let rect, let anchor, let k):
            let font = ScoreFonts.font(size: size, bold: bold)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink(k)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: str, attributes: attrs))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let tw = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            var tx = rect.minX
            switch anchor {
            case .center: tx = rect.midX - tw / 2
            case .trailing: tx = rect.maxX - tw
            case .leading: break
            }
            let baseline = rect.midY + (ascent - descent) / 2
            ctx.saveGState()
            ctx.translateBy(x: tx, y: baseline)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

}
