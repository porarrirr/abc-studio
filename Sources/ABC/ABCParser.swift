import Foundation

/// ABC 記法パーサ。abcjs が扱う一般的なサブセットを対象とする。
/// 例外は投げず、問題はすべて ABCBook.diagnostics に報告する。
public enum ABCParser {
    /// Parses a full ABC file which may contain multiple tunes.
    /// Never throws; problems are reported in ABCBook.diagnostics.
    public static func parse(_ source: String) -> ABCBook {
        Engine(source).parseBook()
    }
}

// MARK: - 内部ユーティリティ

private extension Character {
    var isASCIILetter: Bool { isASCII && isLetter }
    var isASCIIDigit: Bool { isASCII && isNumber }
}

private let noteLetterSet = Set<Character>("ABCDEFGabcdefg")
private let accidentalCharSet = Set<Character>("^_=")
private let semitoneOf: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
private let stepOf: [Character: Int] = ["C": 0, "D": 1, "E": 2, "F": 3, "G": 4, "A": 5, "B": 6]
private let fifthsOf: [Character: Int] = ["C": 0, "G": 1, "D": 2, "A": 3, "E": 4, "B": 5, "F": -1]
private let sharpOrder = [3, 0, 4, 1, 5, 2, 6]   // F C G D A E B
private let flatOrder = [6, 2, 5, 1, 4, 0, 3]    // B E A D G C F
private let modeOffset: [String: Int] = [
    "": 0, "ion": 0, "ionian": 0, "maj": 0, "major": 0,
    "m": -3, "min": -3, "minor": -3, "aeo": -3, "aeolian": -3,
    "dor": -2, "dorian": -2, "phr": -4, "phrygian": -4,
    "lyd": 1, "lydian": 1, "mix": -1, "mixolydian": -1,
    "loc": -5, "locrian": -5,
]
private let tupletDefaultP: [Int: Int] = [2: 3, 3: 2, 4: 3, 5: 4, 6: 2, 7: 4, 8: 3, 9: 8]
private let dynamicVelocity: [String: Int] = [
    "ppp": 30, "pp": 45, "p": 55, "mp": 65, "mf": 80,
    "f": 96, "ff": 110, "fff": 120, "sfz": 100, "sf": 100, "fz": 100,
]

/// 1物理行(改行・末尾 \r 除去済み)
private struct SrcLine {
    var text: String    // 行内容
    var start: Int      // 行頭の UTF-8 バイトオフセット(ファイル基準)
    var number: Int     // 1 始まり行番号
}

/// 継続行結合・コメント除去済みの論理行。各文字にファイル位置を持つ。
private struct LogicalLine {
    var chars: [Character] = []
    var offs: [Int] = []     // 各文字の UTF-8 バイトオフセット
    var lines: [Int] = []    // 各文字のファイル行番号
    var cols: [Int] = []     // 各文字の物理行内桁位置
}

/// ファイルヘッダ由来のデフォルト値
private struct HeaderFields {
    var title: String?
    var composer: String?
    var meter: ABCMeter?
    var noteLen: ABCFraction?
    var tempo: ABCTempo?
    var key: ABCKeySignature?
    var keyClef: ABCClef?
    var scoreOrder: [String]?
    var voices: [(id: String, name: String?, clef: ABCClef?)] = []
}

/// 引用符外の % 以降をコメントとして除去
private func stripComment(_ s: String) -> String {
    var inQuote = false
    var end = s.startIndex
    while end < s.endIndex {
        let c = s[end]
        if c == "\"" { inQuote.toggle() } else if c == "%" && !inQuote { break }
        end = s.index(after: end)
    }
    return String(s[..<end])
}

private func parseMeter(_ s: String) -> ABCMeter? {
    let t = s.trimmingCharacters(in: .whitespaces)
    switch t {
    case "C":
        return .commonTime
    case "C|":
        return ABCMeter(style: .cut, measureLength: ABCFraction(1, 2),
                        beamUnit: ABCFraction(1, 4), display: "C|")
    case "none", "None", "NONE":
        return ABCMeter(style: .none, measureLength: ABCFraction(1, 1),
                        beamUnit: ABCFraction(1, 4), display: "")
    default:
        break
    }
    let parts = t.split(separator: "/")
    if parts.count == 2,
       let n = Int(parts[0].trimmingCharacters(in: .whitespaces)),
       let d = Int(parts[1].trimmingCharacters(in: .whitespaces)), d > 0 {
        return ABCMeter(num: n, den: d)
    }
    return nil
}

/// "n/d" または "n" の分数パース
private func parseLen(_ s: String) -> ABCFraction? {
    let t = s.trimmingCharacters(in: .whitespaces)
    let parts = t.split(separator: "/")
    if parts.count == 2,
       let n = Int(parts[0].trimmingCharacters(in: .whitespaces)),
       let d = Int(parts[1].trimmingCharacters(in: .whitespaces)), d != 0 {
        return ABCFraction(n, d)
    }
    if parts.count == 1, let n = Int(t), n != 0 { return ABCFraction(n, 1) }
    return nil
}

/// Q: テンポ指定("Allegro" 1/4=120 / 1/4=120 / 120)
private func parseTempo(_ s: String) -> ABCTempo {
    var tempo = ABCTempo()
    var rest = s.trimmingCharacters(in: .whitespaces)
    if let o = rest.firstIndex(of: "\"") {
        let after = rest.index(after: o)
        if let c = rest[after...].firstIndex(of: "\"") {
            tempo.text = String(rest[after..<c])
            rest = String(rest[rest.index(after: c)...]).trimmingCharacters(in: .whitespaces)
        }
    }
    guard !rest.isEmpty else { return tempo }
    if let eq = rest.firstIndex(of: "=") {
        let unitPart = rest[..<eq]
        let bpmPart = rest[rest.index(after: eq)...]
        var unit = ABCFraction(0, 1)
        var found = false
        for tok in unitPart.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if let fr = parseLen(String(tok)) { unit = unit + fr; found = true }
        }
        if found { tempo.unit = unit }
        if let b = Double(bpmPart.trimmingCharacters(in: .whitespaces)) { tempo.bpm = b }
    } else if let b = Double(rest) {
        tempo.bpm = b
    }
    return tempo
}

private func parseClef(_ s: String) -> ABCClef? {
    let v = String(s.lowercased().prefix(while: { $0.isLetter }))
    switch v {
    case "treble", "soprano": return .treble
    case "bass": return .bass
    case "alto", "mezzosoprano": return .alto
    case "tenor", "baritone": return .tenor
    case "perc", "percussion": return .percussion
    default: return nil
    }
}

