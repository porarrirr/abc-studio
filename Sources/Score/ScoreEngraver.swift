import CoreGraphics
import CoreText
import Foundation



// MARK: - Public API

public enum ScoreInk: Sendable { case primary, accent, faint }
public enum ScoreTextAnchor: Sendable { case leading, center, trailing }

public enum EngravedShape {
    case fill(CGPath, ScoreInk)
    case stroke(CGPath, lineWidth: CGFloat, ScoreInk)
    case text(String, size: CGFloat, bold: Bool, rect: CGRect, anchor: ScoreTextAnchor, ink: ScoreInk)
}

/// Maps a note element id to its region: rect = cursor bar area, shapeRange = indices into
/// EngravedScore.shapes that belong to the element (noteheads/rest glyphs) for re-tinting.
public struct CursorTarget {
    public var rect: CGRect
    public var shapeRange: Range<Int>
    public init(rect: CGRect, shapeRange: Range<Int>) {
        self.rect = rect
        self.shapeRange = shapeRange
    }
}

public struct EngravedScore {
    public var size: CGSize
    public var shapes: [EngravedShape]
    public var targets: [Int: CursorTarget]
    public init(size: CGSize, shapes: [EngravedShape], targets: [Int: CursorTarget]) {
        self.size = size
        self.shapes = shapes
        self.targets = targets
    }
}

// MARK: - Shared font helper

private enum ScoreFonts {
    private static var cache: [String: CTFont] = [:]

