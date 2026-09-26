import SwiftUI

/// Engraving cache so that cursor/highlight ticks do not re-run layout.
private final class ScoreMemo {
    /// 簡易キー(サイズ系)。ヒット時はさらに sourceText も照合する。
    var key: String = ""
    var sourceText: String = ""
    var score: EngravedScore = EngravedScore(size: .zero, shapes: [], targets: [:])
}

/// Renders an ABCTune as native notation inside a 2-axis scroll view,
/// with playback highlighting, an auto-scrolling cursor bar and tap-to-seek.
public struct ScoreView: View {
    public let tune: ABCTune
    public let highlight: Set<Int>
    public let cursorID: Int?
    /// 音符をタップしたときに呼ばれる(要素ID)。nil なら無効。
    public var onTapNote: ((Int) -> Void)?

    @State private var memo = ScoreMemo()

    public init(tune: ABCTune, highlight: Set<Int>, cursorID: Int?,
                onTapNote: ((Int) -> Void)? = nil) {
        self.tune = tune
        self.highlight = highlight
        self.cursorID = cursorID
        self.onTapNote = onTapNote
    }

    public var body: some View {
        GeometryReader { geo in
            let score = engravedScore(for: max(geo.size.width, 760))
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        Canvas { gc, _ in
                            gc.withCGContext { cg in
                                // Canvas hands over a y-down (SwiftUI-oriented) context;
                                // ScorePainter expects plain Quartz orientation, so flip first.
                                cg.translateBy(x: 0, y: score.size.height)
                                cg.scaleBy(x: 1, y: -1)
                                ScorePainter.draw(score, in: cg,
                                                  highlight: highlight, cursorID: cursorID)
                            }
                        }
                        .frame(width: score.size.width, height: score.size.height)

                        // invisible anchor at the active cursor target for scrollTo
                        if let cid = cursorID, let t = score.targets[cid] {
                            Color.clear
                                .frame(width: max(t.rect.width, 20),
                                       height: max(t.rect.height, 48))
                                .position(x: t.rect.midX, y: t.rect.midY)
                                .id(Self.cursorAnchorID)
                        }
                    }
                    .frame(width: score.size.width, height: score.size.height,
                           alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { point in
                        tapNote(at: point, in: score)
                    }
                }
                .onChange(of: cursorID) { _, _ in
                    guard cursorID != nil else { return }
                    withAnimation(.linear(duration: 0.12)) {
                        proxy.scrollTo(Self.cursorAnchorID, anchor: .center)
                    }
                }
            }
        }
        .background(Color(red: 0.97, green: 0.97, blue: 0.95))
    }

    private static let cursorAnchorID = -999_999

    /// タップ位置に最も近い音符ターゲットを探して通知する。
    /// カーソル領域は細長いので、x 方向に少し広げて判定する。
    private func tapNote(at point: CGPoint, in score: EngravedScore) {
        guard let onTapNote else { return }
        var best: (id: Int, dist: CGFloat)?
        for (id, target) in score.targets {
            let r = target.rect.insetBy(dx: -14, dy: -8)
            guard r.contains(point) else { continue }
            let d = abs(r.midX - point.x) + abs(r.midY - point.y) * 0.25
            if best == nil || d < best!.dist { best = (id, d) }
        }
        if let hit = best { onTapNote(hit.id) }
    }

    private func engravedScore(for width: CGFloat) -> EngravedScore {
        // Cheap cache key: source text + tune index + width.
        // 同じ長さのテキストに編集した場合でも更新されるよう、
        // キーが一致しても本文そのものを照合する。
        let key = "\(tune.index)#\(tune.source.count)#\(tune.voices.count)#\(Int(width))"
        if memo.key == key, memo.sourceText == tune.source { return memo.score }
        let s = ScoreEngraver.engrave(tune, width: width)
        memo.key = key
        memo.sourceText = tune.source
        memo.score = s
        return s
    }
}