/// K: の内容をパース。(調号, K: 内の clef= 属性)
private func parseKey(_ s: String) -> (key: ABCKeySignature, clef: ABCClef?)? {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return nil }
    let tokens = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    var clef: ABCClef? = nil
    var perc = false
    var modeWord: String? = nil
    for tok in tokens.dropFirst() {
        let low = tok.lowercased()
        if low == "perc" || low == "percussion" { perc = true } else if low.hasPrefix("clef=") {
            clef = parseClef(String(tok.dropFirst(5)))
        } else if modeOffset[low] != nil && modeWord == nil {
            modeWord = low
        }
    }
    let head = tokens[0]
    let low = head.lowercased()
    if low == "none" || low == "perc" {
        return (ABCKeySignature(display: head, accidentals: [],
                                isPercussion: perc || low == "perc"), clef)
    }
    guard let first = head.first, fifthsOf[first] != nil else { return nil }
    var idx = head.index(after: head.startIndex)
    var acc = 0
    while idx < head.endIndex {
        let c = head[idx]
        if c == "#" || c == "^" { acc += 1 } else if c == "b" || c == "_" { acc -= 1 } else { break }
        idx = head.index(after: idx)
    }
    var modeStr = String(head[idx...]).lowercased()
    if modeStr.isEmpty, let mw = modeWord { modeStr = mw }
    guard let off = modeOffset[modeStr] else { return nil }
    let fifths = (fifthsOf[first] ?? 0) + 7 * acc + off
    var accs: [(letter: Int, accidental: ABCAccidental)] = []
    if !perc {
        if fifths > 0 {
            for i in 0..<min(fifths, 7) { accs.append((letter: sharpOrder[i], accidental: .sharp)) }
        } else if fifths < 0 {
            for i in 0..<min(-fifths, 7) { accs.append((letter: flatOrder[i], accidental: .flat)) }
        }
    }
    return (ABCKeySignature(display: head, accidentals: accs, isPercussion: perc), clef)
}

/// V: 行の name= / clef= 属性
private func parseVoiceAttrs(_ s: String) -> (name: String?, clef: ABCClef?) {
    var name: String? = nil
    var clef: ABCClef? = nil
    var i = s.startIndex
    while i < s.endIndex {
        while i < s.endIndex && s[i].isWhitespace { i = s.index(after: i) }
        var key = ""
        while i < s.endIndex && s[i] != "=" && !s[i].isWhitespace {
            key.append(s[i]); i = s.index(after: i)
        }
        if i < s.endIndex && s[i] == "=" {
            i = s.index(after: i)
            var val = ""
            if i < s.endIndex && s[i] == "\"" {
                i = s.index(after: i)
                while i < s.endIndex && s[i] != "\"" {
                    val.append(s[i]); i = s.index(after: i)
                }
                if i < s.endIndex { i = s.index(after: i) }
            } else {
                while i < s.endIndex && !s[i].isWhitespace {
                    val.append(s[i]); i = s.index(after: i)
                }
            }
            switch key {
            case "name", "nm": name = val
            case "clef": if let c = parseClef(val) { clef = c }
            default: break
            }
        } else {
            while i < s.endIndex && !s[i].isWhitespace { i = s.index(after: i) }
        }
    }
    return (name, clef)
}

/// %%score の声部リスト
private func scoreVoices(_ s: String) -> [String] {
    let cleaned = s.map { "(){}[]|*".contains($0) ? " " : $0 }
    return String(cleaned)
        .split(whereSeparator: { $0 == " " || $0 == "\t" })
        .map(String.init)
        .filter { !$0.contains("=") }
}

private func accMap(_ k: ABCKeySignature) -> [Int: Int] {
    var m: [Int: Int] = [:]
    for a in k.accidentals { m[a.letter] = a.accidental.semitones }
    return m
}

private let glyphBases: [(ABCNoteGlyph, ABCFraction)] = [
    (.whole, ABCFraction(1, 1)), (.half, ABCFraction(1, 2)),
    (.quarter, ABCFraction(1, 4)), (.eighth, ABCFraction(1, 8)),
    (.sixteenth, ABCFraction(1, 16)), (.thirtySecond, ABCFraction(1, 32)),
    (.sixtyFourth, ABCFraction(1, 64)),
]

/// 書き込み音価 → 符頭タイプ + 付点数
private func glyphFor(_ len: ABCFraction) -> (ABCNoteGlyph, Int) {
    for (g, b) in glyphBases {
        if len == b { return (g, 0) }
        if len == b * ABCFraction(3, 2) { return (g, 1) }
        if len == b * ABCFraction(7, 4) { return (g, 2) }
        if len == b * ABCFraction(15, 8) { return (g, 3) }
    }
    for (g, b) in glyphBases where !(len < b) { return (g, 0) }
    return (.sixtyFourth, 0)
}

private func decoration(named name: String) -> ABCDecoration? {
    switch name {
    case "trill": return .trill
    case "fermata": return .fermata
    case "accent", "emphasis", ">": return .accent
    case "staccato": return .staccato
    case "tenuto": return .tenuto
    case "upbow": return .upbow
    case "downbow": return .downbow
    case "breath": return .breath
    case "mordent", "lowermordent", "pralltriller": return .mordent
    case "roll": return .roll
    case "<(", "crescendo(": return .crescendoStart
    case "<)", "crescendo)": return .crescendoEnd
    case ">(", "diminuendo(": return .diminuendoStart
    case ">)", "diminuendo)": return .diminuendoEnd
    default:
        if let v = dynamicVelocity[name] { return .dynamic(velocity: v, label: name) }
        return nil
    }
}

// MARK: - ファイルレベルエンジン

private final class Engine {
    let source: String
    var diagnostics: [ABCDiagnostic] = []
    var lineLookup: [Int: String] = [:]

    var warnedDirectives = Set<String>()
    var warnedUnknownLines = Set<Int>()
    var warnedChordLines = Set<Int>()
    var warnedGraceLines = Set<Int>()
    var pFileWarned = false

    init(_ source: String) { self.source = source }

    func diag(_ sev: ABCDiagnostic.Severity, _ line: Int, _ col: Int, _ msg: String) {
        let ctx = lineLookup[line]?.trimmingCharacters(in: .whitespaces) ?? ""
        diagnostics.append(ABCDiagnostic(severity: sev, line: line, column: col,
                                         message: msg, context: ctx))
    }

