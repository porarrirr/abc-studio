import SwiftUI

/// Engraving cache so that cursor/highlight ticks do not re-run layout.
private final class ScoreMemo {
    var key: String = ""
    var score: EngravedScore = EngravedScore(size: .zero, shapes: [], targets: [:])
}

/// Renders an ABCTune as native notation inside a 2-axis scroll view,
/// with playback highlighting and an auto-scrolling cursor bar.
public struct ScoreView: View {
    public let tune: ABCTune
    public let highlight: Set<Int>
    public let cursorID: Int?

    @State private var memo = ScoreMemo()

    public init(tune: ABCTune, highlight: Set<Int>, cursorID: Int?) {
        self.tune = tune
        self.highlight = highlight
        self.cursorID = cursorID
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

    private func engravedScore(for width: CGFloat) -> EngravedScore {
        // Cheap cache key: source text + tune index + width.
        let key = "\(tune.index)#\(tune.source.count)#\(tune.voices.count)#\(Int(width))"
        if memo.key == key { return memo.score }
        let s = ScoreEngraver.engrave(tune, width: width)
        memo.key = key
        memo.score = s
        return s
    }
}