    static func font(size: CGFloat, bold: Bool) -> CTFont {
        let key = "\(size)|\(bold)"
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

// MARK: - ScoreEngraver

public enum ScoreEngraver {
    /// width = engraving width in points (caller passes max(viewportWidth, 760)).
    public static func engrave(_ tune: ABCTune, width: CGFloat) -> EngravedScore {
        Engine(tune: tune, width: width).run()
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
    var hasChordSymbols: Bool
    var measureHasLyric: [Bool]
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
    var shapeStart: Int
    var shapeEnd: Int
}

private final class Engine {
    let tune: ABCTune
    let width: CGFloat

    // geometry constants (points)
    let s: CGFloat = 9                      // staffSpace
    var staffH: CGFloat { s * 4 }
    var headW: CGFloat { s * 1.16 }
    var headH: CGFloat { s * 0.82 }
    let stemW: CGFloat = 1.15
    let leftPad: CGFloat = 16
    let rightPad: CGFloat = 18
    let topPad: CGFloat = 24
    let bottomPad: CGFloat = 26
    var labelCol: CGFloat { s * 6.8 }       // voice-name column (first system)
    let systemGapY: CGFloat = 38

    var shapes: [EngravedShape] = []
    var targets: [Int: CursorTarget] = [:]

    // per-voice persistent connector state
    private struct TiePend { var step: Int; var x: CGFloat; var cy: CGFloat; var above: Bool }
    private struct SlurPend { var x: CGFloat; var y: CGFloat; var above: Bool }
    private struct HairpinPend { var cresc: Bool; var x: CGFloat }
    private var ties: [[TiePend]] = []
    private var slurs: [[SlurPend]] = []
    private var hairpins: [[HairpinPend]] = []
    var lyricEvents: [(vi: Int, x: CGFloat, y: CGFloat, text: String, hyphen: Bool, extendTo: CGFloat?)] = []
    var contentRight: CGFloat = 0
    var contentBottom: CGFloat = 0

    init(tune: ABCTune, width: CGFloat) {
        self.tune = tune
        self.width = width
    }

    // MARK: clef tables (diatonic bottom-line step, C4 = 0)

    private func bottomStep(_ clef: ABCClef) -> Int {
        switch clef {
        case .treble: return 2      // E4
        case .bass: return -10      // G2
        case .alto: return -4       // F3
        case .tenor: return -6      // D3
        case .percussion: return 2
        }
    }

    private func clefWidth(_ clef: ABCClef) -> CGFloat {
        switch clef {
        case .treble: return s * 2.9
        case .bass: return s * 2.5
        case .alto, .tenor: return s * 2.3
        case .percussion: return s * 2.0
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

        let hasChord = v.elements.contains {
            if case .note(let n) = $0 { return n.chordSymbol != nil && !n.chordSymbol!.isEmpty }
            return false
        }
        var lyricByMeasure = [Bool](repeating: false, count: measures.count)
        for (i, m) in measures.enumerated() {
            lyricByMeasure[i] = m.items.contains {
                if case .note(let n) = $0 { return n.lyric != nil && !n.lyric!.syllable.isEmpty }
                return false
            }
        }
        return VPlan(measures: measures, keyAt: keyAt, meterAt: meterAt,
                     brackets: brackets, hasChordSymbols: hasChord, measureHasLyric: lyricByMeasure)
    }

    // MARK: width estimation

    private func keySigWidth(_ key: ABCKeySignature) -> CGFloat {
        key.isPercussion ? 0 : CGFloat(key.accidentals.count) * s * 0.92 + s * 0.3
    }

    private func slotWidth(_ item: VItem) -> CGFloat {
        switch item {
        case .field(let f):
            switch f {
            case .key(let k): return keySigWidth(k) + s * 1.4
            case .meter: return s * 2.2
            case .tempo(let t):
                var w = ScoreFonts.width("♩= \(tempoString(t))", size: 11, bold: true) + s * 0.8
                if let txt = t.text, !txt.isEmpty { w += ScoreFonts.width(txt, size: 11, bold: true) + 8 }
                return w
            case .noteLength: return 0
            }
        case .note(let n):
            var w = (2.2 + 3.9 * sqrt(max(0.03, n.duration.value))) * s
            w += CGFloat(n.dots) * 0.45 * s
            w += CGFloat(n.graceNotes.count) * 0.85 * s
            let nAcc = n.pitches.filter { $0.accidental != nil }.count
            w += CGFloat(min(2, nAcc)) * 0.85 * s
            if n.rest == .measure { w = max(w, s * 3.4) }
            return max(w, s * 2.3)
        }
    }

    private func measureMinWidth(_ m: VMeasure) -> CGFloat {
        var w: CGFloat = s * 0.9 + s * 1.2   // inner pads
        if m.startBar != nil { w += s * 1.2 }
        for item in m.items { w += slotWidth(item) }
        return max(w, s * 3.0)
    }

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
        var gridW = [CGFloat](repeating: s * 3.0, count: M)
        for p in plans {
            for (i, m) in p.measures.enumerated() {
                gridW[i] = max(gridW[i], measureMinWidth(m))
            }
        }

        // furniture width needed if a system starts at measure boundary b
        func furnitureWidth(_ b: Int) -> CGFloat {
            var w: CGFloat = 0
            for (vi, v) in voices.enumerated() {
                guard plans[vi].measures.indices.contains(b) || b < plans[vi].measures.count else { continue }
                let key = b < plans[vi].keyAt.count ? plans[vi].keyAt[b] : v.keySignature
                var f = clefWidth(v.clef) + s * 0.4
                if !v.isPercussion { f += keySigWidth(key) }
                w = max(w, f)
            }
            return w
        }
        func meterColumn(_ b: Int, firstSystem: Bool) -> CGFloat {
            firstSystem ? s * 2.6 : 0
        }

        // ---- pack measures into systems ----
        struct Sys { var start: Int; var end: Int; var startX: CGFloat; var avail: CGFloat }
        var systems: [Sys] = []
        var m = 0
        var sysIdx = 0
        while m < M {
            let lineStart = leftPad + (sysIdx == 0 ? labelCol : 0)
            let startX = lineStart + furnitureWidth(m) + meterColumn(m, firstSystem: sysIdx == 0) + s * 0.5
            let avail = width - rightPad - startX
            var used: CGFloat = 0
            var e = m
            while e < M {
                let mw = gridW[e]
                if e > m && used + mw > avail { break }
                used += mw
                e += 1
            }
            if e == m { e = m + 1; used = gridW[m] }
            systems.append(Sys(start: m, end: e, startX: startX, avail: avail))
            m = e
            sysIdx += 1
        }

        // ---- emit systems ----
        var y = topPad
        for (si, sys) in systems.enumerated() {
            // stretch measures to fill available width
            var widths = [CGFloat](repeating: 0, count: sys.end - sys.start)
            var total: CGFloat = 0
            for i in sys.start..<sys.end { widths[i - sys.start] = gridW[i]; total += gridW[i] }
            let extra = sys.end > sys.start ? max(0, sys.avail - total) / CGFloat(sys.end - sys.start) : 0
            var mX: [CGFloat] = []
            var cur = sys.startX
            for i in 0..<widths.count {
                widths[i] += extra
                mX.append(cur)
                cur += widths[i]
            }
            let sysRight = cur
            let lineStart = leftPad + (si == 0 ? labelCol : 0)
            contentRight = max(contentRight, sysRight)

            // row heights
            var rowTop: [CGFloat] = []
            var rowBottom: [CGFloat] = []
            var ry = y
            for (vi, _) in voices.enumerated() {
                let plan = plans[vi]
                var topExtra: CGFloat = 0
                if si == 0 && vi == 0 { topExtra += s * 2.4 }                        // tempo
                if plan.brackets.contains(where: { $0.endMeasure >= sys.start && $0.startMeasure < sys.end }) {
                    topExtra += s * 1.9                                            // volta bracket
                }
                if plan.hasChordSymbols { topExtra += s * 1.7 }
                ry += topExtra
                rowTop.append(ry)
                ry += staffH
                rowBottom.append(ry)
                let hasLyric = (sys.start..<sys.end).contains { plan.measureHasLyric.indices.contains($0) ? plan.measureHasLyric[$0] : false }
                ry += (hasLyric ? s * 2.8 : 0)
                ry += staffH * 1.15                                                // gap to next staff
            }
            let sysBottom = ry - staffH * 1.15

            // per-voice rows
            for (vi, v) in voices.enumerated() {
                let plan = plans[vi]
                let st = rowTop[vi]
                let sb = rowBottom[vi]

                // staff lines
                for l in 0..<5 {
                    let ly = st + CGFloat(l) * s
                    let p = CGMutablePath()
                    p.move(to: CGPoint(x: lineStart, y: ly))
                    p.addLine(to: CGPoint(x: sysRight, y: ly))
                    shapes.append(.stroke(p, lineWidth: 1, .primary))
                }

                // voice name (first system)
                if si == 0 {
                    let name = v.name.isEmpty ? v.id : v.name
                    emitText(name, size: 11, bold: false,
                             rect: CGRect(x: leftPad - 6, y: st + staffH / 2 - 7, width: labelCol - 4, height: 14),
                             anchor: .trailing, ink: .primary)
                }

                // furniture: clef + key + meter
                var fx = lineStart
                emitClef(v.clef, x: fx, staffTop: st)
                fx += clefWidth(v.clef)
                if !v.isPercussion {
                    let key = sys.start < plan.keyAt.count ? plan.keyAt[sys.start] : v.keySignature
                    emitKeySig(key, clef: v.clef, x: fx + s * 0.2, staffTop: st)
                    fx += keySigWidth(key) + s * 0.2
                }
                if si == 0 {
                    let meter = sys.start < plan.meterAt.count ? plan.meterAt[sys.start] : tune.meter
                    emitMeter(meter, x: fx + s * 0.5, staffTop: st)
                }

                // tempo on very first system above first staff
                if si == 0 && vi == 0 {
                    emitTempo(tune.tempo, x: sys.startX, y: st - s * 1.7)
                }

                // measures
                var accState: [Int: ABCAccidental] = [:]
                var curKey = sys.start < plan.keyAt.count ? plan.keyAt[sys.start] : v.keySignature
                for mi in sys.start..<sys.end where mi < plan.measures.count {
                    let meas = plan.measures[mi]
                    let mx0 = mX[mi - sys.start]
                    let mx1 = mx0 + widths[mi - sys.start]
                    if let sb2 = meas.startBar { emitBar(sb2, x: mx0, staffTop: st) }
                    emitMeasure(vi: vi, plan: plan, mi: mi, x0: mx0, x1: mx1,
                                staffTop: st, sysIndex: si, accState: &accState, curKey: &curKey)
                    if let eb = meas.endBar {
                        emitBar(eb, x: mx1, staffTop: st)
                    } else if mi == plan.measures.count - 1 {
                        emitBar(ABCBar(kind: .final), x: mx1, staffTop: st)
                    }
                }

                // volta brackets for this row
                for b in plan.brackets where b.endMeasure >= sys.start && b.startMeasure < sys.end {
                    let lo = max(b.startMeasure, sys.start)
                    let hi = min(b.endMeasure, sys.end - 1)
                    guard lo <= hi else { continue }
                    let bx0 = lo == b.startMeasure ? mX[lo - sys.start] : lineStart + 2
                    let bx1 = mX[hi - sys.start] + widths[hi - sys.start]
                    let by = st - s * 1.55
                    let p = CGMutablePath()
                    p.move(to: CGPoint(x: bx0, y: by + s * 0.75))
                    p.addLine(to: CGPoint(x: bx0, y: by))
                    p.addLine(to: CGPoint(x: bx1, y: by))
                    if hi == b.endMeasure {
                        p.move(to: CGPoint(x: bx1, y: by))
                        p.addLine(to: CGPoint(x: bx1, y: by + s * 0.55))
                    }
                    shapes.append(.stroke(p, lineWidth: 1, .primary))
                    if lo == b.startMeasure {
                        emitText(b.label, size: 9.5, bold: false,
                                 rect: CGRect(x: bx0 + 3, y: by + 1.5, width: s * 2.5, height: 11),
                                 anchor: .leading, ink: .primary)
                    }
                }

                contentBottom = max(contentBottom, sb + s * 3)
            }

            y = sysBottom + systemGapY
        }

        // ---- lyrics pass ----
        for ev in lyricEvents {
            emitText(ev.text, size: 10.5, bold: false,
                     rect: CGRect(x: ev.x - headW * 0.4, y: ev.y, width: 200, height: 13),
                     anchor: .leading, ink: .faint)
            let w = ScoreFonts.width(ev.text, size: 10.5, bold: false)
            if ev.hyphen {
                emitText("-", size: 10.5, bold: false,
                         rect: CGRect(x: ev.x + w + 3, y: ev.y, width: 14, height: 13),
                         anchor: .leading, ink: .faint)
            }
            if let ext = ev.extendTo, ext > ev.x + w + 4 {
                let p = CGMutablePath()
                p.move(to: CGPoint(x: ev.x + w + 3, y: ev.y + 9.5))
                p.addLine(to: CGPoint(x: ext - 2, y: ev.y + 9.5))
                shapes.append(.stroke(p, lineWidth: 0.8, .faint))
            }
        }

        return EngravedScore(size: CGSize(width: max(width, contentRight + rightPad),
                                          height: contentBottom + bottomPad),
                             shapes: shapes, targets: targets)
    }

    private func tempoString(_ t: ABCTempo) -> String {
        t.bpm == t.bpm.rounded() ? "\(Int(t.bpm))" : String(format: "%.1f", t.bpm)
    }

    private func emitTempo(_ t: ABCTempo, x: CGFloat, y: CGFloat) {
        var cx = x
        if let txt = t.text, !txt.isEmpty {
            emitText(txt, size: 12, bold: true,
                     rect: CGRect(x: cx, y: y - 8, width: max(20, ScoreFonts.width(txt, size: 12, bold: true) + 4), height: 14),
                     anchor: .leading, ink: .primary)
            cx += ScoreFonts.width(txt, size: 12, bold: true) + 10
        }
        // small quarter-note glyph + "= bpm"
        let hp = noteheadPath(cx: cx + 4, cy: y + 3.4, scale: 0.82)
        shapes.append(.fill(hp, .primary))
        let sp = CGMutablePath()
        sp.addRect(CGRect(x: cx + 7.6, y: y - 15.5, width: 1.05, height: 18.9))
        shapes.append(.fill(sp, .primary))
        emitText("= \(tempoString(t))", size: 11.5, bold: true,
                 rect: CGRect(x: cx + 11, y: y - 7, width: 60, height: 14),
                 anchor: .leading, ink: .primary)
    }

    /// Render a font glyph to a CGPath in authoring coords (y-down), positioned so that
    /// `anchorFrac` (fraction of the glyph bounds' height, from its top) lands at `anchorY`,
    /// and the glyph's left bounds edge lands at `anchorX`. Returns nil if the glyph is missing.
    private func glyphPath(_ scalars: String, fontName: String, size: CGFloat,
                           anchorX: CGFloat, anchorY: CGFloat, anchorFrac: CGFloat) -> CGPath? {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        var utf16 = Array(scalars.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count) else { return nil }
        let raw = CGMutablePath()
        for g in glyphs {
            if let gp = CTFontCreatePathForGlyph(font, g, nil) { raw.addPath(gp) }
        }
        let b = raw.boundingBox
        if b.isNull || b.width == 0 { return nil }
        // glyph space is y-up with origin on the baseline; map to authoring y-down:
        // point (gx, gy) -> (anchorX + gx - b.minX, anchorY - (gy - (b.minY + frac*h)))
        let ty = anchorY + b.minY + (1 - anchorFrac) * b.height
        var t = CGAffineTransform(translationX: anchorX - b.minX, y: ty).scaledBy(x: 1, y: -1)
        return raw.copy(using: &t)
    }

    // MARK: staff furniture

    private func emitClef(_ clef: ABCClef, x: CGFloat, staffTop: CGFloat) {
        let st = staffTop
        switch clef {
        case .treble:
            // real glyph outline from Apple Symbols (U+1D11E), spiral center ~62% of glyph height
            if let p = glyphPath("\u{1D11E}", fontName: "Apple Symbols", size: staffH * 1.42,
                                 anchorX: x + s * 0.15, anchorY: st + s * 3.0, anchorFrac: 0.62) {
                shapes.append(.fill(p, .primary))
                return
            }
            // fallback: stylized G clef
            let cx = x + s * 1.45
            let p = CGMutablePath()
            p.move(to: CGPoint(x: cx - s * 0.30, y: st + s * 4.95))
            p.addCurve(to: CGPoint(x: cx + s * 0.42, y: st + s * 2.9),
                       control1: CGPoint(x: cx - s * 1.05, y: st + s * 4.6),
                       control2: CGPoint(x: cx - s * 1.15, y: st + s * 3.5))
            p.addCurve(to: CGPoint(x: cx + s * 0.30, y: st + s * 0.7),
                       control1: CGPoint(x: cx + s * 1.15, y: st + s * 2.4),
                       control2: CGPoint(x: cx + s * 0.62, y: st + s * 1.55))
            p.addCurve(to: CGPoint(x: cx + s * 0.16, y: st - s * 0.75),
                       control1: CGPoint(x: cx + s * 0.05, y: st + s * 0.0),
                       control2: CGPoint(x: cx + s * 0.2, y: st - s * 0.3))
            p.addCurve(to: CGPoint(x: cx + s * 0.62, y: st - s * 0.05),
                       control1: CGPoint(x: cx + s * 0.1, y: st - s * 1.2),
                       control2: CGPoint(x: cx + s * 0.8, y: st - s * 0.75))
            shapes.append(.stroke(p, lineWidth: 2.1, .primary))
            let loop = CGMutablePath()
            loop.addEllipse(in: CGRect(x: cx - s * 0.78, y: st + s * 2.25,
                                       width: s * 1.62, height: s * 1.55))
            shapes.append(.stroke(loop, lineWidth: 2.0, .primary))
        case .bass:
            // real glyph outline (U+1D122), dot pair centered on F line (2nd from top, ~45% height)
            if let p = glyphPath("\u{1D122}", fontName: "Apple Symbols", size: staffH * 1.15,
                                 anchorX: x + s * 0.1, anchorY: st + s * 1.0, anchorFrac: 0.42) {
                shapes.append(.fill(p, .primary))
                return
            }
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x + s * 0.35, y: st + s * 0.55))
            p.addCurve(to: CGPoint(x: x + s * 0.5, y: st + s * 2.7),
                       control1: CGPoint(x: x + s * 1.85, y: st + s * 0.55),
                       control2: CGPoint(x: x + s * 1.7, y: st + s * 2.25))
            shapes.append(.stroke(p, lineWidth: 2.6, .primary))
            let head = CGMutablePath()
            head.addEllipse(in: CGRect(x: x + s * 0.05, y: st + s * 0.28, width: s * 0.62, height: s * 0.62))
            shapes.append(.fill(head, .primary))
            for dy in [0.5, 1.5] {
                let d = CGMutablePath()
                d.addEllipse(in: CGRect(x: x + s * 1.62, y: st + s * CGFloat(dy) - s * 0.21,
                                        width: s * 0.42, height: s * 0.42))
                shapes.append(.fill(d, .primary))
            }
        case .alto, .tenor:
            // C clef: bracket glyph with a notch whose point sits on the C line
            let cLineY: CGFloat = clef == .alto ? st + s * 2 : st + s * 1
            let x0 = x + s * 0.25
            let x1 = x0 + s * 0.52           // inner edge of vertical bar
            let xt = x0 + s * 1.5            // notch tip x
            let yTop = st - s * 0.3, yBot = st + staffH + s * 0.3
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x0, y: yTop))
            p.addLine(to: CGPoint(x: x1, y: yTop))
            // top arm curving right to the notch tip
            p.addCurve(to: CGPoint(x: xt, y: cLineY),
                       control1: CGPoint(x: x1 + s * 0.85, y: yTop + s * 0.15),
                       control2: CGPoint(x: xt + s * 0.1, y: cLineY - s * 0.95))
            // tip notch back to inner edge
            p.addCurve(to: CGPoint(x: x1 + s * 0.12, y: cLineY),
                       control1: CGPoint(x: xt - s * 0.35, y: cLineY - s * 0.28),
                       control2: CGPoint(x: xt - s * 0.55, y: cLineY))
            // bottom arm mirror
            p.addCurve(to: CGPoint(x: xt, y: cLineY + s * 0.02),
                       control1: CGPoint(x: xt - s * 0.55, y: cLineY),
                       control2: CGPoint(x: xt - s * 0.35, y: cLineY + s * 0.28))
            p.addCurve(to: CGPoint(x: x1, y: yBot),
                       control1: CGPoint(x: xt + s * 0.1, y: cLineY + s * 0.95),
                       control2: CGPoint(x: x1 + s * 0.85, y: yBot - s * 0.15))
            p.addLine(to: CGPoint(x: x0, y: yBot))
            p.closeSubpath()
            shapes.append(.fill(p, .primary))
        case .percussion:
            for i in 0..<2 {
                let r = CGMutablePath()
                r.addRect(CGRect(x: x + s * 0.35 + CGFloat(i) * s * 0.95, y: st,
                                 width: s * 0.52, height: staffH))
                shapes.append(.fill(r, .primary))
            }
        }
    }

    private func emitKeySig(_ key: ABCKeySignature, clef: ABCClef, x: CGFloat, staffTop: CGFloat) {
        let bottom = bottomStep(clef)
        for (i, a) in key.accidentals.enumerated() {
            let p = keyPos(a.letter, a.accidental, clef)
            let cy = staffTop + staffH - CGFloat(p - bottomStepSafe(clef, bottom)) * (s / 2)
            emitAccidentalGlyph(a.accidental, cx: x + CGFloat(i) * s * 0.92 + s * 0.45, cy: cy, size: 19)
        }
    }

    // positions in keyPos tables are already relative to bottom line (offset p)
    private func bottomStepSafe(_ clef: ABCClef, _ bottom: Int) -> Int { bottom }

    private func emitMeter(_ meter: ABCMeter, x: CGFloat, staffTop: CGFloat) {
        let st = staffTop
        switch meter.style {
        case .none:
            break
        case .common:
            emitText("C", size: 21, bold: true,
                     rect: CGRect(x: x, y: st + s * 0.4, width: s * 1.9, height: staffH - s * 0.8),
                     anchor: .center, ink: .primary)
        case .cut:
            emitText("C", size: 21, bold: true,
                     rect: CGRect(x: x, y: st + s * 0.4, width: s * 1.9, height: staffH - s * 0.8),
                     anchor: .center, ink: .primary)
            let p = CGMutablePath()
            p.addRect(CGRect(x: x + s * 0.88, y: st + s * 0.1, width: 1.3, height: staffH - s * 0.2))
            shapes.append(.fill(p, .primary))
        case .fraction(let num, let den):
            emitText("\(num)", size: 19, bold: true,
                     rect: CGRect(x: x, y: st, width: s * 2.0, height: staffH / 2),
                     anchor: .center, ink: .primary)
            emitText("\(den)", size: 19, bold: true,
                     rect: CGRect(x: x, y: st + staffH / 2, width: s * 2.0, height: staffH / 2),
                     anchor: .center, ink: .primary)
        }
    }

    private func emitBar(_ bar: ABCBar, x: CGFloat, staffTop: CGFloat) {
        let st = staffTop
        func vline(_ lx: CGFloat, _ w: CGFloat) {
            let p = CGMutablePath()
            p.addRect(CGRect(x: lx, y: st, width: w, height: staffH))
            shapes.append(.fill(p, .primary))
        }
        func dots(_ dx: CGFloat) {
            for dy in [1, 3] {
                let d = CGMutablePath()
                d.addEllipse(in: CGRect(x: dx - 2.1, y: st + s * CGFloat(dy) - 2.1,
                                        width: 4.2, height: 4.2))
                shapes.append(.fill(d, .primary))
            }
        }
        switch bar.kind {
        case .plain:
            vline(x - 0.5, 1.0)
        case .double:
            vline(x - 3.2, 1.0); vline(x + 1.6, 1.0)
        case .final:
            vline(x - 5.2, 1.0); vline(x - 1.2, 3.4)
        case .repeatStart:
            vline(x - 1.4, 3.2); vline(x + 3.2, 1.0); dots(x + 6.6)
        case .repeatEnd:
            dots(x - 7.6); vline(x - 4.2, 1.0); vline(x - 1.0, 3.2)
        case .repeatBoth:
            dots(x - 7.6); vline(x - 4.2, 1.0); vline(x - 0.8, 3.0)
            vline(x + 3.4, 1.0); dots(x + 6.8)
        }
    }

    // MARK: measure layout & emit

    private func emitMeasure(vi: Int, plan: VPlan, mi: Int, x0: CGFloat, x1: CGFloat,
                             staffTop st: CGFloat, sysIndex si: Int,
                             accState: inout [Int: ABCAccidental], curKey: inout ABCKeySignature) {
        let voice = tune.voices[vi]
        let meas = plan.measures[mi]
        guard !meas.items.isEmpty else { return }
        accMap = [:]

        let perc = voice.isPercussion
        let bottom = bottomStep(voice.clef)

        // ---- pass 1: positions ----
        let itemsW = meas.items.map { slotWidth($0) }
        let padL: CGFloat = s * 0.9, padR: CGFloat = s * 1.3
        let interior = (x0 + padL, x1 - padR)
        let sumW = itemsW.reduce(0, +)
        let scale = max(0.55, min(2.3, (interior.1 - interior.0) / max(sumW, 1)))
        var xs: [CGFloat] = []
        var cur = interior.0
        for i in 0..<itemsW.count { xs.append(cur); cur += itemsW[i] * scale }

        var placed: [PlacedNote?] = Array(repeating: nil, count: meas.items.count)
        var beamOfItem: [Int: Int] = [:]
        var beamGroups: [[Int]] = []
        var curBeam = -1
        var tupletRanges: [(lo: Int, hi: Int, n: Int)] = []
        var tFirst = -1

        // accidental state
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
                    // thin bar + new key signature
                    let p = CGMutablePath()
                    p.addRect(CGRect(x: xs[idx] + s * 0.2, y: st, width: 1, height: staffH))
                    p.addRect(CGRect(x: xs[idx] + s * 0.2 + 3, y: st, width: 1, height: staffH))
                    shapes.append(.fill(p, .primary))
                    emitKeySig(nk, clef: voice.clef, x: xs[idx] + s * 0.9, staffTop: st)
                case .meter(let nm):
                    emitMeter(nm, x: xs[idx] + s * 0.2, staffTop: st)
                case .tempo(let t):
                    emitTempo(t, x: xs[idx], y: st - s * 1.7)
                case .noteLength:
                    break
                }
            case .note(let n):
                if n.rest == .invisible || n.rest == .spacer {
                    let r = CGRect(x: xs[idx] - 1, y: st - 6, width: 10, height: staffH + 12)
                    targets[n.id] = CursorTarget(rect: r, shapeRange: shapes.count..<shapes.count)
                    placed[idx] = PlacedNote(note: n, x: xs[idx] + 4, heads: [], stemUp: true,
                                             stemX: 0, tipY: 0, restCenterX: xs[idx] + 4,
                                             topCy: 0, botCy: 0, shapeStart: shapes.count, shapeEnd: shapes.count)
                    continue
                }

                // beam group tracking
                if n.beamStart { curBeam += 1; beamGroups.append([]) }
                if curBeam >= 0 { beamOfItem[idx] = curBeam; beamGroups[curBeam].append(idx) }

                // tuplet tracking
                if let tp = n.tuplet {
                    if tp.isFirst { tFirst = idx }
                    if tp.isLast && tFirst >= 0 { tupletRanges.append((tFirst, idx, tp.n)); tFirst = -1 }
                }

                if n.isRest {
                    let restX = xs[idx] + itemsW[idx] * scale / 2
                    placed[idx] = PlacedNote(note: n, x: restX, heads: [], stemUp: true,
                                             stemX: restX, tipY: 0, restCenterX: restX,
                                             topCy: 0, botCy: 0, shapeStart: 0, shapeEnd: 0)
                    if n.beamEnd { curBeam = -1 }
                    continue
                }

                // note pitch positions
                var heads: [HeadPos] = []
                var accs: [(x: CGFloat, cy: CGFloat, acc: ABCAccidental)] = []
                let sorted = n.pitches.sorted { $0.step < $1.step }
                var accW: CGFloat = 0
                for pitch in sorted {
                    let pPos: Int
                    var xHead = false
                    if perc {
                        let dm = drumPos(pitch.midi)
                        pPos = dm.p; xHead = dm.x
                    } else {
                        pPos = pitch.step - bottom
                    }
                    let cy = st + staffH - CGFloat(pPos) * s / 2
                    // accidental?
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
                accW = accs.isEmpty ? 0 : (CGFloat(min(accs.count, 2)) * s * 0.85 + s * 0.25)
                let graceW = CGFloat(n.graceNotes.count) * s * 0.8
                let headX = xs[idx] + accW + graceW + headW / 2

                // stem direction: farthest-from-middle rule
                let maxP = heads.map { $0.p }.max() ?? 4
                let minP = heads.map { $0.p }.min() ?? 4
                let stemUp = (4 - minP) >= (maxP - 4)
                // seconds offset: the higher note of a second stays on the stem side
                // (right for stem-up, left for stem-down); the other head moves aside.
                for hi in 0..<heads.count { heads[hi].x = headX }
                for hi in 1..<heads.count {
                    if heads[hi].p - heads[hi - 1].p == 1 {
                        if stemUp { heads[hi - 1].x = headX - headW * 1.02 }
                        else { heads[hi].x = headX - headW * 1.02 }
                    }
                }
                for (ai, _) in accs.enumerated() {
                    accs[ai].x = headX - headW * 0.75 - CGFloat(ai) * s * 0.8 - s * 0.35
                }

                let stemX = stemUp ? headX + headW / 2 - stemW * 0.45 : headX - headW / 2 + stemW * 0.45
                let topCy = heads.map { $0.cy }.min() ?? 0
                let botCy = heads.map { $0.cy }.max() ?? 0
                var tipY: CGFloat
                if stemUp {
                    tipY = min(topCy - s * 3.5, st + s * 1.4)
                } else {
                    tipY = max(botCy + s * 3.5, st + s * 2.6)
                }
                if n.glyph == .whole { tipY = 0 }

                placed[idx] = PlacedNote(note: n, x: headX, heads: heads, stemUp: stemUp,
                                         stemX: stemX, tipY: tipY, restCenterX: 0,
                                         topCy: topCy, botCy: botCy, shapeStart: 0, shapeEnd: 0)
                // stash accidentals for emit via a side table
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
            guard pairs.count >= 2, !notes.isEmpty else { continue }
            // majority direction over pitched members
            var upVotes = 0
            for (_, pn) in notes {
                let maxP = pn.heads.map { $0.p }.max() ?? 4
                let minP = pn.heads.map { $0.p }.min() ?? 4
                if (4 - minP) >= (maxP - 4) { upVotes += 1 } else { upVotes -= 1 }
            }
            let stemUp = upVotes >= 0
            let fx = pairs.first!.1.stemX
            let lx = pairs.last!.1.stemX
            guard lx > fx else { continue }
            // required tip per pitched member
            func reqTip(_ pn: PlacedNote) -> CGFloat {
                stemUp ? pn.topCy - s * 3.0 : pn.botCy + s * 3.0
            }
            // slope follows pitch contour, clamped
            let first = notes.first!.1, last = notes.last!.1
            let firstRef = stemUp ? first.topCy : first.botCy
            let lastRef = stemUp ? last.topCy : last.botCy
            var slope = (lastRef - firstRef) * 0.4
            slope = max(-s * 0.9, min(s * 0.9, slope))
            var beamAtFirst: CGFloat
            if stemUp {
                beamAtFirst = .greatestFiniteMagnitude
                for (_, pn) in notes {
                    let want = reqTip(pn) - slope * (pn.stemX - fx) / (lx - fx)
                    beamAtFirst = min(beamAtFirst, want)
                }
            } else {
                beamAtFirst = -.greatestFiniteMagnitude
                for (_, pn) in notes {
                    let want = reqTip(pn) - slope * (pn.stemX - fx) / (lx - fx)
                    beamAtFirst = max(beamAtFirst, want)
                }
            }
            beamGeo[bi] = BeamGeo(yAtX0: beamAtFirst,
                                  yAtX1: beamAtFirst + slope,
                                  x0: fx, x1: lx, stemUp: stemUp)
            // store adjusted tips
            for (m, _) in pairs {
                var pn = placed[m]!
                let px = pn.stemX
                pn.tipY = beamAtFirst + slope * (px - fx) / (lx - fx)
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
                emitRest(n, x: pn.restCenterX, staffTop: st, measX0: x0, measX1: x1,
                         meter: plan.meterAt[mi])
                pnShapeRange(idx: idx, n: n, pn: pn, s0: s0, staffTop: st)
                continue
            }

            // accidentals
            for a in accMap[idx] ?? [] {
                emitAccidentalGlyph(a.acc, cx: a.x, cy: a.cy, size: 18)
            }

            // grace notes
            if !n.graceNotes.isEmpty {
                emitGrace(n.graceNotes, beforeX: pn.x - headW * 0.55, staffTop: st, bottom: bottom, perc: perc)
            }

            // stems
            let stemmed = n.glyph != .whole
            if stemmed {
                if pn.stemUp {
                    let p = CGMutablePath()
                    let top = beamOfItem[idx].flatMap { beamGeo[$0] } != nil ? pn.tipY + s * 0.5 : pn.tipY
                    p.addRect(CGRect(x: pn.stemX - stemW / 2, y: top, width: stemW,
                                     height: pn.topCy - s * 0.15 - top))
                    shapes.append(.fill(p, .primary))
                } else {
                    let p = CGMutablePath()
                    let bot = beamOfItem[idx].flatMap { beamGeo[$0] } != nil ? pn.tipY - s * 0.5 : pn.tipY
                    p.addRect(CGRect(x: pn.stemX - stemW / 2, y: pn.botCy + s * 0.15,
                                     width: stemW, height: bot - pn.botCy - s * 0.15))
                    shapes.append(.fill(p, .primary))
                }
            }

            // flags for un-beamed notes
            if beamOfItem[idx] == nil && n.glyph.flagCount > 0 {
                emitFlag(x: pn.stemX + stemW / 2, tipY: pn.tipY, stemUp: pn.stemUp,
                         count: n.glyph.flagCount)
            }

            // noteheads (cursor-tracked range)
            let s0 = shapes.count
            let filled = n.glyph != .whole && n.glyph != .half
            for h in pn.heads {
                if h.xHead {
                    let p = CGMutablePath()
                    let hw = headW * 0.42, hh = headH * 0.62
                    p.move(to: CGPoint(x: h.x - hw, y: h.cy - hh)); p.addLine(to: CGPoint(x: h.x + hw, y: h.cy + hh))
                    p.move(to: CGPoint(x: h.x - hw, y: h.cy + hh)); p.addLine(to: CGPoint(x: h.x + hw, y: h.cy - hh))
                    shapes.append(.stroke(p, lineWidth: 1.7, .primary))
                } else {
                    let hp = noteheadPath(cx: h.x, cy: h.cy, scale: 1)
                    if filled { shapes.append(.fill(hp, .primary)) }
                    else { shapes.append(.stroke(hp, lineWidth: 1.3, .primary)) }
                }
                // ledger lines
                if h.p < 0 {
                    var lp = -2
                    while lp >= h.p {
                        emitLedger(x: h.x, cy: st + staffH - CGFloat(lp) * s / 2)
                        lp -= 2
                    }
                } else if h.p > 8 {
                    var lp = 10
                    while lp <= h.p {
                        emitLedger(x: h.x, cy: st + staffH - CGFloat(lp) * s / 2)
                        lp += 2
                    }
                }
            }
            // augmentation dots
            if n.dots > 0 {
                let rightX = pn.heads.map { $0.x }.max()! + headW * 0.62 + 2
                for (di, h) in pn.heads.enumerated() {
                    for d in 0..<n.dots {
                        var dy = h.cy
                        if h.p % 2 == 0 { dy -= s * 0.5 }   // on a line -> dot on space above
                        let dp = CGMutablePath()
                        dp.addEllipse(in: CGRect(x: rightX + CGFloat(d) * s * 0.55 + CGFloat(di) * 0,
                                                 y: dy - 1.6, width: 3.2, height: 3.2))
                        shapes.append(.fill(dp, .primary))
                    }
                }
            }
            pnShapeRange(idx: idx, n: n, pn: pn, s0: s0, staffTop: st)

            // chord symbol
            if let cs = n.chordSymbol, !cs.isEmpty {
                emitText(cs, size: 11.5, bold: true,
                         rect: CGRect(x: pn.x - 30, y: st - s * 1.75, width: 60, height: 13),
                         anchor: .center, ink: .primary)
            }

            // lyric collect
            if let ly = n.lyric, !ly.syllable.isEmpty {
                var ext: CGFloat? = nil
                if ly.underscoreAfter {
                    ext = lyricExtendTarget(items: meas.items, placed: placed, from: idx, x1: x1)
                }
                lyricEvents.append((vi: vi, x: pn.x, y: st + staffH + s * 1.5,
                                    text: ly.syllable, hyphen: ly.hyphenAfter, extendTo: ext))
            }

        }

        // beams on top of stems
        for (bi, _) in beamGroups.enumerated() {
            guard let g = beamGeo[bi] else { continue }
            let members = beamGroups[bi]
            let beamThick = s * 0.48
            let dir: CGFloat = g.stemUp ? 1 : -1
            let p = CGMutablePath()
            p.move(to: CGPoint(x: g.x0 - stemW * 0.5, y: g.yAtX0))
            p.addLine(to: CGPoint(x: g.x1 + stemW * 0.5, y: g.yAtX1))
            p.addLine(to: CGPoint(x: g.x1 + stemW * 0.5, y: g.yAtX1 + beamThick * dir))
            p.addLine(to: CGPoint(x: g.x0 - stemW * 0.5, y: g.yAtX0 + beamThick * dir))
            p.closeSubpath()
            shapes.append(.fill(p, .primary))
            // secondary beams
            for lvl in 2...4 {
                var runStart: Int? = nil
                func yAt(_ x: CGFloat) -> CGFloat {
                    g.yAtX0 + (g.yAtX1 - g.yAtX0) * (x - g.x0) / (g.x1 - g.x0)
                }
                for (mi2, itemIdx) in members.enumerated() {
                    let pn = placed[itemIdx]!
                    let needs = pn.note.glyph.flagCount >= lvl
                    if needs && runStart == nil { runStart = mi2 }
                    if (!needs || mi2 == members.count - 1), runStart != nil {
                        let runEnd = needs ? mi2 : mi2 - 1
                        let sx0 = placed[members[runStart!]]!.stemX - stemW * 0.5
                        let sx1 = placed[members[runEnd]]!.stemX + stemW * 0.5
                        let off = beamThick * dir + CGFloat(lvl - 1) * s * 0.72 * dir
                        let bp = CGMutablePath()
                        bp.move(to: CGPoint(x: sx0, y: yAt(sx0) + off))
                        bp.addLine(to: CGPoint(x: sx1, y: yAt(sx1) + off))
                        bp.addLine(to: CGPoint(x: sx1, y: yAt(sx1) + off + beamThick * 0.88 * dir))
                        bp.addLine(to: CGPoint(x: sx0, y: yAt(sx0) + off + beamThick * 0.88 * dir))
                        bp.closeSubpath()
                        shapes.append(.fill(bp, .primary))
                        runStart = nil
                    }
                }
            }
        }

        // decorations / tuplets / ties / slurs per measure
        for (idx, item) in meas.items.enumerated() {
            guard case .note(let n) = item, let pn = placed[idx] else { continue }
            emitDecorations(n, pn: pn, staffTop: st, vi: vi)
            // ties
            if !n.isRest {
                // resolve pending ties whose target is in this note
                var remaining: [TiePend] = []
                for tp in ties[vi] {
                    if let h = pn.heads.first(where: { $0.p == tp.step }) {
                        emitArc(x0: tp.x, y0: tp.cy, x1: h.x - headW * 0.5, y1: h.cy,
                                above: tp.above, thin: true)
                    } else {
                        remaining.append(tp)
                    }
                }
                ties[vi] = remaining
                if n.tieStart {
                    for h in pn.heads {
                        ties[vi].append(TiePend(step: h.p, x: h.x + headW * 0.55,
                                                cy: h.cy, above: !pn.stemUp))
                    }
                }
                // slurs
                for _ in 0..<n.slurEnds {
                    if !slurs[vi].isEmpty {
                        let sp = slurs[vi].removeFirst()
                        emitArc(x0: sp.x, y0: sp.y, x1: pn.x, y1: pn.stemUp ? pn.botCy + s * 0.9 : pn.topCy - s * 0.9,
                                above: sp.above, thin: false)
                    }
                }
                for _ in 0..<n.slurStarts {
                    let above = !pn.stemUp
                    slurs[vi].append(SlurPend(x: pn.x,
                                              y: above ? pn.topCy - s * 0.9 : pn.botCy + s * 0.9,
                                              above: above))
                }
            }
        }
        // tuplets
        for tr in tupletRanges {
            let lo = tr.lo, hi = tr.hi
            guard let a = placed[lo], let b = placed[hi] else { continue }
            let above = !a.stemUp
            let midX = (a.x + b.x) / 2
            let ty = above ? min(a.topCy, b.topCy) - s * 1.9 : max(a.botCy, b.botCy) + s * 1.2
            emitText("\(tr.n)", size: 10, bold: false,
                     rect: CGRect(x: midX - 10, y: ty, width: 20, height: 12),
                     anchor: .center, ink: .primary)
        }
    }

    private var accMap: [Int: [(x: CGFloat, cy: CGFloat, acc: ABCAccidental)]] = [:]

    private func lyricExtendTarget(items: [VItem], placed: [PlacedNote?], from idx: Int, x1: CGFloat) -> CGFloat {
        for j in (idx + 1)..<items.count {
            if case .note = items[j], let pj = placed[j] { return pj.x }
        }
        return x1 - s
    }

    private func pnShapeRange(idx: Int, n: ABCNote, pn: PlacedNote, s0: Int, staffTop st: CGFloat) {
        let rect = CGRect(x: pn.x - 1, y: st - 6, width: 9, height: staffH + 12)
        targets[n.id] = CursorTarget(rect: rect, shapeRange: s0..<shapes.count)
    }

    private func emitLedger(x: CGFloat, cy: CGFloat) {
        let p = CGMutablePath()
        p.addRect(CGRect(x: x - headW * 0.75, y: cy - 0.5, width: headW * 1.5, height: 1))
        shapes.append(.fill(p, .primary))
    }

    // MARK: glyphs

    private func noteheadPath(cx: CGFloat, cy: CGFloat, scale: CGFloat) -> CGPath {
        var t = CGAffineTransform(translationX: cx, y: cy).rotated(by: -20 * .pi / 180)
            .scaledBy(x: scale, y: scale)
        return CGPath(ellipseIn: CGRect(x: -headW / 2, y: -headH / 2, width: headW, height: headH),
                      transform: &t)
    }

    private func emitAccidentalGlyph(_ acc: ABCAccidental, cx: CGFloat, cy: CGFloat, size: CGFloat) {
        switch acc {
        case .sharp:
            emitText("\u{266F}", size: size, bold: false,
                     rect: CGRect(x: cx - s * 0.55, y: cy - s * 1.25, width: s * 1.1, height: s * 2.5),
                     anchor: .center, ink: .primary)
        case .flat:
            emitText("\u{266D}", size: size, bold: false,
                     rect: CGRect(x: cx - s * 0.55, y: cy - s * 1.35, width: s * 1.1, height: s * 2.5),
                     anchor: .center, ink: .primary)
        case .natural:
            emitText("\u{266E}", size: size, bold: false,
                     rect: CGRect(x: cx - s * 0.55, y: cy - s * 1.2, width: s * 1.1, height: s * 2.4),
                     anchor: .center, ink: .primary)
        case .doubleSharp:
            emitText("x", size: size * 0.8, bold: true,
                     rect: CGRect(x: cx - s * 0.5, y: cy - s * 0.55, width: s, height: s * 1.1),
                     anchor: .center, ink: .primary)
        case .doubleFlat:
            emitText("\u{266D}\u{266D}", size: size * 0.85, bold: false,
                     rect: CGRect(x: cx - s * 0.9, y: cy - s * 1.35, width: s * 1.8, height: s * 2.5),
                     anchor: .center, ink: .primary)
        }
    }

    private func emitRest(_ n: ABCNote, x: CGFloat, staffTop st: CGFloat,
                          measX0: CGFloat, measX1: CGFloat, meter: ABCMeter) {
        let cx = n.rest == .measure ? (measX0 + measX1) / 2 : x
        switch n.glyph {
        case .whole:
            let p = CGMutablePath()
            p.addRect(CGRect(x: cx - s * 0.55, y: st + s * 1.0, width: s * 1.1, height: s * 0.48))
            shapes.append(.fill(p, .primary))
            if n.rest == .measure {
                let count = (n.duration / meter.measureLength).value
                if count > 1.01 {
                    emitText("\(Int(count.rounded()))", size: 10.5, bold: true,
                             rect: CGRect(x: cx - 15, y: st - s * 1.7, width: 30, height: 12),
                             anchor: .center, ink: .primary)
                }
            }
        case .half:
            let p = CGMutablePath()
            p.addRect(CGRect(x: cx - s * 0.55, y: st + s * 2 - s * 0.48, width: s * 1.1, height: s * 0.48))
            shapes.append(.fill(p, .primary))
        case .quarter:
            // real quarter-rest outline (U+1D13D) if available, else stylized squiggle
            if let gp = glyphPath("\u{1D13D}", fontName: "Apple Symbols", size: staffH * 0.92,
                                  anchorX: cx - s * 0.55, anchorY: st + s * 2.0, anchorFrac: 0.5) {
                shapes.append(.fill(gp, .primary))
                break
            }
            let p = CGMutablePath()
            p.move(to: CGPoint(x: cx - s * 0.42, y: st + s * 0.9))
            p.addCurve(to: CGPoint(x: cx + s * 0.42, y: st + s * 1.35),
                       control1: CGPoint(x: cx + s * 0.05, y: st + s * 0.75),
                       control2: CGPoint(x: cx + s * 0.5, y: st + s * 0.95))
            p.addCurve(to: CGPoint(x: cx - s * 0.5, y: st + s * 2.05),
                       control1: CGPoint(x: cx + s * 0.28, y: st + s * 1.7),
                       control2: CGPoint(x: cx - s * 0.55, y: st + s * 1.6))
            p.addCurve(to: CGPoint(x: cx + s * 0.5, y: st + s * 2.7),
                       control1: CGPoint(x: cx - s * 0.4, y: st + s * 2.45),
                       control2: CGPoint(x: cx + s * 0.5, y: st + s * 2.3))
            p.addCurve(to: CGPoint(x: cx - s * 0.1, y: st + s * 3.6),
                       control1: CGPoint(x: cx + s * 0.48, y: st + s * 3.0),
                       control2: CGPoint(x: cx - s * 0.45, y: st + s * 3.0))
            shapes.append(.stroke(p, lineWidth: 1.7, .primary))
        case .eighth, .sixteenth, .thirtySecond, .sixtyFourth:
            // dot + slanted stem + flags
            let d = CGMutablePath()
            d.addEllipse(in: CGRect(x: cx - s * 0.62, y: st + s * 1.35, width: s * 0.42, height: s * 0.42))
            shapes.append(.fill(d, .primary))
            let p = CGMutablePath()
            p.move(to: CGPoint(x: cx + s * 0.15, y: st + s * 0.85))
            p.addCurve(to: CGPoint(x: cx - s * 0.25, y: st + s * 2.5),
                       control1: CGPoint(x: cx - s * 0.1, y: st + s * 1.4),
                       control2: CGPoint(x: cx - s * 0.2, y: st + s * 2.0))
            p.addCurve(to: CGPoint(x: cx + s * 0.55, y: st + s * 3.1),
                       control1: CGPoint(x: cx - s * 0.3, y: st + s * 2.95),
                       control2: CGPoint(x: cx + s * 0.25, y: st + s * 3.0))
            shapes.append(.stroke(p, lineWidth: 1.5, .primary))
            // extra flags for 16th+
            for f in 1..<n.glyph.flagCount {
                let fy = st + s * (2.0 - CGFloat(f) * 0.55)
                let fp = CGMutablePath()
                fp.move(to: CGPoint(x: cx - s * 0.15, y: fy + s * 0.9))
                fp.addCurve(to: CGPoint(x: cx + s * 0.5, y: fy + s * 0.4),
                            control1: CGPoint(x: cx + s * 0.2, y: fy + s * 0.95),
                            control2: CGPoint(x: cx + s * 0.45, y: fy + s * 0.75))
                shapes.append(.stroke(fp, lineWidth: 1.4, .primary))
            }
        }
        // dots
        if n.dots > 0 {
            for d in 0..<n.dots {
                let dp = CGMutablePath()
                dp.addEllipse(in: CGRect(x: cx + s * 0.65 + CGFloat(d) * s * 0.5,
                                         y: st + s * 1.9, width: 3.2, height: 3.2))
                shapes.append(.fill(dp, .primary))
            }
        }
    }

    private func emitFlag(x: CGFloat, tipY: CGFloat, stemUp: Bool, count: Int) {
        for i in 0..<count {
            let shrink = CGFloat(i) * s * 0.16
            if stemUp {
                let fy = tipY + CGFloat(i) * s * 0.75
                let p = CGMutablePath()
                p.move(to: CGPoint(x: x, y: fy))
                p.addCurve(to: CGPoint(x: x + s * 0.95 - shrink, y: fy + s * 1.45),
                           control1: CGPoint(x: x + s * 0.5, y: fy + s * 0.25),
                           control2: CGPoint(x: x + s * 1.05 - shrink, y: fy + s * 0.7))
                p.addCurve(to: CGPoint(x: x, y: fy + s * 0.8),
                           control1: CGPoint(x: x + s * 0.6 - shrink, y: fy + s * 1.15),
                           control2: CGPoint(x: x + s * 0.2, y: fy + s * 0.95))
                p.closeSubpath()
                shapes.append(.fill(p, .primary))
            } else {
                // down-stem flag: hook extends right and curls up
                let fy = tipY - CGFloat(i) * s * 0.75
                let p = CGMutablePath()
                p.move(to: CGPoint(x: x, y: fy))
                p.addCurve(to: CGPoint(x: x + s * 0.95 - shrink, y: fy + s * 0.9),
                           control1: CGPoint(x: x + s * 0.4, y: fy + s * 0.1),
                           control2: CGPoint(x: x + s * 0.95 - shrink, y: fy + s * 0.35))
                p.addCurve(to: CGPoint(x: x + s * 0.25, y: fy + s * 0.75),
                           control1: CGPoint(x: x + s * 0.75 - shrink, y: fy + s * 0.75),
                           control2: CGPoint(x: x + s * 0.45, y: fy + s * 0.85))
                p.closeSubpath()
                shapes.append(.fill(p, .primary))
            }
        }
    }

    private func emitGrace(_ graces: [ABCNote], beforeX: CGFloat, staffTop st: CGFloat,
                           bottom: Int, perc: Bool) {
        let sc: CGFloat = 0.62
        var gx = beforeX - CGFloat(graces.count) * s * 0.8 + s * 0.15
        var stemXs: [CGFloat] = []
        for g in graces {
            for pitch in g.pitches {
                let pPos = perc ? drumPos(pitch.midi).p : pitch.step - bottom
                let cy = st + staffH - CGFloat(pPos) * s / 2
                let hp = noteheadPath(cx: gx, cy: cy, scale: sc)
                shapes.append(.fill(hp, .primary))
            }
            let topP = g.pitches.map { perc ? drumPos($0.midi).p : $0.step - bottom }.max() ?? 8
            let topCy = st + staffH - CGFloat(topP) * s / 2
            let sx = gx + headW * sc * 0.45
            stemXs.append(sx)
            let sp = CGMutablePath()
            sp.addRect(CGRect(x: sx - 0.55, y: topCy - s * 2.4 * sc - s * 0.9,
                              width: 1.1, height: s * 2.4 * sc + s * 0.9))
            shapes.append(.fill(sp, .primary))
            // acciaccatura slash
            let sl = CGMutablePath()
            sl.move(to: CGPoint(x: sx - s * 0.45, y: topCy - s * 1.15))
            sl.addLine(to: CGPoint(x: sx + s * 0.45, y: topCy - s * 1.85))
            shapes.append(.stroke(sl, lineWidth: 1.1, .primary))
            gx += s * 0.8
        }
        if stemXs.count >= 2 {
            let p = CGMutablePath()
            let y0 = (st + staffH - CGFloat(graces.map { $0.pitches.map { perc ? drumPos($0.midi).p : $0.step - bottom }.max() ?? 8 }.max() ?? 8) * s / 2) - s * 2.4 * sc - s * 0.9
            p.move(to: CGPoint(x: stemXs.first! - 0.5, y: y0))
            p.addLine(to: CGPoint(x: stemXs.last! + 0.5, y: y0))
            p.addLine(to: CGPoint(x: stemXs.last! + 0.5, y: y0 + s * 0.42))
            p.addLine(to: CGPoint(x: stemXs.first! - 0.5, y: y0 + s * 0.42))
            p.closeSubpath()
            shapes.append(.fill(p, .primary))
        }
    }

    private func emitDecorations(_ n: ABCNote, pn: PlacedNote, staffTop st: CGFloat, vi: Int) {
        if n.isRest || pn.heads.isEmpty { return }
        for d in n.decorations {
            switch d {
            case .staccato:
                let y = pn.stemUp ? pn.botCy + s * 1.05 : pn.topCy - s * 1.05
                let p = CGMutablePath()
                p.addEllipse(in: CGRect(x: pn.x - 1.7, y: y - 1.7, width: 3.4, height: 3.4))
                shapes.append(.fill(p, .primary))
            case .accent:
                let y = pn.stemUp ? pn.botCy + s * 1.25 : pn.topCy - s * 1.25
                let p = CGMutablePath()
                p.move(to: CGPoint(x: pn.x - s * 0.5, y: y - s * 0.3))
                p.addLine(to: CGPoint(x: pn.x + s * 0.5, y: y))
                p.addLine(to: CGPoint(x: pn.x - s * 0.5, y: y + s * 0.3))
                shapes.append(.stroke(p, lineWidth: 1.5, .primary))
            case .tenuto:
                let y = pn.stemUp ? pn.botCy + s * 1.0 : pn.topCy - s * 1.0
                let p = CGMutablePath()
                p.addRect(CGRect(x: pn.x - s * 0.42, y: y - 0.8, width: s * 0.84, height: 1.6))
                shapes.append(.fill(p, .primary))
            case .fermata:
                let y = min(pn.topCy - s * 1.7, st - s * 0.9)
                let p = CGMutablePath()
                // dome with inner scallop
                p.move(to: CGPoint(x: pn.x - s * 0.72, y: y))
                p.addQuadCurve(to: CGPoint(x: pn.x + s * 0.72, y: y),
                               control: CGPoint(x: pn.x, y: y - s * 1.5))
                p.addQuadCurve(to: CGPoint(x: pn.x - s * 0.72, y: y),
                               control: CGPoint(x: pn.x, y: y - s * 0.42))
                shapes.append(.fill(p, .primary))
                let dp = CGMutablePath()
                dp.addEllipse(in: CGRect(x: pn.x - 2.0, y: y - s * 0.52, width: 4.0, height: 4.0))
                shapes.append(.fill(dp, .primary))
            case .trill:
                emitText("tr", size: 11, bold: false,
                         rect: CGRect(x: pn.x - 12, y: min(pn.topCy - s * 1.9, st - s * 1.1), width: 24, height: 12),
                         anchor: .center, ink: .primary)
            case .upbow:
                let y = min(pn.topCy - s * 1.5, st - s * 0.7)
                let p = CGMutablePath()
                p.move(to: CGPoint(x: pn.x - s * 0.3, y: y + s * 0.35))
                p.addLine(to: CGPoint(x: pn.x, y: y - s * 0.3))
                p.addLine(to: CGPoint(x: pn.x + s * 0.3, y: y + s * 0.35))
                shapes.append(.stroke(p, lineWidth: 1.3, .primary))
            case .downbow:
                let y = min(pn.topCy - s * 1.5, st - s * 0.7)
                let p = CGMutablePath()
                p.move(to: CGPoint(x: pn.x - s * 0.35, y: y - s * 0.3))
                p.addLine(to: CGPoint(x: pn.x - s * 0.35, y: y + s * 0.2))
                p.addLine(to: CGPoint(x: pn.x + s * 0.35, y: y + s * 0.2))
                p.addLine(to: CGPoint(x: pn.x + s * 0.35, y: y - s * 0.3))
                shapes.append(.stroke(p, lineWidth: 1.3, .primary))
            case .breath:
                emitText(",", size: 15, bold: true,
                         rect: CGRect(x: pn.x + s * 0.6, y: pn.topCy - s * 2.2, width: 10, height: 14),
                         anchor: .center, ink: .primary)
            case .dynamic(_, let label):
                emitText(label, size: 12, bold: true,
                         rect: CGRect(x: pn.x - 25, y: st + staffH + s * 1.15, width: 50, height: 13),
                         anchor: .center, ink: .primary)
            case .crescendoStart:
                hairpins[vi].append(HairpinPend(cresc: true, x: pn.x))
            case .crescendoEnd, .diminuendoEnd:
                if let hp = hairpins[vi].last {
                    var isCrescEnd = false
                    if case .crescendoEnd = d { isCrescEnd = true }
                    if isCrescEnd == hp.cresc {
                        hairpins[vi].removeLast()
                        emitHairpin(cresc: hp.cresc, x0: hp.x, x1: pn.x, y: st + staffH + s * 1.6)
                    }
                }
            case .diminuendoStart:
                hairpins[vi].append(HairpinPend(cresc: false, x: pn.x))
            default:
                break
            }
        }
    }

    private func emitHairpin(cresc: Bool, x0: CGFloat, x1: CGFloat, y: CGFloat) {
        guard x1 > x0 + s else { return }
        let p = CGMutablePath()
        if cresc {
            p.move(to: CGPoint(x: x0, y: y))
            p.addLine(to: CGPoint(x: x1, y: y - s * 0.4))
            p.move(to: CGPoint(x: x0, y: y))
            p.addLine(to: CGPoint(x: x1, y: y + s * 0.4))
        } else {
            p.move(to: CGPoint(x: x0, y: y - s * 0.4))
            p.addLine(to: CGPoint(x: x0, y: y + s * 0.4))
            p.move(to: CGPoint(x: x0, y: y - s * 0.4))
            p.addLine(to: CGPoint(x: x1, y: y))
            p.move(to: CGPoint(x: x0, y: y + s * 0.4))
            p.addLine(to: CGPoint(x: x1, y: y))
        }
        shapes.append(.stroke(p, lineWidth: 1, .primary))
    }

    private func emitArc(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, above: Bool, thin: Bool) {
        guard x1 - x0 > s * 0.5 else { return }
        let midX = (x0 + x1) / 2
        let span = x1 - x0
        let h = min(s * 0.7 + span * 0.06, s * 1.8) * (above ? -1 : 1)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0, y: y0))
        p.addQuadCurve(to: CGPoint(x: x1, y: y1),
                       control: CGPoint(x: midX, y: (y0 + y1) / 2 + h * 1.7))
        shapes.append(.stroke(p, lineWidth: thin ? 1.2 : 1.6, .primary))
    }

    private func emitText(_ str: String, size: CGFloat, bold: Bool, rect: CGRect,
                          anchor: ScoreTextAnchor, ink: ScoreInk) {
        shapes.append(.text(str, size: size, bold: bold, rect: rect, anchor: anchor, ink: ink))
    }

    // MARK: percussion map

    private func drumPos(_ midi: Int) -> (p: Int, x: Bool) {
        switch midi {
        case 35, 36: return (-3, false)          // kick
        case 38, 40, 37: return (5, false)       // snare / clap / side stick
        case 42, 44: return (9, true)            // closed/pedal hat
        case 46: return (9, true)                // open hat
        case 41: return (1, false)               // low floor tom
        case 43: return (2, false)               // high floor tom
        case 45: return (4, false)               // low tom
        case 47: return (6, false)               // mid tom
        case 48, 50: return (7, false)           // high toms
        case 49, 55: return (11, true)           // crash / splash
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

    private static func color(_ ink: ScoreInk) -> CGColor {
        if let c = colorCache[ink] { return c }
        let c: CGColor
        switch ink {
        case .primary: c = CGColor(red: 0x20 / 255, green: 0x3c / 255, blue: 0x3d / 255, alpha: 1)
        case .accent: c = CGColor(red: 0xe9 / 255, green: 0xa2 / 255, blue: 0x43 / 255, alpha: 1)
        case .faint: c = CGColor(red: 0x9a / 255, green: 0xab / 255, blue: 0xa6 / 255, alpha: 1)
        }
        colorCache[ink] = c
        return c
    }

    /// Replays an EngravedScore into a CGContext.
    /// The context must be in plain Quartz orientation (origin bottom-left, y-up);
    /// callers with a y-down context should flip before calling.
    public static func draw(_ score: EngravedScore, in ctx: CGContext,
                            highlight: Set<Int>, cursorID: Int?) {
        // shape-index -> accent override for highlighted elements
        var accentShapes: Set<Int> = []
        for id in highlight {
            if let t = score.targets[id] {
                for i in t.shapeRange { accentShapes.insert(i) }
            }
        }

        ctx.saveGState()
        ctx.translateBy(x: 0, y: score.size.height)
        ctx.scaleBy(x: 1, y: -1)

        // playback cursor bar under the notation
        if let cid = cursorID, let t = score.targets[cid] {
            let r = t.rect
            let path = CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)
            ctx.setFillColor(color(.accent).copy(alpha: 0.30)!)
            ctx.addPath(path)
            ctx.fillPath()
        }

        for (i, shape) in score.shapes.enumerated() {
            switch shape {
            case .fill(let path, let ink):
                ctx.setFillColor(color(accentShapes.contains(i) ? .accent : ink))
                ctx.addPath(path)
                ctx.fillPath()
            case .stroke(let path, let lw, let ink):
                ctx.setStrokeColor(color(accentShapes.contains(i) ? .accent : ink))
                ctx.setLineWidth(lw)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.addPath(path)
                ctx.strokePath()
            case .text(let str, let size, let bold, let rect, let anchor, let ink):
                let col = color(accentShapes.contains(i) ? .accent : ink)
                let font = ScoreFonts.font(size: size, bold: bold)
                let attrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): col
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
        ctx.restoreGState()
    }
}