    func warnDirective(_ name: String, line: Int) {
        guard warnedDirectives.insert(name).inserted else { return }
        diag(.warning, line, 0, "対応していない %% ディレクティブです（無視されます）: %%\(name)")
    }
    func warnUnknownOnce(line: Int, col: Int) {
        guard warnedUnknownLines.insert(line).inserted else { return }
        diag(.warning, line, col, "ABC として解釈できない文字があります（無視されます）")
    }
    func warnChordOnce(_ line: Int) {
        guard warnedChordLines.insert(line).inserted else { return }
        diag(.error, line, 0, "和音の [ ] が閉じられていません。']' を追加してください")
    }
    func warnGraceOnce(_ line: Int) {
        guard warnedGraceLines.insert(line).inserted else { return }
        diag(.warning, line, 0, "括弧・装飾の対応が取れていません")
    }
    func warnPFile(_ line: Int) {
        guard !pFileWarned else { return }
        pFileWarned = true
        diag(.warning, line, 0, "P:（演奏順）は現在未対応です。譜面どおりに再生します")
    }

    func parseBook() -> ABCBook {
        let lines = physicalLines()
        for l in lines { lineLookup[l.number] = l.text }
        guard let firstX = lines.firstIndex(where: { $0.text.hasPrefix("X:") }) else {
            diag(.error, 0, 0, "曲が見つかりませんでした。X: で始まり K: を含む曲が必要です")
            return ABCBook(tunes: [], diagnostics: diagnostics)
        }
        var defaults = HeaderFields()
        for line in lines[..<firstX] { parseHeaderLine(line, into: &defaults) }

        var blocks: [[SrcLine]] = []
        var i = firstX
        while i < lines.count {
            guard lines[i].text.hasPrefix("X:") else { i += 1; continue }
            var j = i + 1
            while j < lines.count
                    && !lines[j].text.hasPrefix("X:")
                    && !lines[j].text.trimmingCharacters(in: .whitespaces).isEmpty {
                j += 1
            }
            blocks.append(Array(lines[i..<j]))
            i = j
        }
        var tunes: [ABCTune] = []
        for block in blocks {
            let ctx = TuneContext(block: block, index: tunes.count,
                                  total: blocks.count, defaults: defaults, engine: self)
            tunes.append(ctx.parse())
        }
        diagnostics.sort { a, b in
            if a.line != b.line { return a.line < b.line }
            if a.severity == b.severity { return false }
            return a.severity == .error
        }
        return ABCBook(tunes: tunes, diagnostics: diagnostics)
    }

    /// ファイルを物理行に分割(UTF-8 オフセット付き)
    func physicalLines() -> [SrcLine] {
        var result: [SrcLine] = []
        let src = source
        var segStart = src.startIndex
        var bytePos = 0
        var number = 1
        var idx = src.startIndex
        while idx < src.endIndex {
            let c = src[idx]
            // "\r\n" は1つの Character(書記素クラスタ)なのでまとめて判定する
            if c == "\n" || c == "\r" || c == "\r\n" {
                let rawSlice = src[segStart..<idx]
                var text = String(rawSlice)
                let adv = c.utf8.count
                let next = src.index(after: idx)
                if text.hasSuffix("\r") { text.removeLast() }
                result.append(SrcLine(text: text, start: bytePos, number: number))
                bytePos += rawSlice.utf8.count + adv
                number += 1
                segStart = next
                idx = next
            } else {
                idx = src.index(after: idx)
            }
        }
        let rawSlice = src[segStart...]
        var text = String(rawSlice)
        if text.hasSuffix("\r") { text.removeLast() }
        result.append(SrcLine(text: text, start: bytePos, number: number))
        return result
    }

    /// ファイルヘッダ(最初の X: より前)のフィールド
    func parseHeaderLine(_ line: SrcLine, into f: inout HeaderFields) {
        let text = line.text
        if text.hasPrefix("%%") {
            let body = String(text.dropFirst(2))
            let name = String(body.prefix(while: { !$0.isWhitespace }))
            if name == "score" {
                f.scoreOrder = scoreVoices(String(body.dropFirst(name.count)))
            } else if !name.isEmpty {
                warnDirective(name, line: line.number)
            }
            return
        }
        if text.hasPrefix("%") { return }
        guard text.count >= 2 else { return }
        let second = text[text.index(after: text.startIndex)]
        guard second == ":", let letter = text.first, letter.isASCIILetter else { return }
        let content = String(stripComment(text).dropFirst(2))
            .trimmingCharacters(in: .whitespaces)
        switch letter {
        case "T": f.title = f.title.map { $0 + "\n" + content } ?? content
        case "C": f.composer = f.composer.map { $0 + "\n" + content } ?? content
        case "M": if let m = parseMeter(content) { f.meter = m }
        case "L": if let l = parseLen(content) { f.noteLen = l }
        case "Q": f.tempo = parseTempo(content)
        case "K":
            if let r = parseKey(content) {
                f.key = r.key
                if let cl = r.clef { f.keyClef = cl }
            }
        case "V":
            let t = content
            let idEnd = t.firstIndex(where: { $0.isWhitespace }) ?? t.endIndex
            let id = String(t[..<idEnd])
            if !id.isEmpty {
                let (nm, cl) = parseVoiceAttrs(String(t[idEnd...]))
                f.voices.append((id: id, name: nm, clef: cl))
            }
        case "P": warnPFile(line.number)
        default: break
        }
    }
}

// MARK: - 曲単位のパース状態

private final class TuneContext {
    struct VState {
        var id: String
        var name: String
        var clef: ABCClef
        var clefSet: Bool
        var keySignature: ABCKeySignature
        var started: Bool = false
        var elements: [ABCElement] = []
        var writtenLen: [Int: ABCFraction] = [:]
        var tupletFactor: [Int: ABCFraction] = [:]
        var lastNote: Int? = nil
        var lyricCursor = 0
    }

    let block: [SrcLine]
    let index: Int
    let total: Int
    unowned let engine: Engine

    var title: String
    var composer: String
    var meter: ABCMeter           // 現在値(本文中の M: で変化)
    var headerMeter: ABCMeter     // ヘッダ時点の値(ABCTune.meter)
    var tempo: ABCTempo
    var headerKey: ABCKeySignature
    var currentKey: ABCKeySignature
    var keyAcc: [Int: Int]
    var noteLen: ABCFraction      // 現在値
    var headerNoteLen: ABCFraction
    var clefFromKey: ABCClef?
    var scoreOrder: [String]?
    var ownTitle = false
    var ownComposer = false

