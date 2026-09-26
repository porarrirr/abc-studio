import Combine
import Foundation

/// アプリ全体の状態。ABCソースのパース・音色割当・再生をまとめる。
final class StudioModel: ObservableObject {
    @Published var source: String = ""
    @Published var sourceName: String = ""
    @Published var book: ABCBook?
    @Published var selectedTune = 0
    @Published var diagnostics: [ABCDiagnostic] = []
    /// voiceID → Instrument.id
    @Published var assignments: [String: String] = [:]
    @Published var highlight: Set<Int> = []
    @Published var cursorID: Int?
    @Published var toastText: String?
    @Published var status = "準備完了"
    /// 再生速度(%)75-150
    @Published var speed = 100
    @Published var showImporter = false
    @Published var importError: String?
    /// ソースエディタへのジャンプ要求(行番号)。処理後 nil に戻す。
    @Published var jumpToLine: Int?

    let engine = PlaybackEngine()
    /// 初回起動時の例題(app.js の EXAMPLE と同一)
    static let example = """
X:1
T:小さなアンサンブル
C:ABC Studio
M:4/4
L:1/4
Q:1/4=104
%%score melody harmony bass
V:melody clef=treble name="Violin"
V:harmony clef=treble name="Piano"
V:bass clef=bass name="Bass"
K:C
[V:melody] E F G c | B A G2 | A G F E | D4 |
[V:harmony] [CEG]2 [DFA]2 | [EGc]2 [CEG]2 | [FAc]2 [CEG]2 | [B,DG]4 |
[V:bass] C,2 G,2 | E,2 C,2 | F,2 C,2 | G,4 |
"""
    private var lintTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var sequence: PlaybackSequence?
    private var engineObserver: AnyCancellable?

    var tune: ABCTune? {
        guard let book, book.tunes.indices.contains(selectedTune) else { return nil }
        return book.tunes[selectedTune]
    }

    var title: String { tune?.title ?? "楽譜をひらこう。" }
    var subtitle: String {
        guard let tune else { return "ABC 記譜法を読み込み、好きな楽器で再生できます。" }
        let count = tune.voices.count
        let tunes = book.map { $0.tunes.count } ?? 0
        let part = tunes > 1 ? " · \(selectedTune + 1)/\(tunes) 曲" : ""
        return (sourceName.isEmpty ? "" : sourceName + " · ") + "\(count) パート" + part
    }

    init() {
        engineObserver = engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        engine.onCursor = { [weak self] ids, anchor in
            self?.highlight = ids
            self?.cursorID = anchor
        }
        engine.onFinish = { [weak self] in
            guard let self else { return }
            self.highlight = []
            self.cursorID = nil
            self.status = "再生完了"
        }
    }

    // MARK: - 読み込み

