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
    @State private var tab = 0
    @State private var seekDrag: Double?
    @State private var speedDrag: Double?
    @State private var showAbout = false
    /// Info.plist でエクスポート宣言した独自 UTI(なければプレーンテキスト扱い)
    private let abcType = UTType("jp.porari.abc") ?? .plainText
    private let tabs = ["楽譜", "楽器", "ABCを編集"]

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        intro
                        workspace(scoreHeight: max(330, geo.size.height * 0.52))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 22)
                    .padding(.bottom, 34)
                    .frame(maxWidth: 1240)
                    .frame(maxWidth: .infinity)
                }
            }
        }
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

    // MARK: - イントロ

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR MUSIC, IN MOTION")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.8)
                .foregroundStyle(Color(red: 0.137, green: 0.545, blue: 0.498))
            Text(model.title)
                .font(.system(size: 31, weight: .bold))
                .tracking(-1)
                .foregroundStyle(Color.ink)
            Text(model.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Color.sub)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 20)
    }

    // MARK: - ワークスペース(タブ+ペイン)

    private func workspace(scoreHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            tabBar
            paneContent(scoreHeight: scoreHeight)
                .frame(minHeight: 375)
        }
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color(red: 0.875, green: 0.906, blue: 0.875)))
        .shadow(color: Color(red: 0.125, green: 0.239, blue: 0.212).opacity(0.06), radius: 21, y: 9)
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
    private func paneContent(scoreHeight: CGFloat) -> some View {
        switch tab {
        case 0: scorePane(scoreHeight: scoreHeight)
        case 1: partsPane
        default: sourcePane
        }
    }

    // MARK: - 楽譜ペイン

    private func scorePane(scoreHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("SCORE")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.8)
                    .foregroundStyle(Color(red: 0.137, green: 0.545, blue: 0.498))
                Spacer()
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
                }
                Text("音符タップでシーク · 再生中の音符を追いかけます")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.faint)
            }
            .padding(.horizontal, 16)
            .padding(.top, 17)
            .padding(.bottom, 6)

            if let tune = model.tune {
                ScoreView(tune: tune, highlight: model.highlight, cursorID: model.cursorID,
                          onTapNote: { model.seekToElement($0) })
                    .frame(height: scoreHeight)
                    .padding(.bottom, 8)
            } else {
                Spacer()
                    .frame(minHeight: 300)
            }
        }
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
                        Text("パートごとの音色")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(Color.ink)
                    }
                    Spacer()
                    Text("声部ごとに楽器を選べます。変更は次の再生から反映されます。")
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
        return HStack {
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
            Spacer()
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
            Picker(voice.name + "の楽器", selection: Binding(
                get: { model.assignments[voice.id] ?? "piano" },
                set: { model.assign(voice.id, instrument: $0) })) {
                ForEach(Instruments.all, id: \.id) { inst in
                    Text(inst.label).tag(inst.id)
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
                    .padding(.horizontal, 16)

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
                        }
                    }
                    Text("ABC 記譜法の楽譜表示・再生アプリ。解析・譜面描画・再生はすべてネイティブ実装です。")
                        .font(.system(size: 13))
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