    var voices: [VState] = []
    var voiceIndex: [String: Int] = [:]
    var currentVoice: Int? = nil

    // 次の音符に引き継ぐ保留要素
    var pendingChord: String? = nil
    var pendingDeco: [ABCDecoration] = []
    var pendingSlur = 0
    var pendingGrace: [ABCNote] = []
    var prefixStart: Int? = nil
    var pendingTuplet: (n: Int, factor: ABCFraction, remaining: Int, total: Int)? = nil
    var pendingBroken: ABCFraction? = nil
    var slurOpen = 0
    var slurWarned = false
    var ampWarned = false
    var pWarned = false
    var nextNoteId = 0
    var lastBodyLine = 0

    init(block: [SrcLine], index: Int, total: Int, defaults: HeaderFields, engine: Engine) {
        self.block = block
        self.index = index
        self.total = total
        self.engine = engine
        title = defaults.title ?? ""
        composer = defaults.composer ?? ""
        meter = defaults.meter ?? ABCMeter(num: 4, den: 4)
        headerMeter = meter
        tempo = defaults.tempo ?? ABCTempo()
        headerKey = defaults.key ?? .cMajor
        currentKey = headerKey
        keyAcc = accMap(headerKey)
        noteLen = defaults.noteLen ?? ABCFraction(1, 8)
        headerNoteLen = noteLen
        clefFromKey = defaults.keyClef
        scoreOrder = defaults.scoreOrder
        for v in defaults.voices { makeVoice(id: v.id, name: v.name, clef: v.clef) }
    }

    func report(_ sev: ABCDiagnostic.Severity, _ line: Int, _ msg: String, col: Int = 0) {
        engine.diag(sev, line, col, msg)
    }

    // MARK: 声部管理

    @discardableResult
    func makeVoice(id: String, name: String?, clef: ABCClef?) -> Int {
        voices.append(VState(id: id, name: name ?? id,
                             clef: clef ?? clefFromKey ?? .treble,
                             clefSet: clef != nil,
                             keySignature: currentKey))
        voiceIndex[id] = voices.count - 1
        return voices.count - 1
    }

    func ensureVoice() -> Int {
        if let v = currentVoice { return v }
        if !voices.isEmpty {
            currentVoice = 0
            return 0
        }
        let v = makeVoice(id: "main", name: "メロディー", clef: nil)
        currentVoice = v
        return v
    }

    func markStarted(_ vi: Int) {
        guard !voices[vi].started else { return }
        voices[vi].started = true
        voices[vi].keySignature = currentKey
        if !voices[vi].clefSet { voices[vi].clef = clefFromKey ?? .treble }
    }

    func switchVoice(_ content: String) {
        let t = content.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let idEnd = t.firstIndex(where: { $0.isWhitespace }) ?? t.endIndex
        let id = String(t[..<idEnd])
        if let vi = voiceIndex[id] {
            currentVoice = vi
        } else {
            let (nm, cl) = parseVoiceAttrs(String(t[idEnd...]))
            currentVoice = makeVoice(id: id, name: nm, clef: cl)
        }
    }

    // MARK: 曲パース

    func parse() -> ABCTune {
        var i = 1   // block[0] は X: 行
        while i < block.count {
            let line = block[i]
            let text = line.text
            if text.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            if text.hasPrefix("K:") {
                let content = String(stripComment(text).dropFirst(2))
                if let (k, cl) = parseKey(content) {
                    headerKey = k
                    currentKey = k
                    keyAcc = accMap(k)
                    if let cl = cl { clefFromKey = cl }
                } else {
                    report(.warning, line.number,
                           "K:（調）の値を解釈できません。C として扱います")
                }
                i += 1
                break
            }
            if isFieldLine(text) {
                headerField(line)
                i += 1
                continue
            }
            break   // K: なしで本文開始
        }
        parseBody(ArraySlice(block[i...]))
        finalizeVoices()
        if slurOpen > 0 { warnUnbalanced(lastBodyLine) }

        var ordered = voices
        if let order = scoreOrder {
            var ranked: [VState] = []
            var used = Set<Int>()
            for vid in order {
                if let vi = voiceIndex[vid], !used.contains(vi) {
                    ranked.append(voices[vi])
                    used.insert(vi)
                }
            }
            for (vi, v) in voices.enumerated() where !used.contains(vi) { ranked.append(v) }
            ordered = ranked
        }
        let voiceModels = ordered.map {
            ABCVoice(id: $0.id, name: $0.name, clef: $0.clef,
                     keySignature: $0.keySignature, elements: $0.elements)
        }
        let tune = ABCTune(index: index,
                           source: block.map { $0.text }.joined(separator: "\n"),
                           lineOffset: block[0].number - 1,
                           title: title, composer: composer,
                           meter: headerMeter, tempo: tempo,
                           defaultNoteLength: headerNoteLen,
                           voices: voiceModels)
        if !tune.hasNotes {
            let wh = total > 1 ? "\(index + 1) 曲目 " : ""
            report(.error, block[0].number,
                   "\(wh)音符が見つかりません。K: の後に音符を書いてください")
        }
        return tune
    }

    func finalizeVoices() {
        for vi in voices.indices where !voices[vi].started {
            voices[vi].keySignature = headerKey
            if !voices[vi].clefSet { voices[vi].clef = clefFromKey ?? .treble }
        }
    }

    func isFieldLine(_ text: String) -> Bool {
        if text.hasPrefix("%") { return true }
        guard text.count >= 2 else { return false }
        return text[text.index(after: text.startIndex)] == ":"
            && text.first!.isASCIILetter
    }

    /// チューンヘッダのフィールド行
    func headerField(_ line: SrcLine) {
        let text = line.text
        if text.hasPrefix("%") {
            if text.hasPrefix("%%") { directive(text, line: line.number) }
            return
        }
        guard text.count >= 2,
              text[text.index(after: text.startIndex)] == ":",
              let letter = text.first else { return }
        let content = String(stripComment(text).dropFirst(2))
            .trimmingCharacters(in: .whitespaces)
        switch letter {
        case "T":
            if ownTitle { title += "\n" + content } else { title = content; ownTitle = true }
        case "C":
            if ownComposer { composer += "\n" + content } else { composer = content; ownComposer = true }
        case "M":
            if let m = parseMeter(content) {
                meter = m
                headerMeter = m
            } else {
                report(.warning, line.number, "M:（拍子）の値を解釈できません。4/4 として扱います")
            }
        case "L":
            if let l = parseLen(content) {
                noteLen = l
                headerNoteLen = l
            } else {
                report(.warning, line.number, "L:（基本の音長）の値を解釈できません。1/8 として扱います")
            }
        case "Q":
            tempo = parseTempo(content)
        case "V":
            let t = content
            let idEnd = t.firstIndex(where: { $0.isWhitespace }) ?? t.endIndex
            let id = String(t[..<idEnd])
            if !id.isEmpty, voiceIndex[id] == nil {
                let (nm, cl) = parseVoiceAttrs(String(t[idEnd...]))
                makeVoice(id: id, name: nm, clef: cl)
            }
        case "P":
            warnP(line.number)
        default:
            break   // O,A,Z,B,D,F,G,H,N,R,S,I,U,W,w 等は受理して無視
        }
    }

