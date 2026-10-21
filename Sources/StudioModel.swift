import Combine
import Foundation

/// The complete document preparation stage has no UIKit or model mutations.
/// It is shared by initial restore, file/sample/library opens and draft apply.
enum StudioDocumentPreparation {
    private final class Entry {
        let document: Document
        init(_ document: Document) { self.document = document }
    }
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 3
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    struct Tune {
        let sequence: PlaybackSequence
        let instruments: [String: String]
    }

    struct Document {
        let source: String
        let book: ABCBook
        let diagnostics: [ABCDiagnostic]
        let firstTune: Tune?
    }

    static func tune(_ tune: ABCTune) -> Tune {
        let instruments = Dictionary(uniqueKeysWithValues: tune.voices.map { voice in
            (voice.id, Instruments.namedInstrument(forPartName: voice.name)?.id
                ?? (voice.isPercussion ? "drums" : "piano"))
        })
        return Tune(sequence: ABCSequencer.sequence(tune), instruments: instruments)
    }

    static func document(_ abc: String) -> Document? {
        let key = abc as NSString
        if let entry = cache.object(forKey: key) { return entry.document }
        let normalized = abc.replacingOccurrences(of: "\\r\\n?", with: "\n", options: .regularExpression)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let parsed = ABCBeaming.apply(to: ABCParser.parse(normalized))
        let diagnostics = (parsed.diagnostics + ABCDiagnostics.validate(normalized))
            .sorted { ($0.line, $0.severity == .error ? 0 : 1) < ($1.line, $1.severity == .error ? 0 : 1) }
        let result = Document(source: normalized, book: parsed, diagnostics: diagnostics,
                              firstTune: parsed.tunes.first.map(Self.tune))
        let elements = parsed.tunes.reduce(0) { sum, tune in
            sum + tune.voices.reduce(0) { $0 + $1.elements.count }
        }
        let events = result.firstTune?.sequence.tracks.reduce(0) { $0 + $1.events.count } ?? 0
        cache.setObject(Entry(result), forKey: key,
                        cost: normalized.utf8.count + elements * 256 + events * 80)
        return result
    }

}

#if canImport(UIKit)
import MediaPlayer
import UIKit

/// 共有シートへ渡すファイル(.sheet(item:) 用)
struct ShareFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Cursor changes are observed by the score alone, rather than every tab.
final class PlaybackCursor: ObservableObject {
    @Published var highlight: Set<Int> = []
    @Published var elementID: Int?
}

/// アプリ全体の状態。ABCソースのパース・音色割当・再生・入出力をまとめる。
final class StudioModel: ObservableObject {
    @Published var source: String = "" {
        didSet {
            sourceLineCount = SourceSyntax.lineCount(in: source)
            if isOpening { cancelOpening() }
        }
    }
    private(set) var sourceLineCount = 1
    @Published var sourceName: String = ""
    @Published var book: ABCBook?
    @Published var selectedTune = 0
    @Published var diagnostics: [ABCDiagnostic] = []
    /// voiceID → Instrument.id
    @Published var assignments: [String: String] = [:]
    let playbackCursor = PlaybackCursor()
    var highlight: Set<Int> {
        get { playbackCursor.highlight }
        set { if playbackCursor.highlight != newValue { playbackCursor.highlight = newValue } }
    }
    var cursorID: Int? {
        get { playbackCursor.elementID }
        set { if playbackCursor.elementID != newValue { playbackCursor.elementID = newValue } }
    }
    @Published var toastText: String?
    @Published var status = "準備完了"
    /// 再生速度(%)50-200
    @Published var speed = 100
    @Published var showImporter = false
    @Published var importError: String?
    /// ソースエディタへのジャンプ要求(行番号)。処理後 nil に戻す。
    @Published var jumpToLine: Int?
    /// ミュート中の声部
    @Published var mutedVoices: Set<String> = []
    /// ソロ再生中の声部(nil = なし)
    @Published var soloVoiceID: String?
    /// voiceID → パート音量 0...1
    @Published var partVolumes: [String: Double] = [:]
    /// マスター音量 0...1
    @Published var masterVolume: Double = 1
    /// 曲全体のループ再生
    @Published var loopEnabled = false {
        didSet { engine.loopEnabled = loopEnabled }
    }
    /// 共有シート表示要求(書き出し済みファイル)
    @Published var shareFile: ShareFile?
    /// 音声レンダリング中
    @Published var isRendering = false
    /// ライブラリ(保存済みの曲)の一覧。新しい順。
    @Published var libraryItems: [LibraryItem] = []

