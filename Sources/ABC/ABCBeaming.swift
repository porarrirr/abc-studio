import Foundation

/// パース済みモデルに自動ビーム(beamStart/beamEnd)を付与する。
/// ルール: 八分音符以下(flagCount>=1)の連続する音符を、ABCMeter.beamUnit の区切りを
/// またがない範囲・同一小節内でグループ化する。休符・四分以上の音符はビームを切断する。
public enum ABCBeaming {
    public static func apply(to book: ABCBook) -> ABCBook {
        var tunes = book.tunes
        for i in tunes.indices {
            var voices = tunes[i].voices
            let meter = tunes[i].meter
            for j in voices.indices {
                voices[j].elements = beam(voices[j].elements, meter: meter)
            }
            tunes[i].voices = voices
        }
        return ABCBook(tunes: tunes, diagnostics: book.diagnostics)
    }

    private static func beam(_ elements: [ABCElement], meter: ABCMeter) -> [ABCElement] {
        var result = elements
        var unit = meter.beamUnit
        var measurePos = ABCFraction(0, 1)   // 小節内の位置(全音符=1)
        var unitPos = ABCFraction(0, 1)      // ビーム単位内の位置
        var group: [Int] = []                // 現在のビーム候補インデックス

        func closeGroup() {
            if group.count >= 2, let first = group.first, let last = group.last {
                if case .note(var n) = result[first] { n.beamStart = true; result[first] = .note(n) }
                if case .note(var n) = result[last] { n.beamEnd = true; result[last] = .note(n) }
            }
            group.removeAll()
        }

        for (i, element) in elements.enumerated() {
            switch element {
            case .bar:
                closeGroup()
                measurePos = ABCFraction(0, 1)
                unitPos = ABCFraction(0, 1)
            case .fieldChange(let change):
                closeGroup()
                if case .meter(let m) = change {
                    unit = m.beamUnit
                    measurePos = ABCFraction(0, 1)
                    unitPos = ABCFraction(0, 1)
                }
            case .note(let note):
                let candidate = !note.isRest && note.glyph.flagCount >= 1
                // ABC では空白がビームを切断する
                if note.spaceBefore { closeGroup() }
                // ビーム単位の区切りをまたぐ音符はグループに入れない
                let crosses = candidate && !unitPos.isZero && (unitPos + note.duration) > unit
                if !candidate || crosses { closeGroup() }
                if candidate && !crosses { group.append(i) }
                measurePos = measurePos + note.duration
                unitPos = unitPos + note.duration
                while unitPos >= unit { unitPos = unitPos - unit }
            }
        }
        closeGroup()
        return result
    }
}