    /// %% ディレクティブ(ヘッダ/本文共通)
    func directive(_ text: String, line: Int) {
        let body = String(text.dropFirst(2))
        let name = String(body.prefix(while: { !$0.isWhitespace }))
        if name == "score" {
            scoreOrder = scoreVoices(String(body.dropFirst(name.count)))
        } else if !name.isEmpty {
            engine.warnDirective(name, line: line)
        }
    }

    // MARK: 本文

    func parseBody(_ slice: ArraySlice<SrcLine>) {
        let lines = Array(slice)
        var i = 0
        while i < lines.count {
            var L = LogicalLine()
            var consumed = 0
            while true {
                let src = lines[i + consumed]
                var text = src.text.hasPrefix("%") ? src.text : stripComment(src.text)
                while text.last?.isWhitespace == true { text.removeLast() }
                var cont = false
                if text.last == "\\" || text.last == "+" {
                    cont = true
                    text.removeLast()
                }
                appendChars(text, of: src, to: &L)
                consumed += 1
                if !cont || i + consumed >= lines.count { break }
            }
            if let lastChar = L.chars.indices.last {
                lastBodyLine = L.lines[lastChar]
            } else {
                lastBodyLine = lines[i + consumed - 1].number
            }
            dispatch(L)
            i += consumed
        }
    }

    func appendChars(_ text: String, of line: SrcLine, to L: inout LogicalLine) {
        var pos = line.start
        var col = 1
        for ch in text {
            L.chars.append(ch)
            L.offs.append(pos)
            L.lines.append(line.number)
            L.cols.append(col)
            pos += ch.utf8.count
            col += 1
        }
    }

    /// 論理行の種類判定
    func dispatch(_ L: LogicalLine) {
        guard let first = L.chars.first else { return }
        if first == "%" {
            if L.chars.count > 1 && L.chars[1] == "%" {
                directive(String(L.chars), line: L.lines[0])
            }
            return
        }
        if L.chars.count >= 2 && L.chars[1] == ":" && L.chars[0].isASCIILetter {
            bodyField(L)
            return
        }
        music(L)
    }

    /// 本文中のフィールド行(M:/L:/Q:/K:/V:/w: 等)
    func bodyField(_ L: LogicalLine) {
        let letter = L.chars[0]
        let content = String(L.chars[2...]).trimmingCharacters(in: .whitespaces)
        switch letter {
        case "w":
            assignLyrics(ensureVoice(), content)
        case "V":
            switchVoice(content)
        case "M", "L", "Q", "K", "P":
            applyField(letter, content, line: L.lines[0])
        default:
            break   // W:, I: などは無視
        }
    }

    /// インライン/本文フィールドの適用
    func applyField(_ letter: Character, _ content: String, line: Int) {
        switch letter {
        case "M":
            if let m = parseMeter(content) {
                meter = m
                emitField(.meter(m))
            } else {
                report(.warning, line, "M:（拍子）の値を解釈できません。4/4 として扱います")
            }
        case "L":
            if let l = parseLen(content) {
                noteLen = l
                emitField(.noteLength(l))
            } else {
                report(.warning, line, "L:（基本の音長）の値を解釈できません。1/8 として扱います")
            }
        case "Q":
            emitField(.tempo(parseTempo(content)))
        case "K":
            if let (k, cl) = parseKey(content) {
                currentKey = k
                keyAcc = accMap(k)
                emitField(.key(k))
                if let cl = cl {
                    let vi = ensureVoice()
                    voices[vi].clef = cl
                    voices[vi].clefSet = true
                }
            } else {
                report(.warning, line, "K:（調）の値を解釈できません。C として扱います")
            }
        case "P":
            warnP(line)
        case "V":
            switchVoice(content)
        default:
            break
        }
    }

    // MARK: 音符列スキャナ

    func at(_ L: LogicalLine, _ i: Int) -> Character? {
        i >= 0 && i < L.chars.count ? L.chars[i] : nil
    }

    func endOff(_ L: LogicalLine, _ k: Int) -> Int {
        guard k > 0 else { return L.offs.first ?? 0 }
        return L.offs[k - 1] + L.chars[k - 1].utf8.count
    }

    func music(_ L: LogicalLine) {
        var p = 0
        while p < L.chars.count {
            let c = L.chars[p]
            switch c {
            case " ", "\t":
                p += 1
            case "|":
                p = bar(L, p)
            case ":":
                p = colonBar(L, p)
            case "[":
                p = bracket(L, p)
            case "(":
                p = parenTuplet(L, p)
            case ")":
                slurEndNow(L, p)
                p += 1
            case "{":
                p = grace(L, p)
            case "\"":
                p = chordSym(L, p)
            case "!":
                p = bang(L, p)
            case "<", ">":
                p = broken(L, p)
            case "-":
                tieLast()
                p += 1
            case "&":
                warnAmp(L, p)
                p += 1
            case "~":
                pendDeco(.roll, L, p)
                p += 1
            case ".":
                pendDeco(.staccato, L, p)
                p += 1
            case "H":
                pendDeco(.fermata, L, p)
                p += 1
            case "L":
                pendDeco(.accent, L, p)
                p += 1
            case "M":
                pendDeco(.mordent, L, p)
                p += 1
            case "T":
                pendDeco(.trill, L, p)
                p += 1
            case "u":
                pendDeco(.upbow, L, p)
                p += 1
            case "v", "V":
                pendDeco(.downbow, L, p)
                p += 1
            case "S", "O", "P":
                p += 1   // segno / cresc / その他受理して無視
            case "z", "x", "y", "Z":
                p = restNote(L, p)
            case "^", "_", "=":
                p = pitched(L, p)
            default:
                if noteLetterSet.contains(c) {
                    p = pitched(L, p)
                } else {
                    engine.warnUnknownOnce(line: L.lines[p], col: L.cols[p])
                    p += 1
                }
            }
        }
    }