    let engine = PlaybackEngine()
    private let libraryStore = LibraryStore()
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
    private var remoteInstalled = false
    private var didRestore = false
    @Published private(set) var isOpening = false
    private var openGeneration = 0
    private var openWork: DispatchWorkItem?
    private let documentQueue = DispatchQueue(label: "jp.porari.abcstudio.documents", qos: .userInitiated)

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
        engineObserver = engine.$isPlaying.removeDuplicates().sink { [weak self] _ in self?.objectWillChange.send() }
        engine.onCursor = { [weak self] ids, anchor in
            self?.highlight = ids
            self?.cursorID = anchor
        }
        engine.onFinish = { [weak self] in
            guard let self else { return }
            self.highlight = []
            self.cursorID = nil
            self.status = "再生完了"
            self.updateNowPlaying()
        }
        engine.onAutoPause = { [weak self] in
            guard let self else { return }
            self.status = "一時停止"
            self.updateNowPlaying()
        }
        installRemoteCommands()
    }

    // MARK: - 読み込み

    func restore() {
        guard !didRestore else { return }
        didRestore = true
        refreshLibrary()
        // A file opened at launch takes precedence over restoring the old tab.
        guard !isOpening else { return }
        guard let abc = UserDefaults.standard.string(forKey: "lastABC") else {
            openForDisplay(filename: "", persist: false, read: { Self.example })
            return
        }
        openForDisplay(filename: UserDefaults.standard.string(forKey: "lastFilename") ?? "",
                       persist: false, read: { abc })
    }

    /// インポートできるファイルサイズの上限(ABC テキストとしては十分大きい)。
    /// 巨大ファイルをメインスレッドでパースして UI が固まるのを防ぐ。
    private static let maxImportBytes = 8 * 1024 * 1024

    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= Self.maxImportBytes else {
                throw ImportFailure.tooLarge
            }
            guard let abc = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16) else {
                throw ImportFailure.unsupportedEncoding
            }
            loadABC(abc, filename: url.lastPathComponent)
        } catch {
            importError = error.localizedDescription
        }
    }

    /// クリップボードの ABC テキストを読み込む
    func importPaste() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            toast("クリップボードに ABC テキストがありません"); return
        }
        openForDisplay(filename: "クリップボード", read: { text })
    }

    /// バンドル同梱のサンプル曲(Samples/*.abc)
    lazy var samples: [(name: String, url: URL)] = {
        (Bundle.main.urls(forResourcesWithExtension: "abc", subdirectory: "Samples") ?? [])
            .map { ($0.deletingPathExtension().lastPathComponent, $0) }
            .sorted { $0.name < $1.name }
    }()

    func loadSample(_ url: URL) {
        do {
            let abc = try String(contentsOf: url, encoding: .utf8)
            loadABC(abc, filename: url.lastPathComponent)
        } catch {
            toast("サンプルを読み込めません: \(error.localizedDescription)")
        }
    }

    /// エディタ内容を楽譜に反映
    func applySource() {
        loadABC(source, filename: sourceName)
    }

    typealias PreparedTune = StudioDocumentPreparation.Tune
    private typealias PreparedDocument = StudioDocumentPreparation.Document

    private static func prepareTune(_ tune: ABCTune) -> PreparedTune {
        StudioDocumentPreparation.tune(tune)
    }

    private static func prepareDocument(_ abc: String) -> PreparedDocument? {
        StudioDocumentPreparation.document(abc)
    }

    func loadABC(_ abc: String, filename: String, persist: Bool = true) {
        cancelOpening()
        lintTask?.cancel()
        guard let document = Self.prepareDocument(abc) else { toast("ABC の内容が空です"); return }
        apply(document, filename: filename, persist: persist)
    }

    private func apply(_ document: PreparedDocument, filename: String, persist: Bool) {
        let normalized = document.source
        source = normalized
        sourceName = filename
        let parsed = document.book
        book = parsed
        diagnostics = document.diagnostics
        highlight = []
        cursorID = nil
        guard !parsed.tunes.isEmpty else {
            sequence = nil
            engine.unload()
            selectedTune = 0
            assignments = [:]
            partVolumes = [:]
            partVolumeNames = [:]
            mutedVoices = []
            soloVoiceID = nil
            shareFile = nil
            status = "読み込みエラー"
            toast(diagnostics.first(where: { $0.severity == .error })?.message ?? "ABC を確認してください")
            updateNowPlaying()
            return
        }
        selectTune(0, prepared: document.firstTune)
        if diagnostics.contains(where: { $0.severity == .warning }) {
            status = "読み込み完了（警告あり）"
            toast("警告があります。「エディタ」タブで確認できます")
        }
        if persist {
            UserDefaults.standard.set(normalized, forKey: "lastABC")
            UserDefaults.standard.set(filename, forKey: "lastFilename")
        }
        updateNowPlaying()
    }

    /// UI requests share one generation so older reads/parses never replace a
    /// newer selection. Disk I/O, parsing and sequencing stay off the UI queue.
    private func openForDisplay(filename: String, play: Bool = false, persist: Bool = true,
                                read: @escaping () throws -> String,
                                completion: ((Bool) -> Void)? = nil) {
        cancelOpening()
        lintTask?.cancel()
        let generation = openGeneration
        isOpening = true
        let work = DispatchWorkItem { [weak self] in
            do {
                let document = Self.prepareDocument(try read())
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.openGeneration == generation else { return }
                    self.isOpening = false
                    self.openWork = nil
                    guard let document else {
                        self.toast("ABC の内容が空です")
                        completion?(false)
                        return
                    }
                    self.apply(document, filename: filename, persist: persist)
                    let success = self.tune != nil && !self.diagnostics.contains { $0.severity == .error }
                    if play, success { self.engine.play(); self.status = "再生中"; self.updateNowPlaying() }
                    completion?(success)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.openGeneration == generation else { return }
                    self.isOpening = false
                    self.openWork = nil
                    self.importError = error.localizedDescription
                    completion?(false)
                }
            }
        }
        openWork = work
        documentQueue.async(execute: work)
    }

    private func cancelOpening() {
        openGeneration += 1
        openWork?.cancel()
        openWork = nil
        if isOpening { isOpening = false }
    }

    func applySourceForDisplay(completion: @escaping (Bool) -> Void) {
        let draft = source
        openForDisplay(filename: sourceName, read: { draft }, completion: completion)
    }

    func loadSampleForDisplay(_ url: URL) {
        openForDisplay(filename: url.lastPathComponent, read: { try String(contentsOf: url, encoding: .utf8) })
    }

    func openLibraryItemForDisplay(_ item: LibraryItem, play: Bool = false) {
        let store = libraryStore
        openForDisplay(filename: item.name, play: play, read: { try store.read(item) }) { [weak self] success in
            if !success { self?.refreshLibrary() }
        }
    }

    func importFileForDisplay(_ url: URL) {
        openForDisplay(filename: url.lastPathComponent, read: {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.count <= Self.maxImportBytes else { throw ImportFailure.tooLarge }
            guard let abc = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16) else { throw ImportFailure.unsupportedEncoding }
            return abc
        })
    }

    func selectTuneForDisplay(_ index: Int) {
        guard let book, book.tunes.indices.contains(index) else { return }
        cancelOpening()
        let generation = openGeneration
        let tune = book.tunes[index]
        isOpening = true
        let work = DispatchWorkItem { [weak self] in
            let prepared = Self.prepareTune(tune)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.openGeneration == generation else { return }
                self.isOpening = false
                self.openWork = nil
                self.selectTune(index, prepared: prepared)
            }
        }
        openWork = work
        documentQueue.async(execute: work)
    }

    private var assignmentPartNames: [String: String] = [:]
    /// パート音量を同じ ID・名前の声部へ引き継ぐための対応表。
    private var partVolumeNames: [String: String] = [:]

    func selectTune(_ index: Int, prepared: PreparedTune? = nil) {
        guard let book, book.tunes.indices.contains(index) else { return }
        selectedTune = index
        let tune = book.tunes[index]
        var next: [String: String] = [:]
        var nextVolumes: [String: Double] = [:]
        for v in tune.voices {
            next[v.id] = assignmentPartNames[v.id] == v.name ? assignments[v.id] : nil
            if next[v.id] == nil {
                next[v.id] = prepared?.instruments[v.id]
                    ?? Instruments.namedInstrument(forPartName: v.name)?.id ?? (v.isPercussion ? "drums" : "piano")
            }
            let volume = partVolumeNames[v.id] == v.name ? partVolumes[v.id] : nil
            nextVolumes[v.id] = Self.clampVolume(volume ?? 1)
        }
        assignments = next
        partVolumes = nextVolumes
        assignmentPartNames = Dictionary(uniqueKeysWithValues: tune.voices.map { ($0.id, $0.name) })
        partVolumeNames = Dictionary(uniqueKeysWithValues: tune.voices.map { ($0.id, $0.name) })
        let voiceIDs = Set(nextVolumes.keys)
        mutedVoices.formIntersection(voiceIDs)
        if let soloVoiceID, !voiceIDs.contains(soloVoiceID) {
            self.soloVoiceID = nil
        }
        rebuildSequence(prepared?.sequence)
        updateNowPlaying()
    }

    // MARK: - 再生

    private func instrumentMap() -> [String: Instrument] {
        var map: [String: Instrument] = [:]
        for v in tune?.voices ?? [] {
            map[v.id] = Instruments.byID(assignments[v.id] ?? "") ?? Instruments.all[0]
        }
        return map
    }

    private func rebuildSequence(_ prepared: PlaybackSequence? = nil) {
        guard let tune else { return }
        engine.stop()
        sequence = prepared ?? ABCSequencer.sequence(tune)
        engine.load(sequence!, instruments: instrumentMap())
        applyGains()
        engine.setMasterVolume(Float(masterVolume))
    }

    func assign(_ voiceID: String, instrument: String) {
        assignments[voiceID] = instrument
        rebuildSequence(sequence)
        toast("次の再生から音色を変更します")
    }

    /// 声部ごとの実効音量(パート音量にソロ・ミュートを反映)
    private func trackGains() -> [String: Float] {
        var gains: [String: Float] = [:]
        for v in tune?.voices ?? [] {
            let audible = soloVoiceID != nil ? v.id == soloVoiceID : !mutedVoices.contains(v.id)
            gains[v.id] = audible ? Float(Self.clampVolume(partVolumes[v.id] ?? 1)) : 0
        }
        return gains
    }

    private static func clampVolume(_ volume: Double) -> Double {
        guard volume.isFinite else { return 1 }
        return min(1, max(0, volume))
    }

    /// 声部の現在の音量。未設定の声部は 100% とする。
    func partVolume(for voiceID: String) -> Double {
        Self.clampVolume(partVolumes[voiceID] ?? 1)
    }

    private func applyGains() {
        engine.setTrackGains(trackGains())
    }

    func toggleMute(_ voiceID: String) {
        if mutedVoices.contains(voiceID) {
            mutedVoices.remove(voiceID)
        } else {
            mutedVoices.insert(voiceID)
        }
        applyGains()
    }

    func toggleSolo(_ voiceID: String) {
        soloVoiceID = soloVoiceID == voiceID ? nil : voiceID
        applyGains()
    }

    /// 声部の音量を 0...1 に収め、再生中のノードにも即時反映する。
    func setPartVolume(_ voiceID: String, volume: Double) {
        var next = partVolumes
        next[voiceID] = Self.clampVolume(volume)
        partVolumes = next
        applyGains()
    }

    func setMasterVolume(_ volume: Double) {
        let clamped = Self.clampVolume(volume)
        masterVolume = clamped
        engine.setMasterVolume(Float(clamped))
    }

    func togglePlay() {
        guard !isOpening || engine.isPlaying else { return }
        guard tune != nil else { toast("楽譜を読み込んでください"); return }
        if engine.isPlaying {
            engine.pause()
            status = "一時停止"
        } else {
            engine.play()
            status = "再生中"
        }
        updateNowPlaying()
    }

    func stopPlayback() {
        engine.stop()
        highlight = []
        cursorID = nil
        status = "停止"
        updateNowPlaying()
    }

    func seek(to fraction: Double) {
        guard !isOpening else { return }
        engine.seek(toFraction: fraction)
        updateNowPlaying()
    }

    /// 楽譜上の音符タップ → その位置へシーク
    func seekToElement(_ elementID: Int) {
        guard !isOpening else { return }
        engine.seekToElement(elementID)
        status = engine.isPlaying ? "再生中" : "シーク"
        updateNowPlaying()
    }

    func setSpeed(_ percent: Int) {
        let clamped = min(200, max(50, percent))
        speed = clamped
        engine.setSpeed(clamped)
        status = "速度変更済み"
        updateNowPlaying()
    }

    // MARK: - 書き出し

    private func writeTemp(_ data: Data, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        do {
            try data.write(to: url)
            return url
        } catch {
            toast("書き出しに失敗しました: \(error.localizedDescription)")
            return nil
        }
    }

    private func exportName(_ ext: String) -> String {
        let base: String
        if let t = tune?.title, !t.isEmpty {
            base = t
        } else {
            base = sourceName.isEmpty ? "score" : sourceName
        }
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:"))
            .joined(separator: "_")
        let stem = safe.hasSuffix("." + ext) ? String(safe.dropLast(ext.count + 1)) : safe
        return stem + "." + ext
    }

    /// 編集中の ABC テキストを .abc ファイルとして共有
    func shareSource() {
        guard let f = writeTemp(Data(source.utf8), name: exportName("abc")) else { return }
        shareFile = ShareFile(url: f)
    }

    /// 楽譜を PNG 画像として共有
    func shareScorePNG() {
        guard let tune else { toast("楽譜を読み込んでください"); return }
        guard let data = ScoreExporter.pngData(tune: tune) else {
            toast("画像の作成に失敗しました"); return
        }
        guard let f = writeTemp(data, name: exportName("png")) else { return }
        shareFile = ShareFile(url: f)
    }

    /// 楽譜を PDF として共有
    func shareScorePDF() {
        guard let tune else { toast("楽譜を読み込んでください"); return }
        guard let data = ScoreExporter.pdfData(tune: tune) else {
            toast("PDF の作成に失敗しました"); return
        }
        guard let f = writeTemp(data, name: exportName("pdf")) else { return }
        shareFile = ShareFile(url: f)
    }

    /// 演奏データを MIDI ファイルとして共有
    func shareMIDI() {
        guard let seq = sequence else { toast("楽譜を読み込んでください"); return }
        let data = MIDIWriter.data(for: seq, instruments: instrumentMap())
        guard let f = writeTemp(data, name: exportName("mid")) else { return }
        shareFile = ShareFile(url: f)
    }

    /// 実行中の音声書き出しタスク(キャンセル用)
    private var renderTask: Task<Void, Never>?

    /// 演奏を WAV 音声としてオフラインレンダリングして共有(非同期・キャンセル可能)
    func shareAudio() {
        guard let seq = sequence else { toast("楽譜を読み込んでください"); return }
        isRendering = true
        status = "音声を書き出し中…"
        let instruments = instrumentMap()
        let gains = trackGains()
        let volume = Float(masterVolume)
        let percent = speed
        let name = exportName("wav")
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let url = try AudioExporter.render(sequence: seq,
                                                   instruments: instruments,
                                                   trackGains: gains,
                                                   masterVolume: volume,
                                                   speedPercent: percent,
                                                   filename: name)
                await MainActor.run {
                    self?.isRendering = false
                    self?.status = "書き出し完了"
                    self?.shareFile = ShareFile(url: url)
                }
            } catch {
                await MainActor.run {
                    self?.isRendering = false
                    if error is AudioExporter.RenderError,
                       (error as? AudioExporter.RenderError) == .cancelled {
                        self?.status = "書き出しをキャンセルしました"
                    } else {
                        self?.status = "書き出し失敗"
                        self?.toast(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// 実行中の音声書き出しを中断する(途中まで書かれたファイルは残さない)
    func cancelRender() {
        renderTask?.cancel()
        renderTask = nil
        isRendering = false
        status = "書き出しをキャンセルしました"
    }

    // MARK: - ライブラリ

    func refreshLibrary() {
        libraryItems = libraryStore.items()
    }

    /// 表示中の ABC をライブラリに保存する。
    /// 名前は T: フィールド → ファイル名 → 「無題の曲」の順で決める。
    func saveToLibrary() {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            toast("保存する ABC がありません"); return
        }
        let stem = (sourceName as NSString).deletingPathExtension
        let name = LibraryStore.title(in: source)
            ?? (stem.isEmpty ? nil : stem)
            ?? "無題の曲"
        do {
            let item = try libraryStore.save(name: name, abc: source)
            refreshLibrary()
            toast("「\(item.name)」をライブラリに保存しました")
        } catch {
            toast("ライブラリに保存できませんでした: \(error.localizedDescription)")
        }
    }

    /// ライブラリの曲を開く。play=true で開いてそのまま再生する。
    func openLibraryItem(_ item: LibraryItem, play: Bool = false) {
        do {
            loadABC(try libraryStore.read(item), filename: item.name)
        } catch {
            toast("ライブラリから開けませんでした: \(error.localizedDescription)")
            refreshLibrary()
            return
        }
        if play, tune != nil { togglePlay() }
    }

    func deleteLibraryItem(_ item: LibraryItem) {
        do {
            try libraryStore.delete(item)
            refreshLibrary()
            toast("「\(item.name)」を削除しました")
        } catch {
            toast("削除できませんでした: \(error.localizedDescription)")
        }
    }

    func renameLibraryItem(_ item: LibraryItem, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try libraryStore.rename(item, to: trimmed)
            refreshLibrary()
        } catch {
            toast("名前を変更できませんでした: \(error.localizedDescription)")
        }
    }

    // MARK: - 診断・エディタ

    /// エディタ入力時の遅延バリデーション(重いパースはバックグラウンドで)と
    /// ドラフト自動保存(「楽譜に反映」を押さずに終了しても編集が残る)。
    func scheduleValidation() {
        lintTask?.cancel()
        let src = source
        lintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            UserDefaults.standard.set(src, forKey: "lastABC")
            let diags = await Task.detached(priority: .userInitiated) {
                let parsed = ABCParser.parse(src)
                return (parsed.diagnostics + ABCDiagnostics.validate(src))
                    .sorted {
                        ($0.line, $0.severity == .error ? 0 : 1)
                            < ($1.line, $1.severity == .error ? 0 : 1)
                    }
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run { self.diagnostics = diags }
        }
    }

    func validateSource() {
        let parsed = ABCParser.parse(source)
        diagnostics = (parsed.diagnostics + ABCDiagnostics.validate(source))
            .sorted { ($0.line, $0.severity == .error ? 0 : 1) < ($1.line, $1.severity == .error ? 0 : 1) }
    }

    /// エディタの ABC テキストをすべて削除する。下書き保存も空にして次回起動時に復活しないようにする。
    func clearSource() {
        lintTask?.cancel()
        source = ""
        diagnostics = []
        jumpToLine = nil
        UserDefaults.standard.set("", forKey: "lastABC")
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

    // MARK: - Now Playing / リモコン

    /// ロック画面・コントロールセンターの再生操作をアプリに接続する。
    private func installRemoteCommands() {
        guard !remoteInstalled else { return }
        remoteInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.tune != nil else { return .commandFailed }
            self.togglePlay()
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.tune != nil, !self.engine.isPlaying else { return .commandFailed }
            self.togglePlay()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.engine.isPlaying else { return .commandFailed }
            self.togglePlay()
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.stopPlayback()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let e = event as? MPChangePlaybackPositionCommandEvent,
                  self.displayDuration > 0 else { return .commandFailed }
            self.seek(to: e.positionTime / self.displayDuration)
            return .success
        }
    }

    /// Now Playing 情報(曲名・長さ・再生位置・レート)を更新する。
    func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: tune?.title ?? "ABC Studio",
            MPMediaItemPropertyArtist: "ABC Studio",
            MPMediaItemPropertyPlaybackDuration: displayDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: engine.progress * displayDuration,
            MPNowPlayingInfoPropertyPlaybackRate: engine.isPlaying ? Double(speed) / 100 : 0,
        ]
        if let composer = tune?.composer, !composer.isEmpty {
            info[MPMediaItemPropertyComposer] = composer
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private enum ImportFailure: LocalizedError {
        case unsupportedEncoding
        case tooLarge
        var errorDescription: String? {
            switch self {
            case .unsupportedEncoding:
                return "この ABC ファイルの文字コードを読み込めません。UTF-8 または UTF-16 で保存してください。"
            case .tooLarge:
                return "このファイルは大きすぎます(8 MB まで)。ABC テキストとして読み込める範囲を確認してください。"
            }
        }
    }
}

#endif
