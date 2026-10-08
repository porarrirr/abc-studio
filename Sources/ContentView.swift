import SwiftUI
import UniformTypeIdentifiers

private extension Color {
    static let canvas = Color(red: 0.961, green: 0.961, blue: 0.937)
    static let card = Color(red: 1, green: 0.996, blue: 0.980)
    static let topbar = Color(red: 1, green: 0.992, blue: 0.973)
    static let line = Color(red: 0.894, green: 0.910, blue: 0.882)
    static let ink = Color(red: 0.098, green: 0.196, blue: 0.231)
    static let sub = Color(red: 0.443, green: 0.529, blue: 0.514)
    static let faint = Color(red: 0.604, green: 0.671, blue: 0.651)
    static let teal = Color(red: 0.086, green: 0.494, blue: 0.451)
    static let tealDark = Color(red: 0.106, green: 0.439, blue: 0.420)
    static let amber = Color(red: 0.914, green: 0.635, blue: 0.263)
    static let fieldBg = Color(red: 0.988, green: 0.996, blue: 0.984)
}

struct ContentView: View {
    @EnvironmentObject private var model: StudioModel
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var tab = 0
    @State private var seekDrag: Double?
    @State private var speedDrag: Double?
    @State private var showAbout = false
    @State private var showClearConfirm = false
    /// ライブラリの名前変更/削除確認対象
    @State private var renamingItem: LibraryItem?
    @State private var renameText = ""
    @State private var deletingItem: LibraryItem?
    /// 譜面の表示倍率と自動追従(次回起動時も維持)
    @AppStorage("scoreZoom") private var scoreZoom = 1.0
    @AppStorage("scoreFollowEnabled") private var followEnabled = true
    /// Info.plist でエクスポート宣言した独自 UTI(なければプレーンテキスト扱い)
    private let abcType = UTType("jp.porari.abc") ?? .plainText
    private let tabs = ["楽譜", "楽器", "ABCを編集", "ライブラリ"]

    /// iPhone(コンパクト幅)では譜面を余白なしの全画面表示にする
    private var isCompact: Bool { hSize == .compact }