    func restore() {
        guard let abc = UserDefaults.standard.string(forKey: "lastABC") else {
            loadABC(Self.example, filename: "", persist: false)
            return
        }
        loadABC(abc, filename: UserDefaults.standard.string(forKey: "lastFilename") ?? "", persist: false)
    }

    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let abc = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16) else {
                throw ImportFailure.unsupportedEncoding
            }
            loadABC(abc, filename: url.lastPathComponent)
        } catch {
            importError = error.localizedDescription
        }
    }

    /// エディタ内容を楽譜に反映
    func applySource() {
        loadABC(source, filename: sourceName)
    }

    func loadABC(_ abc: String, filename: String, persist: Bool = true) {
        let normalized = abc.replacingOccurrences(of: "\r\n?", with: "\n", options: .regularExpression)
        guard normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            toast("ABC の内容が空です"); return
        }
        source = normalized
        sourceName = filename
        var parsed = ABCParser.parse(normalized)
        parsed = ABCBeaming.apply(to: parsed)
        book = parsed
        diagnostics = (parsed.diagnostics + ABCDiagnostics.validate(normalized))
            .sorted { ($0.line, $0.severity == .error ? 0 : 1) < ($1.line, $1.severity == .error ? 0 : 1) }
        engine.stop()
        highlight = []
        cursorID = nil
        guard !parsed.tunes.isEmpty else {
            status = "読み込みエラー"
            toast(diagnostics.first(where: { $0.severity == .error })?.message ?? "ABC を確認してください")
            return
        }
        selectTune(0)
        if diagnostics.contains(where: { $0.severity == .warning }) {
            status = "読み込み完了（警告あり）"
            toast("警告があります。「ABCを編集」タブで確認できます")
        }
        if persist {
            UserDefaults.standard.set(normalized, forKey: "lastABC")
            UserDefaults.standard.set(filename, forKey: "lastFilename")
        }
    }

    func selectTune(_ index: Int) {
        guard let book, book.tunes.indices.contains(index) else { return }
        selectedTune = index
        let tune = book.tunes[index]
        var next: [String: String] = [:]
        for v in tune.voices {
            next[v.id] = assignments[v.id] ?? Instruments.guess(forPartName: v.name).id
        }
        assignments = next
        rebuildSequence()
    }

    // MARK: - 再生

    private func rebuildSequence() {
        guard let tune else { return }
        engine.stop()
        sequence = ABCSequencer.sequence(tune)
        var map: [String: Instrument] = [:]
        for v in tune.voices {
            map[v.id] = Instruments.byID(assignments[v.id] ?? "") ?? Instruments.all[0]
        }
        engine.load(sequence!, instruments: map)
    }

    func assign(_ voiceID: String, instrument: String) {
        assignments[voiceID] = instrument
        rebuildSequence()
        toast("次の再生から音色を変更します")
    }

    func togglePlay() {
        guard tune != nil else { toast("楽譜を読み込んでください"); return }
        if engine.isPlaying {
            engine.pause()
            status = "一時停止"
        } else {
            engine.play()
            status = "再生中"
        }
    }

    func stopPlayback() {
        engine.stop()
        highlight = []
        cursorID = nil
        status = "停止"
    }

    func seek(to fraction: Double) {
        engine.seek(toFraction: fraction)
    }

    func setSpeed(_ percent: Int) {
        speed = percent
        engine.setSpeed(percent)
        status = "速度変更済み"
    }

    // MARK: - 診断・エディタ

    /// エディタ入力時の遅延バリデーション
    func scheduleValidation() {
        lintTask?.cancel()
        lintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run { self.validateSource() }
        }
    }

    func validateSource() {
        let parsed = ABCParser.parse(source)
        diagnostics = (parsed.diagnostics + ABCDiagnostics.validate(source))
            .sorted { ($0.line, $0.severity == .error ? 0 : 1) < ($1.line, $1.severity == .error ? 0 : 1) }
    }

    func jump(to diagnostic: ABCDiagnostic) {
        guard diagnostic.line > 0 else { return }
        jumpToLine = diagnostic.line
    }

    var diagnosticSummary: String {
        let errors = diagnostics.filter { $0.severity == .error }.count
        return "エラー \(errors) 件 · 警告 \(diagnostics.count - errors) 件（タップで該当行へ）"
    }

    func diagnosticText() -> String {
        diagnostics.map { d in
            let head = "\(d.severity == .error ? "エラー" : "警告")\(d.line > 0 ? " \(d.line) 行目" : "")\(d.column > 0 ? " \(d.column) 文字目" : ""): \(d.message)"
            return d.context.isEmpty ? head : head + "\n    > " + d.context
        }.joined(separator: "\n")
    }

    // MARK: - ユーティリティ

    func toast(_ message: String) {
        toastText = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.toastText = nil }
        }
    }

    var currentTimeText: String { Self.format(engine.progress * displayDuration) }
    var totalTimeText: String { Self.format(displayDuration) }
    /// 速度を反映した表示用の総時間
    var displayDuration: Double { engine.duration * 100.0 / Double(speed) }

    private static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    private enum ImportFailure: LocalizedError {
        case unsupportedEncoding
        var errorDescription: String? { "この ABC ファイルの文字コードを読み込めません。UTF-8 または UTF-16 で保存してください。" }
    }
}