    /// 臨時記号+音名+オクターブ → ABCPitch
    func pitchAt(_ L: LogicalLine, _ p: Int) -> (ABCPitch?, Int) {
        let C = L.chars
        let n = C.count
        var i = p
        var acc: ABCAccidental? = nil
        while i < n && accidentalCharSet.contains(C[i]) {
            switch C[i] {
            case "^": acc = (acc == .sharp) ? .doubleSharp : .sharp
            case "_": acc = (acc == .flat) ? .doubleFlat : .flat
            default: acc = .natural
            }
            i += 1
        }
        guard i < n, noteLetterSet.contains(C[i]) else { return (nil, i) }
        let raw = C[i]
        let upper = Character(raw.uppercased())
        var oct = raw.isUppercase ? 0 : 1
        i += 1
        while i < n && (C[i] == "," || C[i] == "'") {
            oct += (C[i] == ",") ? -1 : 1
            i += 1
        }
        let li = stepOf[upper] ?? 0
        let delta = acc?.semitones ?? (keyAcc[li] ?? 0)
        let midi = 60 + oct * 12 + (semitoneOf[upper] ?? 0) + delta
        return (ABCPitch(step: li + 7 * oct, midi: midi, accidental: acc), i)
    }

    /// 音長修飾子(数字と / の列)
    func lengthModifier(_ L: LogicalLine, _ p: Int) -> (ABCFraction, Int) {
        let C = L.chars
        let n = C.count
        var num = 1, den = 1, i = p
        while i < n {
            if C[i].isASCIIDigit {
                let (v, j) = readInt(L, i)
                num *= v
                i = j
            } else if C[i] == "/" {
                i += 1
                if i < n && C[i].isASCIIDigit {
                    let (v, j) = readInt(L, i)
                    den *= v
                    i = j
                } else {
                    den *= 2
                }
            } else {
                break
            }
        }
        return (ABCFraction(num, den), i)
    }

    func readInt(_ L: LogicalLine, _ p: Int) -> (Int, Int) {
        var i = p, v = 0
        while i < L.chars.count && L.chars[i].isASCIIDigit {
            v = v * 10 + (L.chars[i].wholeNumberValue ?? 0)
            i += 1
        }
        return (v, i)
    }

    /// 音名(臨時記号込み)からの音符
    func pitched(_ L: LogicalLine, _ p: Int) -> Int {
        let (pitch, j) = pitchAt(L, p)
        guard let pitch = pitch else {
            engine.warnUnknownOnce(line: L.lines[p], col: L.cols[p])
            return max(j, p + 1)
        }
        let (mult, k) = lengthModifier(L, j)
        emit(pitches: [pitch], rest: .none, written: noteLen * mult,
             start: L.offs[p], end: endOff(L, k), line: L.lines[p])
        return k
    }

    /// 休符 z/x/y/Z
    func restNote(_ L: LogicalLine, _ p: Int) -> Int {
        let c = L.chars[p]
        if c == "Z" {
            var i = p + 1
            var cnt = 1
            if i < L.chars.count && L.chars[i].isASCIIDigit {
                let (v, j) = readInt(L, i)
                cnt = max(1, v)
                i = j
            }
            emit(pitches: [], rest: .measure, written: ABCFraction(1, 1),
                 start: L.offs[p], end: endOff(L, i), line: L.lines[p],
                 duration: meter.measureLength * cnt, glyph: (.whole, 0))
            return i
        }
        let kind: ABCRestKind = c == "x" ? .invisible : (c == "y" ? .spacer : .normal)
        let (mult, k) = lengthModifier(L, p + 1)
        emit(pitches: [], rest: kind, written: noteLen * mult,
             start: L.offs[p], end: endOff(L, k), line: L.lines[p])
        return k
    }

    /// [ ... ] の分岐(和音/インラインフィールド/括弧番号/小節線)
    func bracket(_ L: LogicalLine, _ p: Int) -> Int {
        let nxt = at(L, p + 1)
        if nxt == "|" { return bar(L, p + 1, bracketed: true) }
        if nxt == ":" { return colonBar(L, p + 1) }
        if let c = nxt, c.isASCIIDigit || c == "," {
            let (e, j) = endingsAt(L, p + 1)
            emitBar(.plain, e, line: L.lines[p])
            return j
        }
        if let c = nxt, c.isASCIILetter, at(L, p + 2) == ":" {
            return inlineField(L, p)
        }
        return chord(L, p)
    }

    func chord(_ L: LogicalLine, _ p: Int) -> Int {
        var i = p + 1
        var pitches: [ABCPitch] = []
        var closed = false
        while i < L.chars.count {
            let c = L.chars[i]
            if c == "]" {
                closed = true
                i += 1
                break
            }
            if accidentalCharSet.contains(c) || noteLetterSet.contains(c) {
                let (pitch, j) = pitchAt(L, i)
                if let pitch = pitch { pitches.append(pitch) }
                i = max(j, i + 1)
            } else {
                i += 1
            }
        }
        if !closed { engine.warnChordOnce(L.lines[p]) }
        let (mult, k) = lengthModifier(L, i)
        emit(pitches: pitches, rest: .none, written: noteLen * mult,
             start: L.offs[p], end: endOff(L, k), line: L.lines[p])
        return k
    }

    /// [X:...] インラインフィールド
    func inlineField(_ L: LogicalLine, _ p: Int) -> Int {
        let letter = L.chars[p + 1]
        var i = p + 3
        var content = ""
        while i < L.chars.count && L.chars[i] != "]" {
            content.append(L.chars[i])
            i += 1
        }
        if i < L.chars.count { i += 1 }
        applyField(letter, content, line: L.lines[p])
        return i
    }

    /// | 系小節線。bracketed = [| のように [ 前置あり
    func bar(_ L: LogicalLine, _ p: Int, bracketed: Bool = false) -> Int {
        var i = p + 1
        var kind: ABCBar.Kind = bracketed ? .double : .plain
        var endings: [Int] = []
        switch at(L, i) {
        case "|":
            kind = .double
            i += 1
        case "]":
            kind = .final
            i += 1
        case ":":
            kind = .repeatStart
            i += 1
        case "[":
            if at(L, i + 1)?.isASCIIDigit == true {
                let (e, j) = endingsAt(L, i + 1)
                endings = e
                i = j
            }
        case let c? where c.isASCIIDigit:
            let (e, j) = endingsAt(L, i)
            endings = e
            i = j
        default:
            break
        }
        emitBar(kind, endings, line: L.lines[p])
        return i
    }