    var body: some View {
        VStack(spacing: 0) {
            header
            workspace
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { playerBar }
        .overlay(alignment: .bottom) { toastOverlay }
        .overlay { if model.isRendering { renderingOverlay } }
        .fileImporter(isPresented: $model.showImporter,
                      allowedContentTypes: [abcType, .plainText],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.importFile(url) }
            case .failure(let error):
                model.importError = error.localizedDescription
            }
        }
        .sheet(item: $model.shareFile) { file in
            ShareSheet(items: [file.url])
        }
        .sheet(isPresented: $showAbout) { AboutView() }
        .alert("読み込みエラー", isPresented: Binding(
            get: { model.importError != nil },
            set: { if !$0 { model.importError = nil } }
        )) {
            Button("コピー") {
                UIPasteboard.general.string = model.importError
                model.importError = nil
            }
            Button("閉じる") { model.importError = nil }
        } message: {
            Text(model.importError ?? "")
        }
        .onAppear { model.restore() }
        .focusable()
        .onKeyPress(.space) { model.togglePlay(); return .handled }
        .onKeyPress(.leftArrow) {
            model.seek(to: max(0, model.engine.progress - 0.02)); return .handled
        }
        .onKeyPress(.rightArrow) {
            model.seek(to: min(1, model.engine.progress + 0.02)); return .handled
        }
    }

    // MARK: - ヘッダー

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                Text("♮")
                    .font(.custom("Georgia", size: 27))
                    .foregroundStyle(.white)
                    .frame(width: 37, height: 37)
                    .background(Color(red: 0.106, green: 0.439, blue: 0.420))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 1) {
                    Text("ABC Studio").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.ink)
                    Text("楽譜を、音に。")
                        .font(.system(size: 10))
                        .tracking(0.8)
                        .foregroundStyle(Color.sub)
                }
            }
            Spacer()
            Button { model.showImporter = true } label: {
                Label("ABCを読み込む", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.tealDark)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(red: 0.957, green: 0.980, blue: 0.965))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.796, green: 0.863, blue: 0.839)))
            }
            Menu {
                Button { model.importPaste() } label: {
                    Label("クリップボードから読み込む", systemImage: "doc.on.clipboard")
                }
                if !model.samples.isEmpty {
                    Menu("サンプルを開く") {
                        ForEach(model.samples, id: \.url) { sample in
                            Button(sample.name) { model.loadSample(sample.url) }
                        }
                    }
                }
                Divider()
                Button { model.saveToLibrary() } label: {
                    Label("現在の曲をライブラリに保存", systemImage: "square.and.arrow.down")
                }
                .disabled(model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button { tab = 3 } label: {
                    Label("ライブラリを開く", systemImage: "books.vertical")
                }
                Divider()
                Button { model.shareSource() } label: {
                    Label("ABC を保存・共有", systemImage: "doc.text")
                }
                Menu("楽譜を書き出す") {
                    Button { model.shareScorePNG() } label: { Label("PNG 画像", systemImage: "photo") }
                    Button { model.shareScorePDF() } label: { Label("PDF", systemImage: "doc") }
                }
                Button { model.shareMIDI() } label: {
                    Label("MIDI を書き出す", systemImage: "pianokeys")
                }
                Button { model.shareAudio() } label: {
                    Label("音声 (WAV) を書き出す", systemImage: "waveform")
                }
                .disabled(model.isRendering)
                Divider()
                Button { showAbout = true } label: {
                    Label("このアプリについて", systemImage: "info.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.tealDark)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("メニュー")
        }
        .padding(.horizontal, 22)
        .frame(height: 66)
        .background(Color.topbar)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
    }

    // MARK: - ワークスペース(タブ+ペイン)

    /// タブとペインが残りの画面をすべて使う。コンパクト幅ではカード装飾を外して全画面化。
    private var workspace: some View {
        VStack(spacing: 0) {
            tabBar
            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: isCompact ? 0 : 15))
        .overlay(RoundedRectangle(cornerRadius: isCompact ? 0 : 15)
            .stroke(Color(red: 0.875, green: 0.906, blue: 0.875)))
        .shadow(color: Color(red: 0.125, green: 0.239, blue: 0.212)
            .opacity(isCompact ? 0 : 0.06), radius: 21, y: 9)
        .padding(.horizontal, isCompact ? 0 : 16)
        .padding(.top, isCompact ? 0 : 14)
        .padding(.bottom, isCompact ? 0 : 16)
        .frame(maxWidth: 1240)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabBar: some View {
        HStack(spacing: 17) {
            ForEach(tabs.indices, id: \.self) { i in
                Button { tab = i } label: {
                    Text(tabs[i])
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tab == i ? Color.tealDark : Color.sub)
                        .padding(.vertical, 15)
                        .padding(.horizontal, 2)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(tab == i ? Color.teal : .clear)
                                .frame(height: 3)
                        }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .background(Color(red: 0.976, green: 0.984, blue: 0.969))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch tab {
        case 0: scorePane
        case 1: partsPane
        case 2: sourcePane
        default: libraryPane
        }
    }

    // MARK: - 楽譜ペイン

    private var scorePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("SCORE")
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(1.6)
                            .foregroundStyle(Color(red: 0.137, green: 0.545, blue: 0.498))
                        Text(model.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.sub)
                            .lineLimit(1)
                    }
                    Text(model.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let book = model.book, book.tunes.count > 1 {
                    Picker("曲を選択", selection: Binding(
                        get: { model.selectedTune },
                        set: { model.selectTune($0) })) {
                        ForEach(book.tunes.indices, id: \.self) { i in
                            Text(book.tunes[i].title.isEmpty ? "曲 \(i + 1)" : book.tunes[i].title).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 12))
                    .tint(Color.tealDark)
                    .labelsHidden()
                }
                zoomControl
                followToggle
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }

            if let tune = model.tune {
                ScoreView(tune: tune, highlight: model.highlight, cursorID: model.cursorID,
                          isPlaying: model.engine.isPlaying,
                          zoom: $scoreZoom, followEnabled: followEnabled,
                          onTapNote: { model.seekToElement($0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
    }

    private func setZoom(_ z: Double) {
        scoreZoom = min(ScoreView.maxZoom, max(ScoreView.minZoom, (z * 20).rounded() / 20))
    }

    private var zoomControl: some View {
        HStack(spacing: 0) {
            Button { setZoom(scoreZoom - 0.1) } label: {
                Image(systemName: "minus").frame(width: 28, height: 30)
            }
            .accessibilityLabel("縮小")
            Button { setZoom(1) } label: {
                Text("\(Int((scoreZoom * 100).rounded()))%")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .frame(minWidth: 34)
            }
            .accessibilityLabel("表示倍率をリセット")
            Button { setZoom(scoreZoom + 0.1) } label: {
                Image(systemName: "plus").frame(width: 28, height: 30)
            }
            .accessibilityLabel("拡大")
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(Color.tealDark)
        .background(Color(red: 0.957, green: 0.973, blue: 0.965))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color(red: 0.855, green: 0.894, blue: 0.867)))
    }

    private var followToggle: some View {
        Button { followEnabled.toggle() } label: {
            Label("追従", systemImage: followEnabled ? "location.fill" : "location.slash")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(followEnabled ? .white : Color.sub)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(followEnabled ? Color.teal : Color(red: 0.957, green: 0.973, blue: 0.965))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(followEnabled ? Color.teal : Color(red: 0.855, green: 0.894, blue: 0.867)))
        }
        .accessibilityLabel("自動追従")
        .accessibilityValue(followEnabled ? "オン" : "オフ")
    }

    // MARK: - 楽器ペイン

    private var partsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("INSTRUMENTS")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(1.8)
                            .foregroundStyle(Color(red: 0.137, green: 0.545, blue: 0.498))
                        Text("パートごとの音量・音色")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(Color.ink)
                    }
                    Spacer()
                    Text("音量は再生中にも変更できます。楽器の変更は次の再生から反映されます。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.sub)
                        .frame(maxWidth: 330, alignment: .trailing)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 17).padding(.top, 21).padding(.bottom, 8)

                if let tune = model.tune {
                    ForEach(Array(tune.voices.enumerated()), id: \.element.id) { index, voice in
                        partRow(voice: voice, index: index)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.tealDark)
                        Text("マスター音量")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.ink)
                        Spacer()
                        Text("\(Int((model.masterVolume * 100).rounded()))%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.sub)
                    }
                    Slider(value: Binding(
                        get: { model.masterVolume },
                        set: { model.setMasterVolume($0) }), in: 0...1)
                        .tint(Color.teal)
                        .accessibilityLabel("マスター音量")
                }
                .padding(13)
                .background(Color(red: 0.988, green: 0.992, blue: 0.980))
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color(red: 0.886, green: 0.918, blue: 0.882)))
                .padding(.horizontal, 16).padding(.top, 10)

                Text("合唱は Choir Aahs 音色で再生します。歌詞を歌う音声合成ではありません。ドラムは General MIDI の打楽器配置に従います。S はソロ(そのパートだけ鳴らす)、スピーカーはミュートです。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sub)
                    .lineSpacing(4)
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 0.937, green: 0.961, blue: 0.937))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16).padding(.vertical, 22)
            }
        }
    }

    private func partRow(voice: ABCVoice, index: Int) -> some View {
        let instrument = Instruments.byID(model.assignments[voice.id] ?? "") ?? Instruments.all[0]
        let muted = model.mutedVoices.contains(voice.id)
        let soloed = model.soloVoiceID == voice.id
        let volume = model.partVolume(for: voice.id)
        let volumePercent = Int((volume * 100).rounded())
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 12) {
                    Text(instrument.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(Color.tealDark)
                        .frame(width: 37, height: 37)
                        .background(Color(red: 0.910, green: 0.949, blue: 0.925))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.ink)
                        Text("パート \(index + 1)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.faint)
                    }
                }
                .opacity(muted ? 0.45 : 1)
                Spacer(minLength: 6)
                Button { model.toggleSolo(voice.id) } label: {
                    Text("S")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(soloed ? .white : Color.sub)
                        .frame(width: 26, height: 26)
                        .background(soloed ? Color.amber : Color(red: 0.937, green: 0.953, blue: 0.941))
                        .clipShape(Circle())
                }
                .accessibilityLabel(voice.name + "をソロ再生")
                Button { model.toggleMute(voice.id) } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(muted ? .white : Color.sub)
                        .frame(width: 26, height: 26)
                        .background(muted ? Color(red: 0.643, green: 0.220, blue: 0.165)
                                          : Color(red: 0.937, green: 0.953, blue: 0.941))
                        .clipShape(Circle())
                }
                .accessibilityLabel(voice.name + "をミュート")
            }

            HStack(spacing: 9) {
                Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.tealDark)
                    .frame(width: 20)
                Slider(value: Binding(
                    get: { model.partVolume(for: voice.id) },
                    set: { model.setPartVolume(voice.id, volume: $0) }), in: 0...1)
                    .tint(Color.teal)
                    .accessibilityLabel(voice.name + "の音量")
                    .accessibilityValue("\(volumePercent)%")
                    .accessibilityIdentifier("part-volume-\(voice.id)")
                Text("\(volumePercent)%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.sub)
                    .frame(width: 42, alignment: .trailing)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                Text("楽器")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.faint)
                Spacer()
                Picker(voice.name + "の楽器", selection: Binding(
                    get: { model.assignments[voice.id] ?? "piano" },
                    set: { model.assign(voice.id, instrument: $0) })) {
                    ForEach(Instruments.categories, id: \.self) { category in
                        Section(category) {
                            ForEach(Instruments.all.filter { $0.category == category }, id: \.id) { inst in
                                Text(inst.label).tag(inst.id)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 13, weight: .bold))
                .tint(Color(red: 0.133, green: 0.310, blue: 0.294))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(red: 0.796, green: 0.863, blue: 0.831)))
            }
        }
        .padding(12)
        .background(Color(red: 0.988, green: 0.992, blue: 0.980))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color(red: 0.886, green: 0.918, blue: 0.882)))
        .padding(.horizontal, 16).padding(.vertical, 5)
    }

    // MARK: - ソースペイン

    private var sourcePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ABC SOURCE")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(1.8)
                            .foregroundStyle(Color(red: 0.137, green: 0.545, blue: 0.498))
                        Text("記譜を編集")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(Color.ink)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("検証") { model.validateSource() }
                            .buttonStyle(SmallActionStyle(primary: false))
                        Button("楽譜に反映") { model.applySource() }
                            .buttonStyle(SmallActionStyle(primary: true))
                    }
                }
                .padding(.horizontal, 16).padding(.top, 21).padding(.bottom, 9)

                SourceEditor(text: Binding(
                    get: { model.source },
                    set: { model.source = $0; model.scheduleValidation() }),
                    jumpToLine: $model.jumpToLine)
                    .frame(height: 300)
                    .overlay(alignment: .topTrailing) {
                        Button { showClearConfirm = true } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(red: 0.643, green: 0.220, blue: 0.165))
                                .frame(width: 30, height: 30)
                                .background(Color(red: 0.992, green: 0.941, blue: 0.933))
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9)
                                    .stroke(Color(red: 0.949, green: 0.831, blue: 0.804)))
                        }
                        .disabled(model.source.isEmpty)
                        .opacity(model.source.isEmpty ? 0.45 : 1)
                        .padding(10)
                        .accessibilityLabel("入力内容をすべて削除")
                    }
                    .padding(.horizontal, 16)
                    .alert("入力内容を削除", isPresented: $showClearConfirm) {
                        Button("すべて削除", role: .destructive) { model.clearSource() }
                        Button("キャンセル", role: .cancel) {}
                    } message: {
                        Text("エディタの ABC テキストをすべて削除します。楽譜に反映済みの内容は変わりません。")
                    }

                if !model.diagnostics.isEmpty {
                    diagnosticsPanel
                }

                Text("X:、T:、M:、L:、K: を含む ABC を入力してください。複数声部には V: を使います。エラーや警告は行番号付きで上に表示され、タップすると該当行に移動します。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sub)
                    .padding(.horizontal, 16).padding(.vertical, 18)
            }
        }
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(model.diagnosticSummary)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.sub)
                Spacer()
                Button("コピー") {
                    UIPasteboard.general.string = "ABC Studio 診断結果\n" + model.diagnosticText()
                    model.toast("診断結果をコピーしました")
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.tealDark)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.796, green: 0.863, blue: 0.831)))
            }
            .padding(.bottom, 3)

            ScrollView {
                ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, d in
                Button { model.jump(to: d) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(d.severity == .error ? "エラー" : "警告")\(d.line > 0 ? " \(d.line) 行目" : "")\(d.column > 0 ? " \(d.column) 文字目" : "")")
                                .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                            Text(" " + d.message)
                                .font(.system(size: 11.5, design: .monospaced))
                        }
                        if !d.context.isEmpty {
                            Text(d.context)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                                .padding(.leading, 14)
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .fill((d.severity == .error
                                            ? Color(red: 0.643, green: 0.220, blue: 0.165)
                                            : Color(red: 0.541, green: 0.392, blue: 0.125)).opacity(0.6))
                                        .frame(width: 2)
                                        .offset(x: -7)
                                }
                                .opacity(0.75)
                        }
                    }
                    .foregroundStyle(d.severity == .error
                        ? Color(red: 0.643, green: 0.220, blue: 0.165)
                        : Color(red: 0.541, green: 0.392, blue: 0.125))
                    .padding(EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(d.severity == .error
                        ? Color(red: 0.992, green: 0.941, blue: 0.933)
                        : Color(red: 0.992, green: 0.973, blue: 0.925))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(d.severity == .error
                        ? Color(red: 0.949, green: 0.831, blue: 0.804)
                        : Color(red: 0.941, green: 0.890, blue: 0.761)))
                }
                .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 10)
        .frame(maxHeight: 200)
    }

    // MARK: - ライブラリペイン

    private var libraryPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("LIBRARY")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(1.8)
                            .foregroundStyle(Color(red: 0.137, green: 0.545, blue: 0.498))
                        Text("保存した曲")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(Color.ink)
                    }
                    Spacer()
                    Button("現在の曲を保存") { model.saveToLibrary() }
                        .buttonStyle(SmallActionStyle(primary: true))
                        .disabled(model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 17).padding(.top, 21).padding(.bottom, 8)

                if model.libraryItems.isEmpty {
                    Text("まだ曲はありません。「現在の曲を保存」で、表示中の ABC をライブラリに保存できます。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.sub)
                        .lineSpacing(4)
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.937, green: 0.961, blue: 0.937))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16).padding(.top, 8)
                } else {
                    ForEach(model.libraryItems) { item in
                        libraryRow(item)
                    }
                }

                Text("曲をタップすると開いて「楽譜」タブに移ります。▶ で開いてすぐ再生。長押しで名前の変更・削除ができます。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sub)
                    .lineSpacing(4)
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 0.937, green: 0.961, blue: 0.937))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16).padding(.vertical, 22)
            }
        }
        .alert("名前を変更", isPresented: Binding(
            get: { renamingItem != nil },
            set: { if !$0 { renamingItem = nil } }
        )) {
            TextField("名前", text: $renameText)
            Button("保存") {
                if let item = renamingItem { model.renameLibraryItem(item, to: renameText) }
                renamingItem = nil
            }
            Button("キャンセル", role: .cancel) { renamingItem = nil }
        }
        .alert("ライブラリから削除", isPresented: Binding(
            get: { deletingItem != nil },
            set: { if !$0 { deletingItem = nil } }
        )) {
            Button("削除", role: .destructive) {
                if let item = deletingItem { model.deleteLibraryItem(item) }
                deletingItem = nil
            }
            Button("キャンセル", role: .cancel) { deletingItem = nil }
        } message: {
            Text("「\(deletingItem?.name ?? "")」を削除します。この操作は取り消せません。")
        }
    }

    private func libraryRow(_ item: LibraryItem) -> some View {
        HStack {
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.tealDark)
                    .frame(width: 37, height: 37)
                    .background(Color(red: 0.910, green: 0.949, blue: 0.925))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Text(item.createdAt.formatted(date: .numeric, time: .shortened)
                        + " · \(item.tuneCount) 曲")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.faint)
                }
            }
            Spacer()
            Button {
                model.openLibraryItem(item, play: true)
                tab = 0
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.teal)
                    .clipShape(Circle())
            }
            .accessibilityLabel(item.name + "を再生")
        }
        .padding(12)
        .background(Color(red: 0.988, green: 0.992, blue: 0.980))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color(red: 0.886, green: 0.918, blue: 0.882)))
        .padding(.horizontal, 16).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            model.openLibraryItem(item)
            tab = 0
        }
        .contextMenu {
            Button { model.openLibraryItem(item); tab = 0 } label: {
                Label("開く", systemImage: "doc.text.magnifyingglass")
            }
            Button { model.openLibraryItem(item, play: true); tab = 0 } label: {
                Label("再生", systemImage: "play")
            }
            Divider()
            Button {
                renameText = item.name
                renamingItem = item
            } label: {
                Label("名前を変更", systemImage: "pencil")
            }
            Button(role: .destructive) { deletingItem = item } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    // MARK: - プレイヤーバー

    private var playerBar: some View {
        HStack(spacing: 8) {
            Button { model.togglePlay() } label: {
                Text(model.engine.isPlaying ? "Ⅱ" : "▶")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 43, height: 43)
                    .background(Color.teal)
                    .clipShape(Circle())
                    .shadow(color: Color.teal.opacity(0.2), radius: 5, y: 2)
            }
            .accessibilityLabel(model.engine.isPlaying ? "一時停止" : "再生")
            Button { model.stopPlayback() } label: {
                Text("■")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(red: 0.271, green: 0.455, blue: 0.416))
                    .frame(width: 33, height: 33)
                    .background(Color(red: 0.929, green: 0.953, blue: 0.937))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("停止")
            Button { model.loopEnabled.toggle() } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(model.loopEnabled ? .white
                                        : Color(red: 0.271, green: 0.455, blue: 0.416))
                    .frame(width: 33, height: 33)
                    .background(model.loopEnabled ? Color.teal
                                        : Color(red: 0.929, green: 0.953, blue: 0.937))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("ループ再生")
            VStack(spacing: 6) {
                HStack {
                    Text(model.currentTimeText)
                    Spacer()
                    Text(model.status).foregroundStyle(Color(red: 0.337, green: 0.529, blue: 0.490))
                    Spacer()
                    Text(model.totalTimeText)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.sub)
                Slider(value: Binding(
                    get: { seekDrag ?? model.engine.progress * 1000 },
                    set: { seekDrag = $0 }),
                    in: 0...1000,
                    onEditingChanged: { editing in
                        if !editing, let v = seekDrag { model.seek(to: v / 1000) }
                        if !editing { seekDrag = nil }
                    })
                    .tint(Color(red: 0.118, green: 0.545, blue: 0.498))
                    .frame(height: 8)
                    .accessibilityLabel("再生位置")
            }
            HStack(spacing: 3) {
                Slider(value: Binding(
                    get: { speedDrag ?? Double(model.speed) },
                    set: { speedDrag = $0 }),
                    in: 50...200, step: 25,
                    onEditingChanged: { editing in
                        if !editing, let v = speedDrag { model.setSpeed(Int(v)) }
                        if !editing { speedDrag = nil }
                    })
                    .tint(Color(red: 0.118, green: 0.545, blue: 0.498))
                    .frame(width: 78)
                    .accessibilityLabel("再生速度")
                Text("\(Int((speedDrag ?? Double(model.speed)).rounded()))%")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.133, green: 0.310, blue: 0.294))
                    .frame(width: 34)
            }
            .fixedSize()
        }
        .padding(.horizontal, 13)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .background(Color(red: 1, green: 0.996, blue: 0.976))
        .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
        .shadow(color: Color(red: 0.125, green: 0.247, blue: 0.227).opacity(0.07), radius: 12, y: -4)
    }

    private var toastOverlay: some View {
        Group {
            if let text = model.toastText {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color(red: 0.137, green: 0.275, blue: 0.255))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                    .padding(.bottom, 100)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toastText != nil)
    }

    /// 音声書き出し中の進行表示
    private var renderingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView()
                    .tint(Color.tealDark)
                Text("音声を書き出し中…")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.ink)
                Button("キャンセル", role: .cancel) { model.cancelRender() }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.tealDark)
                    .accessibilityLabel("書き出しをキャンセル")
            }
            .padding(24)
            .background(Color.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// 「このアプリについて」シート。バージョンと音色の帰属表示。
private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var attribution: String {
        guard let url = Bundle.main.url(forResource: "SOUNDFONT-ATTRIBUTION",
                                        withExtension: "md",
                                        subdirectory: "SoundFont"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "音色: FluidR3_GM(SoundFont/SOUNDFONT-ATTRIBUTION.md を同梱)"
        }
        return text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Text("♮")
                            .font(.custom("Georgia", size: 24))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color(red: 0.106, green: 0.439, blue: 0.420))
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ABC Studio").font(.system(size: 17, weight: .bold))
                            Text("バージョン \(version)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text("© 2026 porari")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("ABC 記譜法の楽譜表示・再生アプリ。解析・譜面描画・再生はすべてネイティブ実装です。")
                        .font(.system(size: 13))
                    Text("楽譜記号: Bravura © Steinberg Media Technologies GmbH(SIL Open Font License 1.1)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(attribution)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("このアプリについて")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

private struct SmallActionStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(primary ? .white : Color.tealDark)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(primary ? Color(red: 0.110, green: 0.494, blue: 0.451) : Color(red: 0.910, green: 0.949, blue: 0.925))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
