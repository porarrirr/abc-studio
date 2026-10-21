import SwiftUI
import UniformTypeIdentifiers

/// Shared colors keep the workspace, editor and sheets visually consistent.
enum StudioTheme {
    static let background = Color(red: 0.957, green: 0.961, blue: 0.973)
    static let surface = Color.white
    static let ink = Color(red: 0.102, green: 0.125, blue: 0.180)
    static let secondary = Color(red: 0.400, green: 0.435, blue: 0.506)
    static let line = Color(red: 0.882, green: 0.898, blue: 0.925)
    static let accent = Color(red: 0.251, green: 0.357, blue: 0.780)
    static let accentSoft = Color(red: 0.922, green: 0.937, blue: 0.996)
    static let danger = Color(red: 0.737, green: 0.231, blue: 0.263)
    static let trackColors: [Color] = [accent, Color(red: 0.235, green: 0.525, blue: 0.490),
                                      Color(red: 0.686, green: 0.435, blue: 0.267),
                                      Color(red: 0.557, green: 0.380, blue: 0.671)]
}

private enum StudioTab: Int, CaseIterable {
    case score, mixer, editor, library
    var title: String {
        switch self {
        case .score: return "楽譜"
        case .mixer: return "ミキサー"
        case .editor: return "エディタ"
        case .library: return "ライブラリ"
        }
    }
    var accessibilityLabel: String {
        switch self {
        case .mixer: return "楽器・音量"
        case .editor: return "ABCを編集"
        default: return title
        }
    }
    var icon: String {
        switch self {
        case .score: return "music.note.list"
        case .mixer: return "slider.horizontal.3"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .library: return "square.stack.3d.up"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: StudioModel
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @State private var showHeadphoneTuning = false
    @State private var tab: StudioTab = .score
    @State private var visitedTabs: Set<StudioTab> = [.score]
    @State private var speedDrag: Double?
    @State private var showAbout = false
    @State private var showPlaybackSettings = false
    @State private var showExport = false
    @State private var pendingExport: (() -> Void)?
    @State private var showClearConfirm = false
    @State private var keyboardVisible = false
    @State private var editorPasteRequest = 0
    @State private var showEditorHelp = false
    @State private var showEditorDiagnostics = false
    @State private var pendingEditorDiagnostic: ABCDiagnostic?
    @State private var renamingItem: LibraryItem?
    @State private var renameText = ""
    @State private var deletingItem: LibraryItem?
    @State private var librarySearch = ""
    @AppStorage("scoreZoom") private var scoreZoom = 1.0
    @AppStorage("scoreFollowEnabled") private var followEnabled = true
    private let abcType = UTType("jp.porari.abc") ?? .plainText
    private var isCompact: Bool { hSize == .compact }
    private var isShort: Bool { vSize == .compact }
    private var hasSource: Bool {
        model.source.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            if !isCompact { sidebar }
            VStack(spacing: 0) {
                if tab != .editor || !keyboardVisible { header }
                paneContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !keyboardVisible {
                    VStack(spacing: 0) {
                        if tab != .editor { playerBar }
                        if isCompact { bottomNavigation }
                    }
                    .background(StudioTheme.surface)
                }
            }
        }
        .background(StudioTheme.background.ignoresSafeArea())
        .foregroundStyle(StudioTheme.ink)
        .tint(StudioTheme.accent)
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { toastOverlay }
        .overlay { if model.isRendering { renderingOverlay } }
        .overlay(alignment: .top) {
            if model.isOpening {
                ProgressView("曲を準備中")
                    .padding(12).background(.regularMaterial, in: Capsule())
                    .padding(.top, 60).allowsHitTesting(false)
                    .accessibilityIdentifier("document-opening")
            }
        }
        .fileImporter(isPresented: $model.showImporter,
                      allowedContentTypes: [abcType, .plainText], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.importFileForDisplay(url); tab = .score }
            case .failure(let error): model.importError = error.localizedDescription
            }
        }
        .sheet(item: $model.shareFile) { ShareSheet(items: [$0.url]) }
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $showPlaybackSettings) { playbackSettings }
        .sheet(isPresented: $showEditorHelp) {
            NavigationStack {
                ScrollView {
                    Text("X: 曲番号　T: 曲名　M: 拍子\nL: 基本音長　K: 調　V: パート\n\n例：C D E F | G A B c |")
                        .font(.system(size: 14, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
                .navigationTitle("ABC記譜法のヒント")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { showEditorHelp = false }
                } }
            }
        }
        .sheet(isPresented: $showEditorDiagnostics, onDismiss: {
            if let diagnostic = pendingEditorDiagnostic {
                pendingEditorDiagnostic = nil
                model.jump(to: diagnostic)
            }
        }) {
            NavigationStack {
                ScrollView { diagnosticsPanel.padding(16) }
                    .navigationTitle("記譜のチェック")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("閉じる") { showEditorDiagnostics = false }
                    } }
            }
        }
        .sheet(isPresented: $showExport, onDismiss: {
            let action = pendingExport
            pendingExport = nil
            action?()
        }) { exportSheet }
        .alert("読み込みエラー", isPresented: Binding(
            get: { model.importError != nil }, set: { if !$0 { model.importError = nil } }
        )) {
            Button("コピー") { UIPasteboard.general.string = model.importError; model.importError = nil }
            Button("閉じる", role: .cancel) { model.importError = nil }
        } message: { Text(model.importError ?? "") }
        .alert("入力内容を削除", isPresented: $showClearConfirm) {
            Button("すべて削除", role: .destructive) { model.clearSource() }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("エディタの ABC テキストをすべて削除します。楽譜に反映済みの内容は変わりません。") }
        .alert("名前を変更", isPresented: Binding(
            get: { renamingItem != nil }, set: { if !$0 { renamingItem = nil } }
        )) {
            TextField("名前", text: $renameText)
            Button("保存") {
                if let item = renamingItem { model.renameLibraryItem(item, to: renameText) }
                renamingItem = nil
            }
            Button("キャンセル", role: .cancel) { renamingItem = nil }
        }
        .alert("ライブラリから削除", isPresented: Binding(
            get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } }
        )) {
            Button("削除", role: .destructive) {
                if let item = deletingItem { model.deleteLibraryItem(item) }
                deletingItem = nil
            }
            Button("キャンセル", role: .cancel) { deletingItem = nil }
        } message: { Text("「\(deletingItem?.name ?? "")」を削除します。この操作は取り消せません。") }
        .onAppear { model.restore() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .onChange(of: tab) { _, selected in
            visitedTabs.insert(selected)
            dismissKeyboard()
        }
        .focusable(tab == .score || tab == .mixer)
        .onKeyPress(.space) {
            guard tab == .score || tab == .mixer else { return .ignored }
            model.togglePlay(); return .handled
        }
        .onKeyPress(.leftArrow) {
            guard tab == .score || tab == .mixer else { return .ignored }
            model.seek(to: max(0, model.engine.progress - 0.02)); return .handled
        }
        .onKeyPress(.rightArrow) {
            guard tab == .score || tab == .mixer else { return .ignored }
            model.seek(to: min(1, model.engine.progress + 0.02)); return .handled
        }
    }

    // MARK: Navigation

    private var header: some View {
        HStack(spacing: 12) {
            if isCompact {
                Image(systemName: "waveform.path")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(StudioTheme.accent)
                Text("ABC Studio")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
            } else {
                Label(tab.title, systemImage: tab.icon)
                    .font(.system(size: 17, weight: .semibold))
            }
            Spacer(minLength: 0)
            Menu {
                Button { model.showImporter = true } label: { Label("ファイルから読み込む", systemImage: "folder") }
                Button { model.importPaste(); tab = .score } label: { Label("クリップボードから読み込む", systemImage: "doc.on.clipboard") }
                if !model.samples.isEmpty {
                    Menu("サンプルを開く", systemImage: "music.note") {
                        ForEach(model.samples, id: \.url) { sample in
                            Button(sample.name) { model.loadSampleForDisplay(sample.url); tab = .score }
                        }
                    }
                }
            } label: {
                Label("読み込む", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 13)
                    .frame(minHeight: 44)
                    .background(StudioTheme.accentSoft, in: Capsule())
                    .foregroundStyle(StudioTheme.accent)
            }
            .accessibilityLabel("ABCを読み込む")
            Menu {
                Button { model.saveToLibrary() } label: { Label("現在の曲をライブラリに保存", systemImage: "bookmark") }
                    .disabled(!hasSource)
                Button { showExport = true } label: { Label("書き出し・共有", systemImage: "square.and.arrow.up") }
                    .disabled(model.tune == nil)
                Divider()
                Button { showAbout = true } label: { Label("このアプリについて", systemImage: "info.circle") }
            } label: { Image(systemName: "ellipsis").font(.system(size: 20)).frame(width: 44, height: 44) }
                .accessibilityLabel("メニュー")
        }
        .padding(.horizontal, isCompact ? 20 : 28)
        .frame(minHeight: isShort ? 48 : 64)
        .background(StudioTheme.surface)
        .overlay(alignment: .bottom) { Divider().overlay(StudioTheme.line) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path").font(.system(size: 26, weight: .semibold)).foregroundStyle(StudioTheme.accent)
                Text("ABC Studio").font(.system(size: 22, weight: .bold, design: .rounded))
            }
            .padding(.top, 24)
            VStack(spacing: 6) {
                ForEach(StudioTab.allCases, id: \.rawValue) { item in
                    Button { tab = item } label: {
                        HStack(spacing: 14) {
                            Image(systemName: item.icon).frame(width: 24)
                            Text(item.title).font(.system(size: 15, weight: .semibold))
                            Spacer()
                        }
                        .padding(15)
                        .foregroundStyle(tab == item ? StudioTheme.accent : StudioTheme.secondary)
                        .background(tab == item ? StudioTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .accessibilityLabel(item.accessibilityLabel)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "music.quarternote.3").font(.system(size: 24)).foregroundStyle(StudioTheme.accent)
                Text("楽譜を、音に。").font(.system(size: 16, weight: .semibold))
                Text("読む。聴く。つくる。\nあなたの音楽のワークスペース。")
                    .font(.system(size: 12)).lineSpacing(5).foregroundStyle(StudioTheme.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioTheme.background, in: RoundedRectangle(cornerRadius: 16))
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 16)
        .frame(width: 236)
        .background(StudioTheme.surface)
        .overlay(alignment: .trailing) { Divider() }
    }

    private var bottomNavigation: some View {
        HStack(spacing: 0) {
            ForEach(StudioTab.allCases, id: \.rawValue) { item in
                Button { tab = item } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 20, weight: tab == item ? .semibold : .regular))
                            .frame(width: 54, height: 28)
                            .background(tab == item ? StudioTheme.accentSoft : .clear, in: Capsule())
                        if !isShort { Text(item.title).font(.system(size: 10, weight: tab == item ? .bold : .medium)) }
                    }
                    .foregroundStyle(tab == item ? StudioTheme.accent : StudioTheme.secondary)
                    .frame(maxWidth: .infinity, minHeight: isShort ? 40 : 60)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(item.accessibilityLabel)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .overlay(alignment: .top) { Divider().overlay(StudioTheme.line) }
    }

    private var paneContent: some View {
        ZStack {
            ForEach(StudioTab.allCases, id: \.rawValue) { item in
                if visitedTabs.contains(item) || tab == item {
                    pane(item)
                        .opacity(tab == item ? 1 : 0)
                        .allowsHitTesting(tab == item)
                        .accessibilityHidden(tab != item)
                        .disabled(tab != item)
                        .zIndex(tab == item ? 1 : 0)
                }
            }
        }
    }

    @ViewBuilder private func pane(_ item: StudioTab) -> some View {
        switch item {
        case .score: scorePane
        case .mixer: partsPane
        case .editor: sourcePane
        case .library: libraryPane
        }
    }

    // MARK: Score

    private var scorePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isShort {
                HStack(spacing: 12) {
                    Text(model.title).font(.system(size: 19, weight: .bold)).lineLimit(1)
                    Spacer(minLength: 0)
                    zoomControl
                    followControl
                    Button { showExport = true } label: {
                        Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                    }.accessibilityLabel("書き出し・共有").disabled(model.tune == nil)
                }.padding(.horizontal, 20).padding(.vertical, 6)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        eyebrow("SCORE", detail: "楽譜")
                        Text(model.title)
                            .font(.system(size: isCompact ? 25 : 32, weight: .bold))
                            .lineLimit(2).minimumScaleFactor(0.8)
                        Text(model.subtitle)
                            .font(.system(size: 12)).foregroundStyle(StudioTheme.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button { showExport = true } label: {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                            .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(model.tune == nil)
                    .accessibilityLabel("書き出し・共有")
                }
                .padding(.horizontal, isCompact ? 22 : 28).padding(.top, 24).padding(.bottom, 18)

                HStack(spacing: 8) {
                    Label(model.tune.map { "\($0.meter.display) · ♩ = \(Int($0.tempo.quarterNoteBPM.rounded()))" } ?? "楽譜の表示", systemImage: "music.note")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(StudioTheme.secondary)
                    Spacer(minLength: 0)
                    zoomControl
                    followControl
                }
                .padding(.horizontal, isCompact ? 20 : 28).padding(.bottom, 12)
            }

            if let book = model.book, book.tunes.count > 1 {
                Picker("曲を選択", selection: Binding(get: { model.selectedTune }, set: { model.selectTuneForDisplay($0) })) {
                    ForEach(book.tunes.indices, id: \.self) { i in
                        Text(book.tunes[i].title.isEmpty ? "曲 \(i + 1)" : book.tunes[i].title).tag(i)
                    }
                }
                .pickerStyle(.menu).padding(.horizontal, 16).padding(.bottom, 6)
            }

            if let tune = model.tune {
                PlaybackScore(tune: tune, cursor: model.playbackCursor,
                              isPlaying: model.engine.isPlaying, zoom: $scoreZoom,
                              followEnabled: followEnabled, isActive: tab == .score,
                              onTapNote: { model.seekToElement($0) })
                    .allowsHitTesting(!model.isOpening)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioTheme.line.opacity(0.8)))
                    .padding(.horizontal, isCompact ? 12 : 28)
                    .padding(.bottom, 12)
            } else {
                emptyState(icon: "music.note", title: "音楽をはじめよう", message: "ABCファイルを読み込むか、\nライブラリのサンプルを開いてみましょう。") {
                    Button("ライブラリを開く") { tab = .library }.buttonStyle(StudioActionStyle())
                }
            }
        }
    }

    private var followControl: some View {
        Button { followEnabled.toggle() } label: {
            Image(systemName: followEnabled ? "location.fill" : "location.slash")
                .font(.system(size: 15)).frame(width: 44, height: 44)
                .foregroundStyle(followEnabled ? StudioTheme.accent : StudioTheme.secondary)
                .background(followEnabled ? StudioTheme.accentSoft : StudioTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel("自動追従").accessibilityValue(followEnabled ? "オン" : "オフ")
    }

    private var zoomControl: some View {
        HStack(spacing: 0) {
            Button { setZoom(scoreZoom - 0.1) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }
                .accessibilityLabel("縮小").disabled(scoreZoom <= ScoreView.minZoom)
            Button { setZoom(1) } label: {
                Text("\(Int((scoreZoom * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).frame(minWidth: 38, minHeight: 44)
            }.accessibilityLabel("表示倍率をリセット")
            Button { setZoom(scoreZoom + 0.1) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                .accessibilityLabel("拡大").disabled(scoreZoom >= ScoreView.maxZoom)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(StudioTheme.secondary)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func setZoom(_ value: Double) {
        scoreZoom = min(ScoreView.maxZoom, max(ScoreView.minZoom, (value * 20).rounded() / 20))
    }

    // MARK: Mixer

    private var partsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeading("MIXER", title: "音のバランスを、自在に。", description: "指揮者の位置から、楽器の広がりと奥行きを。")
                masterVolumeCard
                stageCard
                HStack {
                    Text("パート").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(model.tune?.voices.count ?? 0) トラック").font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
                }
                if let tune = model.tune, !tune.voices.isEmpty {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(tune.voices.enumerated()), id: \.element.id) { index, voice in
                            partRow(voice: voice, index: index)
                        }
                    }
                } else {
                    Text("楽譜を読み込むと、ここにパートが表示されます。")
                        .font(.system(size: 14)).foregroundStyle(StudioTheme.secondary)
                }
                Label("配置は指を離すと反映。音色を変えると再生は停止します。", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
                DisclosureGroup("合唱・ドラムの音色について") {
                    Text("合唱は Choir Aahs 音色です。歌詞の発声には対応していません。ドラムは General MIDI の打楽器配置を使います。")
                        .font(.system(size: 12)).foregroundStyle(StudioTheme.secondary).padding(.top, 8)
                }.font(.system(size: 12))
            }
            .padding(isCompact ? 22 : 28)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
    }

    private var stageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("楽器の配置").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("標準配置に戻す") { model.resetStagePositions() }
                    .font(.system(size: 12)).accessibilityIdentifier("reset-stage")
            }
            Button {
                model.prepareHeadphoneAudition()
                showHeadphoneTuning = true
            } label: {
                Label("イヤホンの定位を調整 · " + model.headphoneSettings.profile.label, systemImage: "earbuds")
                    .font(.system(size: 13, weight: .medium))
            }.accessibilityIdentifier("headphone-tuning")
                .sheet(isPresented: $showHeadphoneTuning) { HeadphoneTuningView(model: model) }
            Text("米式配置 · 左右は指揮者から見た向きです")
                .font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(StudioTheme.background)
                    VStack {
                        Text("舞台奥").font(.system(size: 11))
                        Spacer()
                        HStack { Text("左"); Spacer(); Label("指揮者・聴く位置", systemImage: "person.fill"); Spacer(); Text("右") }
                            .font(.system(size: 11))
                    }.foregroundStyle(StudioTheme.secondary).padding(10)
                    ForEach(stageMarkers(width: geometry.size.width)) { marker in
                        Text(marker.numbers)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white).padding(.horizontal, 8).frame(minWidth: 28, minHeight: 28)
                            .background(StudioTheme.trackColors[marker.id % StudioTheme.trackColors.count], in: Capsule())
                            .position(marker.point)
                            .accessibilityLabel(marker.names + "の配置")
                    }
                }
            }.frame(height: 210)
            Text("近い位置の番号はまとめて表示します。各パートの「配置」で調整できます。ステレオのイヤホンで左右・奥行きを確認してください。")
                .font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
        }.studioCard()
    }

    private struct StageMarker: Identifiable {
        let id: Int
        var point: CGPoint
        var numbers: String
        var names: String
        var count: Int
    }

    private func stageMarkers(width: CGFloat) -> [StageMarker] {
        var markers: [StageMarker] = []
        for (index, voice) in (model.tune?.voices ?? []).enumerated() {
            let position = model.stagePosition(for: voice)
            let point = CGPoint(x: 24 + (position.x + 1) / 2 * max(0, width - 48),
                                y: 38 + (1 - position.depth) * 132)
            if let nearby = markers.firstIndex(where: {
                hypot($0.point.x - point.x, $0.point.y - point.y) < 34
            }) {
                let count = CGFloat(markers[nearby].count)
                markers[nearby].point = CGPoint(x: (markers[nearby].point.x * count + point.x) / (count + 1),
                                               y: (markers[nearby].point.y * count + point.y) / (count + 1))
                markers[nearby].numbers += " · \(index + 1)"
                markers[nearby].names += "、" + voice.name
                markers[nearby].count += 1
            } else {
                markers.append(StageMarker(id: index, point: point, numbers: "\(index + 1)", names: voice.name, count: 1))
            }
        }
        return markers
    }

    private var masterVolumeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 19)).foregroundStyle(StudioTheme.accent)
                    .frame(width: 44, height: 44).background(StudioTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("マスター音量").font(.system(size: 15, weight: .semibold))
                    Text("すべてのパートに適用").font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
                Text("\(Int((model.masterVolume * 100).rounded()))%")
                    .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Slider(value: Binding(get: { model.masterVolume }, set: { model.setMasterVolume($0) }), in: 0...1)
                .accessibilityLabel("マスター音量")
        }.studioCard()
    }

    private func partRow(voice: ABCVoice, index: Int) -> some View {
        MixerPartRow(model: model, voice: voice, index: index,
                     instrumentID: model.assignments[voice.id] ?? "piano",
                     volume: model.partVolume(for: voice.id),
                     position: model.stagePosition(for: voice),
                     muted: model.mutedVoices.contains(voice.id),
                     soloed: model.soloVoiceID == voice.id)
            .equatable()
    }

    // MARK: Editor

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("ABC ソース", systemImage: "doc.plaintext").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(model.sourceLineCount) 行")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioTheme.secondary)
                Button { editorPasteRequest += 1 } label: {
                    Label("貼り付け", systemImage: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(minHeight: 44)
                }
                .foregroundStyle(StudioTheme.accent)
                .accessibilityIdentifier("editor-paste")
                .accessibilityHint("クリップボードのテキストをカーソル位置に貼り付けます")
                Menu {
                    Button { model.validateSource(); dismissKeyboard() } label: { Label("記譜を検証", systemImage: "checkmark.circle") }
                    Button { dismissKeyboard(); showEditorHelp = true } label: { Label("ABC記譜法のヒント", systemImage: "questionmark.circle") }
                    Button(role: .destructive) { showClearConfirm = true } label: { Label("入力内容をすべて削除", systemImage: "trash") }
                        .disabled(!hasSource)
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .accessibilityLabel("エディタの操作")
            }
            .padding(.horizontal, 14).background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 12))

            SourceEditor(text: Binding(get: { model.source }, set: { model.source = $0; model.scheduleValidation() }),
                         jumpToLine: $model.jumpToLine, isActive: tab == .editor,
                         pasteRequest: editorPasteRequest,
                         onPasteUnavailable: { model.toast("クリップボードにテキストがありません") })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioTheme.line))
            if !keyboardVisible {
                HStack(spacing: 12) {
                    if model.diagnostics.isEmpty {
                        Label("下書きは自動保存", systemImage: "checkmark.circle")
                            .font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
                    } else {
                        Button {
                            dismissKeyboard()
                            showEditorDiagnostics = true
                        } label: {
                            Label("チェック \(model.diagnostics.count) 件", systemImage: "exclamationmark.circle")
                                .font(.system(size: 12, weight: .semibold)).frame(minHeight: 44)
                        }
                        .foregroundStyle(StudioTheme.danger)
                    }
                    Spacer(minLength: 0)
                    Button {
                        dismissKeyboard()
                        model.applySourceForDisplay { success in
                            if success { tab = .score }
                        }
                    } label: { Label("楽譜に反映", systemImage: "arrow.right") }
                        .buttonStyle(StudioActionStyle()).disabled(!hasSource || model.isOpening)
                }
            }
        }
        .padding(.horizontal, isCompact ? 12 : 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("記譜のチェック · \(model.diagnostics.count) 件", systemImage: "exclamationmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("コピー") {
                    UIPasteboard.general.string = "ABC Studio 診断結果\n" + model.diagnosticText()
                    model.toast("診断結果をコピーしました")
                }.font(.system(size: 12, weight: .semibold))
            }
            ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Button {
                    pendingEditorDiagnostic = diagnostic
                    showEditorDiagnostics = false
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: diagnostic.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(diagnostic.severity == .error ? StudioTheme.danger : Color.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(diagnostic.severity == .error ? "エラー" : "警告") · \(diagnostic.line) 行目")
                                .font(.system(size: 11, weight: .semibold))
                            Text(diagnostic.message).font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
                            if !diagnostic.context.isEmpty {
                                Text(diagnostic.context).font(.system(size: 11, design: .monospaced)).lineLimit(2).foregroundStyle(StudioTheme.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle())
                }
            }
        }.studioCard()
    }

    // MARK: Library

    private var filteredLibrary: [LibraryItem] {
        model.libraryItems.filter { librarySearch.isEmpty || $0.name.localizedStandardContains(librarySearch) }
    }

    private var libraryPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeading("YOUR LIBRARY", title: "音楽が集まる場所。", description: "お気に入りの楽譜を、いつでも手元に。")
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(StudioTheme.secondary)
                    TextField("保存した曲を検索", text: $librarySearch).font(.system(size: 14)).submitLabel(.search)
                        .accessibilityIdentifier("library-search")
                        .onSubmit { dismissKeyboard() }
                    if !librarySearch.isEmpty {
                        Button { librarySearch = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(StudioTheme.secondary).frame(width: 44, height: 44) }
                            .accessibilityLabel("検索をクリア")
                    }
                }
                .padding(.horizontal, 14).frame(minHeight: 48)
                .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                if hasSource && librarySearch.isEmpty { saveCurrentCard }
                HStack {
                    Text("保存した曲").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("\(model.libraryItems.count) 曲").font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
                }
                if filteredLibrary.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: librarySearch.isEmpty ? "square.stack.3d.up" : "magnifyingglass")
                            .font(.system(size: 28, weight: .light)).foregroundStyle(StudioTheme.accent)
                        Text(librarySearch.isEmpty ? "あなたの楽譜棚をつくろう" : "曲が見つかりません")
                            .font(.system(size: 15, weight: .semibold))
                        Text(librarySearch.isEmpty ? "上の「保存」で、開いている曲を追加できます。" : "別の曲名で検索してみてください。")
                            .font(.system(size: 12)).foregroundStyle(StudioTheme.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    LazyVStack(spacing: 10) { ForEach(filteredLibrary) { libraryRow($0) } }
                }
                if librarySearch.isEmpty && !model.samples.isEmpty {
                    Divider().padding(.vertical, 2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("まずは、聴いてみよう。").font(.system(size: 18, weight: .semibold))
                        Text("すぐに試せるサンプル楽譜").font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                        ForEach(Array(model.samples.enumerated()), id: \.element.url) { index, sample in
                            Button { model.loadSampleForDisplay(sample.url); tab = .score } label: {
                                VStack(alignment: .leading, spacing: 18) {
                                    Image(systemName: index.isMultiple(of: 2) ? "music.note" : "pianokeys")
                                        .font(.system(size: 24, weight: .light)).foregroundStyle(StudioTheme.accent)
                                    HStack(alignment: .bottom) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(sample.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                            Text("サンプルを開く").font(.system(size: 10)).foregroundStyle(StudioTheme.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(StudioTheme.accent)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).studioCard()
                            }
                        }
                    }
                }
            }
            .padding(isCompact ? 22 : 28).frame(maxWidth: 960).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var saveCurrentCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 24)).foregroundStyle(StudioTheme.accent)
                .frame(width: 50, height: 58).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text("開いている曲").font(.system(size: 10, weight: .medium)).foregroundStyle(StudioTheme.secondary)
                Text(model.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { model.saveToLibrary() } label: { Label("保存", systemImage: "plus") }
                .buttonStyle(StudioActionStyle()).accessibilityLabel("現在の曲を保存")
        }
        .padding(16).background(StudioTheme.accentSoft, in: RoundedRectangle(cornerRadius: 18))
    }

    private func libraryRow(_ item: LibraryItem) -> some View {
        HStack(spacing: 10) {
            Button { model.openLibraryItemForDisplay(item); tab = .score } label: {
                HStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: 20)).foregroundStyle(StudioTheme.accent)
                        .frame(width: 44, height: 52).background(StudioTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        Text(item.createdAt.formatted(date: .abbreviated, time: .omitted) + " · \(item.tuneCount) 曲")
                            .font(.system(size: 10)).foregroundStyle(StudioTheme.secondary)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            Button { model.openLibraryItemForDisplay(item, play: true); tab = .score } label: {
                Image(systemName: "play.fill").font(.system(size: 15)).foregroundStyle(StudioTheme.accent).frame(width: 44, height: 44)
            }.accessibilityLabel(item.name + "を再生")
            Menu { libraryActions(item) } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(StudioTheme.secondary) }
                .accessibilityLabel(item.name + "の操作")
        }
        .padding(12).background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .contextMenu { libraryActions(item) }
    }

    @ViewBuilder private func libraryActions(_ item: LibraryItem) -> some View {
        Button { model.openLibraryItemForDisplay(item); tab = .score } label: { Label("開く", systemImage: "doc.text.magnifyingglass") }
        Button { model.openLibraryItemForDisplay(item, play: true); tab = .score } label: { Label("再生", systemImage: "play") }
        Button { renameText = item.name; renamingItem = item } label: { Label("名前を変更", systemImage: "pencil") }
        Button(role: .destructive) { deletingItem = item } label: { Label("削除", systemImage: "trash") }
    }

    // MARK: Player

    private var playerBar: some View {
        PlaybackBar(model: model, engine: model.engine, isCompact: isCompact,
                    isShort: isShort, showPlaybackSettings: $showPlaybackSettings)
    }

    private var playbackSettings: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Label("再生速度", systemImage: "speedometer").font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Text("\(Int(speedDrag ?? Double(model.speed)))%")
                                .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                        Slider(value: Binding(get: { speedDrag ?? Double(model.speed) }, set: { speedDrag = $0 }), in: 50...200, step: 5,
                               onEditingChanged: { editing in
                                   if !editing, let value = speedDrag { model.setSpeed(Int(value)) }
                                   if !editing { speedDrag = nil }
                               }).accessibilityLabel("再生速度")
                        HStack(spacing: 8) {
                            ForEach([50, 75, 100, 125, 150], id: \.self) { speed in
                                Button { speedDrag = nil; model.setSpeed(speed) } label: {
                                    Text("\(speed)%").font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                                        .foregroundStyle(model.speed == speed ? .white : StudioTheme.secondary)
                                        .background(model.speed == speed ? StudioTheme.accent : StudioTheme.background, in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                        Text("ゆっくり確かめたり、いつものテンポで聴いたり。")
                            .font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
                    }.studioCard()
                    Toggle(isOn: $model.loopEnabled) { Label("ループ再生", systemImage: "repeat").font(.system(size: 15, weight: .medium)) }
                        .studioCard()
                    masterVolumeCard
                    stageCard
                }.padding(22)
            }
            .background(StudioTheme.background)
            .navigationTitle("再生設定").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { showPlaybackSettings = false } } }
        }
        .tint(StudioTheme.accent)
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private var exportSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(model.title).font(.system(size: 22, weight: .bold)).padding(.top, 8)
                    Text("使いたい形式を選んで、保存・共有できます。")
                        .font(.system(size: 13)).foregroundStyle(StudioTheme.secondary)
                    VStack(spacing: 0) {
                        exportRow("PDF", detail: "印刷や配布に", icon: "doc.richtext") { model.shareScorePDF() }
                        Divider().padding(.leading, 64)
                        exportRow("PNG 画像", detail: "楽譜を画像で共有", icon: "photo") { model.shareScorePNG() }
                        Divider().padding(.leading, 64)
                        exportRow("MIDI", detail: "音楽制作アプリへ", icon: "pianokeys") { model.shareMIDI() }
                        Divider().padding(.leading, 64)
                        exportRow("WAV 音声", detail: "演奏をオーディオに", icon: "waveform") { model.shareAudio() }
                        Divider().padding(.leading, 64)
                        exportRow("ABC テキスト", detail: "記譜のソースを保存", icon: "chevron.left.forwardslash.chevron.right") { model.shareSource() }
                    }.background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                }.padding(22)
            }
            .background(StudioTheme.background)
            .navigationTitle("書き出し・共有").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showExport = false } } }
        }
        .tint(StudioTheme.accent).presentationDetents([.large]).presentationDragIndicator(.visible)
    }

    private func exportRow(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            // Present sharing only once the export sheet has finished dismissing.
            pendingExport = action
            showExport = false
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(StudioTheme.accent).frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
            }.padding(18).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.isRendering)
    }

    // MARK: Shared presentation

    private func eyebrow(_ text: String, detail: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(text).tracking(2)
            if let detail { Rectangle().fill(StudioTheme.line).frame(width: 16, height: 1); Text(detail) }
        }.font(.system(size: 10, weight: .bold)).foregroundStyle(StudioTheme.accent)
    }

    private func pageHeading(_ eyebrowText: String, title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            eyebrow(eyebrowText)
            Text(title).font(.system(size: isCompact ? 23 : 29, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            Text(description).font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
        }.padding(.top, 4).padding(.bottom, 4)
    }

    private func emptyState<Actions: View>(icon: String, title: String, message: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: icon).font(.system(size: 42, weight: .light)).foregroundStyle(StudioTheme.accent)
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(message).font(.system(size: 13)).foregroundStyle(StudioTheme.secondary).multilineTextAlignment(.center).lineSpacing(5)
            actions()
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity).padding(24)
    }

    private var toastOverlay: some View {
        Group {
            if let text = model.toastText {
                Label(text, systemImage: "info.circle.fill")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(16).background(StudioTheme.ink, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
                    .padding(.horizontal, 22).padding(.bottom, keyboardVisible ? 20 : (isCompact ? 180 : 120))
                    .transition(.move(edge: .bottom).combined(with: .opacity)).allowsHitTesting(false)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }.animation(.easeInOut(duration: 0.2), value: model.toastText != nil)
    }

    private var renderingOverlay: some View {
        ZStack {
            StudioTheme.ink.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 18) {
                ProgressView().tint(StudioTheme.accent)
                Text("音声を書き出し中…").font(.system(size: 16, weight: .semibold))
                Text("演奏をWAVファイルに変換しています。")
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
                Button("キャンセル", role: .cancel) { model.cancelRender() }
                    .buttonStyle(StudioActionStyle(primary: false)).accessibilityLabel("書き出しをキャンセル")
            }.padding(28).background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 24)).padding(24)
        }.accessibilityAddTraits(.isModal)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct StudioActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var primary = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(primary ? .white : StudioTheme.accent)
            .padding(.horizontal, 16).frame(minHeight: 44)
            .background(primary ? StudioTheme.accent : StudioTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.75 : 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private extension View {
    func studioCard() -> some View {
        padding(18)
            .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(StudioTheme.line.opacity(0.5)))
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

    private func licenseText(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "ライセンス文書を読み込めませんでした。公開リポジトリのライセンスをご確認ください。"
        }
        return text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform.path")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(StudioTheme.accent)
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
                    VStack(alignment: .leading, spacing: 10) {
                        Link("サポート", destination: URL(string: "https://porarrirr.github.io/abc-studio/support.html")!)
                        Link("プライバシーポリシー", destination: URL(string: "https://porarrirr.github.io/abc-studio/privacy.html")!)
                        Link("ソースコード（MIT License）", destination: URL(string: "https://github.com/porarrirr/abc-studio")!)
                        Link("お問い合わせ: musicabc@rarari.org", destination: URL(string: "mailto:musicabc@rarari.org")!)
                    }
                    .font(.system(size: 13))
                    DisclosureGroup("アプリのライセンス（MIT）") {
                        Text(licenseText("App-LICENSE"))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text("イヤホン用実測データ: CIPIC © 2001 The Regents of the University of California")
                    DisclosureGroup("CIPIC の利用条件") { Text(licenseText("CIPIC-LICENSE")) }
                    Text("楽譜記号: Bravura © Steinberg Media Technologies GmbH(SIL Open Font License 1.1)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    DisclosureGroup("Bravura のライセンス（OFL 1.1）") {
                        Text(licenseText("Bravura-OFL"))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
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

/// Transport progress updates must not rebuild the mixer or navigation tabs.
private struct PlaybackBar: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: PlaybackEngine
    let isCompact: Bool
    let isShort: Bool
    @Binding var showPlaybackSettings: Bool
    @State private var seekDrag: Double?

    @ViewBuilder var body: some View {
        if isShort { compactPlayerBar } else { fullPlayerBar }
    }

    private var compactPlayerBar: some View {
        HStack(spacing: 16) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(StudioTheme.ink, in: RoundedRectangle(cornerRadius: 14))
            }.accessibilityLabel(model.engine.isPlaying ? "一時停止" : "再生")
                .disabled(model.tune == nil || (model.isOpening && !model.engine.isPlaying))
            Button { model.stopPlayback() } label: {
                Image(systemName: "stop.fill").frame(width: 44, height: 44)
            }.accessibilityLabel("停止").disabled(model.tune == nil)
            Text(model.status).font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
            Text(model.currentTimeText).font(.system(size: 10, design: .monospaced))
            Slider(value: Binding(get: { seekDrag ?? model.engine.progress }, set: { seekDrag = $0 }), in: 0...1,
                   onEditingChanged: { editing in
                       if !editing, let value = seekDrag { model.seek(to: value) }
                       if !editing { seekDrag = nil }
                   }).accessibilityLabel("再生位置").disabled(model.tune == nil || model.isOpening)
            Text(model.totalTimeText).font(.system(size: 10, design: .monospaced))
            Button { showPlaybackSettings = true } label: {
                Text("\(model.speed)%").font(.system(size: 12, weight: .semibold)).frame(minWidth: 50, minHeight: 44)
            }.accessibilityLabel("再生設定").accessibilityValue("速度 \(model.speed)%")
        }
        .padding(.horizontal, 22).padding(.vertical, 6)
        .background(StudioTheme.surface).overlay(alignment: .top) { Divider() }
    }

    private var fullPlayerBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(model.engine.isPlaying ? StudioTheme.accent : StudioTheme.secondary.opacity(0.6)).frame(width: 5, height: 5)
                        Text(model.status).font(.system(size: 10)).foregroundStyle(StudioTheme.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button { showPlaybackSettings = true } label: {
                    Text("\(model.speed)%").font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(StudioTheme.accent).frame(minWidth: 48, minHeight: 44)
                        .background(StudioTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                }.accessibilityLabel("再生設定").accessibilityValue("速度 \(model.speed)%")
                Button { model.stopPlayback() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 15)).foregroundStyle(StudioTheme.secondary).frame(width: 44, height: 48)
                }.accessibilityLabel("停止").disabled(model.tune == nil)
                Button { model.togglePlay() } label: {
                    Image(systemName: model.engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(StudioTheme.ink, in: RoundedRectangle(cornerRadius: 17))
                }.accessibilityLabel(model.engine.isPlaying ? "一時停止" : "再生")
                .disabled(model.tune == nil || (model.isOpening && !model.engine.isPlaying))
            }
            HStack(spacing: 10) {
                Text(model.currentTimeText).frame(width: 32, alignment: .leading)
                Slider(value: Binding(get: { seekDrag ?? model.engine.progress }, set: { seekDrag = $0 }), in: 0...1,
                       onEditingChanged: { editing in
                           if !editing, let value = seekDrag { model.seek(to: value) }
                           if !editing { seekDrag = nil }
                       })
                    .accessibilityLabel("再生位置").disabled(model.tune == nil || model.isOpening)
                Text(model.totalTimeText).frame(width: 32, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(StudioTheme.secondary)
        }
        .padding(.horizontal, isCompact ? 22 : 28).padding(.top, 12).padding(.bottom, 2)
        .frame(maxWidth: 1000).frame(maxWidth: .infinity)
        .background(StudioTheme.surface)
        .overlay(alignment: .top) { Divider().overlay(StudioTheme.line) }
    }

}

private struct PlaybackScore: View {
    let tune: ABCTune
    let cursor: PlaybackCursor
    let isPlaying: Bool
    @Binding var zoom: Double
    let followEnabled: Bool
    let isActive: Bool
    let onTapNote: (Int) -> Void
    @State private var highlight: Set<Int> = []
    @State private var cursorID: Int?

    var body: some View {
        ScoreView(tune: tune, highlight: highlight, cursorID: cursorID,
                  isPlaying: isPlaying && isActive, zoom: $zoom, followEnabled: followEnabled,
                  onTapNote: onTapNote, isActive: isActive)
            .onReceive(cursor.$highlight.combineLatest(cursor.$elementID)) { ids, anchor in
                guard isActive else { return }
                if highlight != ids { highlight = ids }
                if cursorID != anchor { cursorID = anchor }
            }
            .onChange(of: isActive) { _, active in
                if active { highlight = cursor.highlight; cursorID = cursor.elementID }
            }
    }
}

/// Snapshot values let unchanged parts skip view rebuilding during a fader drag.
private struct MixerPartRow: View, Equatable {
    let model: StudioModel
    let voice: ABCVoice
    let index: Int
    let instrumentID: String
    let volume: Double
    let position: StagePosition
    let muted: Bool
    let soloed: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.model === b.model && a.voice.id == b.voice.id && a.voice.name == b.voice.name
            && a.index == b.index && a.instrumentID == b.instrumentID
            && a.volume == b.volume && a.position == b.position && a.muted == b.muted && a.soloed == b.soloed
    }

    var body: some View {
        let instrument = Instruments.byID(instrumentID) ?? Instruments.all[0]
        let percent = Int((volume * 100).rounded())
        let color = StudioTheme.trackColors[index % StudioTheme.trackColors.count]
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(color).frame(width: 44, height: 44)
                    .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(voice.name).font(.system(size: 16, weight: .semibold))
                    Text(instrument.category).font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
                }.opacity(muted ? 0.45 : 1)
                Spacer(minLength: 0)
                Button { model.toggleSolo(voice.id) } label: {
                    Text("ソロ").font(.system(size: 11, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(soloed ? .white : StudioTheme.secondary)
                        .background(soloed ? color : StudioTheme.background, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel(voice.name + "をソロ再生").accessibilityValue(soloed ? "オン" : "オフ")
                Button { model.toggleMute(voice.id) } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2")
                        .font(.system(size: 15)).frame(width: 44, height: 44)
                        .foregroundStyle(muted ? StudioTheme.danger : StudioTheme.secondary)
                        .background(muted ? StudioTheme.danger.opacity(0.09) : StudioTheme.background, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel(voice.name + "をミュート").accessibilityValue(muted ? "オン" : "オフ")
            }
            HStack(spacing: 12) {
                Slider(value: Binding(get: { volume },
                                      set: { model.setPartVolume(voice.id, volume: $0) }), in: 0...1)
                    .tint(color).accessibilityLabel(voice.name + "の音量")
                    .accessibilityValue("\(percent)%").accessibilityIdentifier("part-volume-\(voice.id)")
                Text("\(percent)%").font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioTheme.secondary).frame(width: 42, alignment: .trailing).accessibilityHidden(true)
            }
            Divider()
            HStack {
                Text("音色").font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
                Spacer(minLength: 4)
                InstrumentMenu(model: model, voiceID: voice.id, voiceName: voice.name,
                               selection: instrumentID).equatable()
            }
            DisclosureGroup("配置 · 指揮者から見た位置") {
                StagePositionControls(model: model, voiceID: voice.id, voiceName: voice.name,
                                      position: position)
                    .id(position)
            }.font(.system(size: 12)).tint(color)
        }.studioCard()
    }
}

/// Local drafts keep dragging smooth and commit one audio rebuild on release.
private struct StagePositionControls: View {
    let model: StudioModel
    let voiceID: String
    let voiceName: String
    @State private var x: Double
    @State private var depth: Double

    init(model: StudioModel, voiceID: String, voiceName: String, position: StagePosition) {
        self.model = model
        self.voiceID = voiceID
        self.voiceName = voiceName
        _x = State(initialValue: position.x)
        _depth = State(initialValue: position.depth)
    }

    private func commit() {
        model.setStagePosition(voiceID, position: StagePosition(x: x, depth: depth))
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack { Text("左"); Spacer(); Text(abs(x) < 0.025 ? "中央" : "\(x < 0 ? "左" : "右") \(Int(abs(x) * 100))%"); Spacer(); Text("右") }
            Slider(value: $x, in: -1...1, step: 0.05, onEditingChanged: { if !$0 { commit() } })
                .accessibilityLabel(voiceName + "の左右位置").accessibilityIdentifier("stage-x-" + voiceID)
            HStack { Text("手前"); Spacer(); Text("奥行き \(Int(depth * 100))%"); Spacer(); Text("奥") }
            Slider(value: $depth, in: 0...1, step: 0.05, onEditingChanged: { if !$0 { commit() } })
                .accessibilityLabel(voiceName + "の奥行き").accessibilityIdentifier("stage-depth-" + voiceID)
        }.padding(.top, 12).foregroundStyle(StudioTheme.secondary)
    }
}

private struct InstrumentMenu: View, Equatable {
    let model: StudioModel
    let voiceID: String
    let voiceName: String
    let selection: String
    private static let groups = Instruments.categories.map { category in
        (category, Instruments.all.filter { $0.category == category })
    }

    static func == (a: Self, b: Self) -> Bool {
        a.model === b.model && a.voiceID == b.voiceID && a.voiceName == b.voiceName
            && a.selection == b.selection
    }

    var body: some View {
        Picker(voiceName + "の楽器", selection: Binding(
            get: { selection }, set: { model.assign(voiceID, instrument: $0) })) {
            ForEach(Self.groups, id: \.0) { category, instruments in
                Section(category) {
                    ForEach(instruments, id: \.id) { inst in Text(inst.label).tag(inst.id) }
                }
            }
        }
        .pickerStyle(.menu).font(.system(size: 13, weight: .medium))
    }
}