    /// : 系小節線
    func colonBar(_ L: LogicalLine, _ p: Int) -> Int {
        if at(L, p + 1) == "|" && at(L, p + 2) == ":" {
            emitBar(.repeatBoth, [], line: L.lines[p])
            return p + 3
        }
        if at(L, p + 1) == "|" {
            emitBar(.repeatEnd, [], line: L.lines[p])
            var i = p + 2
            // :|1 や :|[1 の括弧番号は直後の小節線要素に付ける
            if at(L, i) == "[", at(L, i + 1)?.isASCIIDigit == true { i += 1 }
            if at(L, i)?.isASCIIDigit == true {
                let (e, j) = endingsAt(L, i)
                emitBar(.plain, e, line: L.lines[p])
                i = j
            }
            return i
        }
        if at(L, p + 1) == ":" {
            emitBar(.repeatBoth, [], line: L.lines[p])
            return p + 2
        }
        emitBar(.plain, [], line: L.lines[p])
        return p + 1
    }

    /// 括弧番号リスト(1 / 1,2 / 1-3、] は任意)
    func endingsAt(_ L: LogicalLine, _ p: Int) -> ([Int], Int) {
        var i = p
        var res: [Int] = []
        while i < L.chars.count {
            let c = L.chars[i]
            if c.isASCIIDigit {
                let (a, j) = readInt(L, i)
                i = j
                if i < L.chars.count && L.chars[i] == "-",
                   at(L, i + 1)?.isASCIIDigit == true {
                    let (b, k) = readInt(L, i + 1)
                    i = k
                    if b >= a { res += a...b } else { res.append(a) }
                } else {
                    res.append(a)
                }
            } else if c == "," {
                i += 1
            } else {
                break
            }
        }
        if i < L.chars.count && L.chars[i] == "]" { i += 1 }
        return (res, i)
    }

    /// ( スラー開始 or (n 連符
    func parenTuplet(_ L: LogicalLine, _ p: Int) -> Int {
        if at(L, p + 1)?.isASCIIDigit == true {
            var i = p + 1
            let (n, j) = readInt(L, i)
            i = j
            var pp: Int? = nil, qq: Int? = nil
            if at(L, i) == ":" {
                i += 1
                if at(L, i)?.isASCIIDigit == true {
                    let (v, j2) = readInt(L, i)
                    pp = v
                    i = j2
                }
                if at(L, i) == ":" {
                    i += 1
                    if at(L, i)?.isASCIIDigit == true {
                        let (v, j2) = readInt(L, i)
                        qq = v
                        i = j2
                    }
                }
            }
            let num = pp ?? tupletDefaultP[n] ?? max(1, n - 1)
            let q = max(1, qq ?? n)
            pendingTuplet = (n: n, factor: ABCFraction(num, max(1, n)),
                             remaining: q, total: q)
            return i
        }
        slurOpen += 1
        pendingSlur += 1
        if prefixStart == nil { prefixStart = L.offs[p] }
        return p + 1
    }

    /// ) スラー終了 → 直前の音符に付く
    func slurEndNow(_ L: LogicalLine, _ p: Int) {
        guard slurOpen > 0 else {
            warnUnbalanced(L.lines[p])
            return
        }
        if let vi = currentVoice, let li = voices[vi].lastNote,
           case .note(var nt) = voices[vi].elements[li] {
            nt.slurEnds += 1
            voices[vi].elements[li] = .note(nt)
        }
        slurOpen -= 1
    }

    /// {...} 前打音
    func grace(_ L: LogicalLine, _ p: Int) -> Int {
        var i = p + 1
        var closed = false
        while i < L.chars.count {
            let c = L.chars[i]
            if c == "}" {
                closed = true
                i += 1
                break
            }
            if accidentalCharSet.contains(c) || noteLetterSet.contains(c) {
                let (pitch, j) = pitchAt(L, i)
                if let pitch = pitch {
                    pendingGrace.append(ABCNote(id: nextNoteId, pitches: [pitch],
                                                rest: .none, glyph: .eighth, dots: 0,
                                                duration: ABCFraction(1, 32),
                                                sourceStart: L.offs[i],
                                                sourceEnd: endOff(L, j),
                                                line: L.lines[i]))
                    nextNoteId += 1
                }
                i = max(j, i + 1)
            } else {
                i += 1
            }
        }
        if !closed { engine.warnGraceOnce(L.lines[p]) }
        if prefixStart == nil { prefixStart = L.offs[p] }
        return i
    }

    /// "..." コード記号/注釈 → 次の音符に付く
    func chordSym(_ L: LogicalLine, _ p: Int) -> Int {
        var i = p + 1
        var s = ""
        while i < L.chars.count && L.chars[i] != "\"" {
            s.append(L.chars[i])
            i += 1
        }
        if i < L.chars.count { i += 1 }
        pendingChord = s
        if prefixStart == nil { prefixStart = L.offs[p] }
        return i
    }

    /// !...! 装飾 / 行末 ! は改行マーカー
    func bang(_ L: LogicalLine, _ p: Int) -> Int {
        var j = p + 1
        while j < L.chars.count && L.chars[j] != "!" { j += 1 }
        guard j < L.chars.count else {
            var i = p + 1
            while i < L.chars.count && !L.chars[i].isWhitespace { i += 1 }
            return i
        }
        let name = String(L.chars[(p + 1)..<j]).lowercased()
        if let d = decoration(named: name) {
            pendingDeco.append(d)
            if prefixStart == nil { prefixStart = L.offs[p] }
        }
        return j + 1
    }

    /// a>b 系 broken rhythm。前の音符を伸ばし/詰め、次の音符に逆を適用
    func broken(_ L: LogicalLine, _ p: Int) -> Int {
        let dir = L.chars[p]
        var k = 0
        while p + k < L.chars.count && L.chars[p + k] == dir { k += 1 }
        let m = min(k, 3)
        let small = ABCFraction(1, 1 << m)
        let big = ABCFraction((1 << (m + 1)) - 1, 1 << m)
        applyBroken(dir == ">" ? big : small)
        pendingBroken = dir == ">" ? small : big
        return p + k
    }

