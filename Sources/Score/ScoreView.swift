import SwiftUI

/// Engraving cache so that cursor/highlight ticks do not re-run layout.
private final class ScoreMemo {
    var key: String = ""
    var score = EngravedScore(size: .zero, shapes: [], targets: [:])
    /// レイアウトが変わるたびに増える(段ビューの再描画判定・追従のやり直しに使う)
    var version = 0
}

/// 譜面ビュー。ビューポート幅に合わせて段組みし、段(システム)ごとのビューを
/// LazyVStack に並べて縦スクロールする。
///
/// 自動追従: 再生中にカーソルが次の段へ移ると、その段が画面上端に来るよう
/// スクロールする(読み進める先が常に下に見える)。再生中に指でスクロールすると
/// 追従を一時停止し、「再生位置へ戻る」で再開する。追従の ON/OFF とズームは
/// 呼び出し側(譜面ヘッダー)が持つ。
public struct ScoreView: View {
    public let tune: ABCTune
    public let highlight: Set<Int>
    public let cursorID: Int?
    public let isPlaying: Bool
    @Binding public var zoom: Double
    public let followEnabled: Bool
    public var onTapNote: ((Int) -> Void)?

    @State private var memo = ScoreMemo()
    @State private var followSuspended = false
    /// ピンチ中の見た目だけの拡大率(指を離したら zoom に確定して組み直す)
    @State private var pinchScale: CGFloat = 1

    public static let minZoom = 0.6
    public static let maxZoom = 2.0

    public init(tune: ABCTune, highlight: Set<Int>, cursorID: Int?, isPlaying: Bool,
                zoom: Binding<Double>, followEnabled: Bool, onTapNote: ((Int) -> Void)? = nil) {
        self.tune = tune
        self.highlight = highlight
        self.cursorID = cursorID
        self.isPlaying = isPlaying
        self._zoom = zoom
        self.followEnabled = followEnabled
        self.onTapNote = onTapNote
    }

    public var body: some View {
        GeometryReader { geo in
            let score = engravedScore(for: geo.size.width)
            let version = memo.version
            let active = activeSystem(in: score)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(score.systems.indices, id: \.self) { i in
                            SystemRow(score: score, index: i, version: version,
                                      highlight: rowHighlight(i, in: score),
                                      cursorID: active == i ? cursorID : nil)
                                .equatable()
                                .contentShape(Rectangle())
                                .onTapGesture { p in tap(at: p, system: i, in: score) }
                                .id(i)
                        }
                    }
                    .scaleEffect(pinchScale, anchor: .top)
                }
                .modifier(UserScrollObserver { if isPlaying && followEnabled { followSuspended = true } })
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in
                            pinchScale = clampZoom(zoom * v.magnification) / zoom
                        }
                        .onEnded { v in
                            zoom = clampZoom(zoom * v.magnification)
                            pinchScale = 1
                        }
                )
                .onChange(of: active) { _, new in
                    if isPlaying { follow(to: new, proxy: proxy) }
                }
                .onChange(of: isPlaying) { _, playing in
                    if playing {
                        followSuspended = false
                        follow(to: active, proxy: proxy)
                    }
                }
                .onChange(of: cursorID == nil) { _, stopped in
                    if stopped { followSuspended = false }
                }
                .onChange(of: version) { _, _ in
                    // ズーム・回転・曲変更で段組みが変わったら現在の段を追い直す
                    if isPlaying { follow(to: active, proxy: proxy, animated: false) }
                }
                .onChange(of: followEnabled) { _, on in
                    followSuspended = false
                    if on && isPlaying { follow(to: active, proxy: proxy) }
                }
                .overlay(alignment: .bottom) {
                    if followSuspended && isPlaying && followEnabled {
                        resumeButton { follow(to: active, proxy: proxy) }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: followSuspended)
            }
        }
        .background(Color.white)
        .accessibilityIdentifier("scoreView")
    }

    // MARK: - 追従

    private func activeSystem(in score: EngravedScore) -> Int? {
        cursorID.flatMap { score.targets[$0]?.system }
    }

    private func follow(to system: Int?, proxy: ScrollViewProxy, animated: Bool = true) {
        guard followEnabled, !followSuspended, let system else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(system, anchor: .top) }
        } else {
            proxy.scrollTo(system, anchor: .top)
        }
    }

    private func resumeButton(_ action: @escaping () -> Void) -> some View {
        Button {
            followSuspended = false
            action()
        } label: {
            Label("再生位置へ戻る", systemImage: "location.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color(red: 0.086, green: 0.494, blue: 0.451))
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .padding(.bottom, 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - タップでシーク

    private func tap(at p: CGPoint, system i: Int, in score: EngravedScore) {
        guard let onTapNote, score.systems.indices.contains(i) else { return }
        let global = CGPoint(x: p.x, y: p.y + score.systems[i].band.minY)
        if let id = score.target(near: global, in: i) { onTapNote(id) }
    }

    // MARK: - レイアウト(メモ化)

    private func clampZoom(_ z: Double) -> Double { min(Self.maxZoom, max(Self.minZoom, z)) }

    private func rowHighlight(_ i: Int, in score: EngravedScore) -> Set<Int> {
        highlight.filter { score.targets[$0]?.system == i }
    }

    private func engravedScore(for viewWidth: CGFloat) -> EngravedScore {
        let w = max(viewWidth, 160)
        let z = clampZoom(zoom)
        let key = "\(tune.index)#\(tune.source.hashValue)#\(Int(w))#\(Int((z * 100).rounded()))"
        if memo.key == key { return memo.score }
        // レイアウト幅を 1/z にしてから z 倍 → 表示幅は常に viewWidth
        memo.score = ScoreEngraver.engrave(tune, width: w / z).scaled(by: z)
        memo.key = key
        memo.version += 1
        return memo.score
    }
}

/// 1 段ぶんの描画。ハイライト・カーソルが変わった段だけ再描画する。
private struct SystemRow: View, Equatable {
    let score: EngravedScore
    let index: Int
    let version: Int
    let highlight: Set<Int>
    let cursorID: Int?

    static func == (a: SystemRow, b: SystemRow) -> Bool {
        a.index == b.index && a.version == b.version
            && a.highlight == b.highlight && a.cursorID == b.cursorID
    }

    var body: some View {
        let band = score.systems[index].band
        Canvas { gc, _ in
            gc.withCGContext { cg in
                ScorePainter.drawYDown(score, in: cg, highlight: highlight,
                                       cursorID: cursorID, system: index)
            }
        }
        .frame(width: band.width, height: band.height)
    }
}

/// 指によるスクロール操作を検知する(プログラムからの scrollTo では発火しない)。
private struct UserScrollObserver: ViewModifier {
    let onUserScroll: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                if phase == .interacting { onUserScroll() }
            }
        } else {
            // iOS 17 にはスクロール操作の検知 API がないため、追従の一時停止は行わない
            content
        }
    }
}