    func applyBroken(_ f: ABCFraction) {
        guard let vi = currentVoice, let li = voices[vi].lastNote,
              case .note(var nt) = voices[vi].elements[li] else { return }
        let w = (voices[vi].writtenLen[li] ?? nt.duration) * f
        voices[vi].writtenLen[li] = w
        let tf = voices[vi].tupletFactor[li] ?? ABCFraction(1, 1)
        nt.duration = w * tf
        let (g, d) = glyphFor(w)
        nt.glyph = g
        nt.dots = d
        voices[vi].elements[li] = .note(nt)
    }

    /// - タイ → 直前の音符に tieStart
    func tieLast() {
        guard let vi = currentVoice, let li = voices[vi].lastNote,
              case .note(var nt) = voices[vi].elements[li] else { return }
        nt.tieStart = true
        voices[vi].elements[li] = .note(nt)
    }

    func pendDeco(_ d: ABCDecoration, _ L: LogicalLine, _ p: Int) {
        pendingDeco.append(d)
        if prefixStart == nil { prefixStart = L.offs[p] }
    }

    // MARK: 要素出力

    func emit(pitches: [ABCPitch], rest: ABCRestKind, written w0: ABCFraction,
              start: Int, end: Int, line: Int,
              duration durOverride: ABCFraction? = nil,
              glyph glyphOverride: (ABCNoteGlyph, Int)? = nil) {
        let vi = ensureVoice()
        markStarted(vi)
        var written = w0
        if let b = pendingBroken {
            written = written * b
            pendingBroken = nil
        }
        let (g, d) = glyphOverride ?? glyphFor(written)
        var duration = durOverride ?? written
        var tf = ABCFraction(1, 1)
        var tuplet: ABCTuplet? = nil
        if var t = pendingTuplet {
            tf = t.factor
            duration = duration * t.factor
            tuplet = ABCTuplet(n: t.n,
                               isFirst: t.remaining == t.total,
                               isLast: t.remaining == 1)
            t.remaining -= 1
            pendingTuplet = t.remaining > 0 ? t : nil
        }
        let note = ABCNote(id: nextNoteId, pitches: pitches, rest: rest,
                           glyph: g, dots: d, duration: duration,
                           slurStarts: pendingSlur,
                           decorations: pendingDeco,
                           chordSymbol: pendingChord,
                           graceNotes: pendingGrace,
                           tuplet: tuplet,
                           sourceStart: prefixStart ?? start,
                           sourceEnd: end, line: line)
        nextNoteId += 1
        pendingChord = nil
        pendingDeco = []
        pendingSlur = 0
        pendingGrace = []
        prefixStart = nil
        let idx = voices[vi].elements.count
        voices[vi].elements.append(.note(note))
        voices[vi].writtenLen[idx] = written
        voices[vi].tupletFactor[idx] = tf
        voices[vi].lastNote = idx
    }

    func emitBar(_ kind: ABCBar.Kind, _ endings: [Int], line: Int) {
        let vi = ensureVoice()
        markStarted(vi)
        voices[vi].elements.append(.bar(ABCBar(kind: kind, endings: endings, line: line)))
    }

    func emitField(_ fc: ABCFieldChange) {
        let vi = ensureVoice()
        markStarted(vi)
        voices[vi].elements.append(.fieldChange(fc))
    }

    // MARK: 歌詞

    enum LTok {
        case syllable(String), bar, skip, extend, hyphen
    }

    func assignLyrics(_ vi: Int, _ content: String) {
        let toks = lyricTokens(content)
        var i = voices[vi].lyricCursor
        let count = voices[vi].elements.count
        var lastAssigned: Int? = nil
        func nextNote(_ from: Int) -> Int? {
            var j = from
            while j < count {
                if case .note = voices[vi].elements[j] { return j }
                j += 1
            }
            return nil
        }
        for t in toks {
            switch t {
            case .bar:
                var j = i
                while j < count {
                    if case .bar = voices[vi].elements[j] { j += 1; break }
                    j += 1
                }
                i = j
            case .skip:
                i = nextNote(i).map { $0 + 1 } ?? count
            case .extend:
                if let li = lastAssigned, case .note(var nt) = voices[vi].elements[li],
                   nt.lyric != nil {
                    nt.lyric?.underscoreAfter = true
                    voices[vi].elements[li] = .note(nt)
                }
            case .hyphen:
                if let li = lastAssigned, case .note(var nt) = voices[vi].elements[li],
                   nt.lyric != nil {
                    nt.lyric?.hyphenAfter = true
                    voices[vi].elements[li] = .note(nt)
                }
            case .syllable(let s):
                guard let j = nextNote(i) else { continue }
                if case .note(var nt) = voices[vi].elements[j] {
                    if !nt.isRest {
                        nt.lyric = ABCLyric(syllable: s, hyphenAfter: false,
                                            underscoreAfter: false)
                        voices[vi].elements[j] = .note(nt)
                        lastAssigned = j
                    }
                    i = j + 1
                }
            }
        }
        voices[vi].lyricCursor = count
    }

    /// w: 行をトークン化(- ハイフン、~ 音節内空白、_ 伸ばし、* 読み飛ばし、| 小節送り)
    func lyricTokens(_ content: String) -> [LTok] {
        var toks: [LTok] = []
        for word in content.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            var firstPart = true
            for part in word.split(separator: "|", omittingEmptySubsequences: false) {
                if !firstPart { toks.append(.bar) }
                firstPart = false
                guard !part.isEmpty else { continue }
                if part == "*" { toks.append(.skip); continue }
                if part == "_" { toks.append(.extend); continue }
                var firstSub = true
                for sub in part.split(separator: "-", omittingEmptySubsequences: false) {
                    if !firstSub { toks.append(.hyphen) }
                    firstSub = false
                    let s = sub.replacingOccurrences(of: "~", with: " ")
                        .replacingOccurrences(of: "*", with: "")
                    if !s.isEmpty { toks.append(.syllable(s)) }
                }
            }
        }
        return toks
    }

    // MARK: 警告(曲内で一度だけ)

    func warnUnbalanced(_ line: Int) {
        guard !slurWarned else { return }
        slurWarned = true
        report(.warning, line, "括弧・装飾の対応が取れていません")
    }
    func warnAmp(_ L: LogicalLine, _ p: Int) {
        guard !ampWarned else { return }
        ampWarned = true
        report(.warning, L.lines[p], "V: の分割(&)は未対応です")
    }
    func warnP(_ line: Int) {
        guard !pWarned else { return }
        pWarned = true
        report(.warning, line, "P:（演奏順）は現在未対応です。譜面どおりに再生します")
    }
}
