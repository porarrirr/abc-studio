import SwiftUI
import AVFoundation

/// Scores describe this listener's preference, not a measured localization error.
struct HeadphoneRating: Equatable {
    var direction = 3
    var externalization = 3
    var timbre = 3
}

struct HeadphoneTuningView: View {
    @ObservedObject var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview: PlaybackEngine
    @State private var candidate: HeadphoneSettings
    @State private var drafts: [HeadphoneProfile: HeadphoneRating] = [:]
    @State private var ratings: [HeadphoneProfile: HeadphoneRating] = [:]
    @State private var completed: Set<HeadphoneProfile> = []
    @State private var cue = "左前 → 正面 → 右前 → 手前 → 舞台奥"
    @State private var auditionedSettings: HeadphoneSettings?

    init(model: StudioModel) {
        self.model = model
        _candidate = State(initialValue: model.headphoneSettings)
        let burst = HeadphoneTrial.signal()
        _preview = StateObject(wrappedValue: PlaybackEngine(makePlayerNode: { AVAudioPlayerNode() },
            makeBuffer: { _, _, _, _ in burst }))
    }

    private var rating: Binding<HeadphoneRating> {
        Binding(get: { drafts[candidate.profile] ?? ratings[candidate.profile] ?? HeadphoneRating() },
                set: { drafts[candidate.profile] = $0 })
    }
    private var canRate: Bool { completed.contains(candidate.profile) && !preview.isPlaying }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("耳に合う定位を選ぶ")
                        .font(.title2.bold())
                    Text("耳の形やイヤホンによって合う候補が変わります。同じ音量で聴き比べ、方向・正面の感じ・音色を別々に評価してください。")
                    Text("頭を正面に向けて試してください。この試聴は頭の動きには追従しません。端末側の追加の空間化はオフにすると比較しやすくなります。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("1 · 同じ音で聴き比べる") {
                    Picker("定位の候補", selection: Binding(get: { candidate.profile }, set: { profile in
                        preview.stop()
                        candidate = HeadphoneSettings(profile: profile, room: candidate.room, width: candidate.width)
                        cue = "左前 → 正面 → 右前 → 手前 → 舞台奥"
                    })) {
                        ForEach(HeadphoneProfile.allCases) { profile in Text(profile.label).tag(profile) }
                    }.pickerStyle(.menu).accessibilityIdentifier("headphone-profile")
                    if !HeadphoneHRTF.isAvailable {
                        Text("実測データを読み込めません。従来の定位で再生します。")
                            .foregroundStyle(.red)
                    }
                    Text(cue).font(.headline).accessibilityIdentifier("headphone-cue")
                    Button(preview.isPlaying ? "試聴を止める" : "5方向を試聴する") {
                        if preview.isPlaying { preview.stop() } else { audition() }
                    }.accessibilityIdentifier("headphone-audition")
                    Text("約5秒の同じノイズ音です。手前と舞台奥の違いも確かめてください。試聴中に候補を変えると停止します。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("2 · あなたの感じ方を記録（1〜5）") {
                    Stepper("方向のわかりやすさ：\(rating.wrappedValue.direction)", value: rating.direction, in: 1...5)
                    Stepper("正面・頭の外に感じる：\(rating.wrappedValue.externalization)", value: rating.externalization, in: 1...5)
                    Stepper("音色の自然さ：\(rating.wrappedValue.timbre)", value: rating.timbre, in: 1...5)
                    Button("この候補の評価を記録") {
                        ratings[candidate.profile] = rating.wrappedValue
                    }.disabled(!canRate).accessibilityIdentifier("headphone-rate")
                    Text("試聴を最後まで聴くと記録できます。点数は好みの目安で、定位の正確さを測定した結果ではありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.disabled(!canRate)
                Section("3 · 記録した候補を比較") {
                    ForEach(HeadphoneProfile.allCases.filter { ratings[$0] != nil }) { profile in
                        if let score = ratings[profile] {
                            Button {
                                preview.stop()
                                candidate = HeadphoneSettings(profile: profile, room: candidate.room, width: candidate.width)
                            } label: {
                                HStack {
                                    Text(profile.label)
                                    Spacer()
                                    Text("方向 \(score.direction) / 頭外 \(score.externalization) / 音色 \(score.timbre)")
                                        .font(.caption)
                                    if profile == candidate.profile { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    Text("候補をもう一度聴き、演奏でも確認してください。合計点だけで自動決定しません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("4 · 広がりと部屋を微調整") {
                    Text("舞台の広がり \(Int(candidate.width * 100))%")
                    Slider(value: Binding(get: { candidate.width }, set: {
                        update(HeadphoneSettings(profile: candidate.profile, room: candidate.room, width: $0))
                    }), in: 0.75...1.25, step: 0.05).accessibilityLabel("舞台の広がり")
                    Text("部屋の響き \(Int(candidate.room * 100))%")
                    Slider(value: Binding(get: { candidate.room }, set: {
                        update(HeadphoneSettings(profile: candidate.profile, room: $0, width: candidate.width))
                    }), in: 0...1, step: 0.05).accessibilityLabel("部屋の響き")
                    Text("響きを増やすと頭の外に感じやすくなる場合がありますが、輪郭がぼやける場合もあります。調整後は再試聴してください。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("この設定を演奏に使う") {
                        preview.stop()
                        model.setHeadphoneSettings(candidate)
                        dismiss()
                    }.accessibilityIdentifier("headphone-apply")
                    Text("設定は次の起動にも引き継ぎ、WAV書き出しにも反映します。実測データの候補は他の人の耳の特性です。あなた専用の測定結果ではありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("イヤホンの定位を調整").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .onDisappear { preview.finishAudition() }
        }
    }

    private func update(_ settings: HeadphoneSettings) {
        preview.stop()
        candidate = settings
        completed = []
        ratings = [:]
        drafts = [:] // Ratings are only comparable at identical room/width settings.
    }

    private func audition() {
        let sequence = HeadphoneTrial.sequence()
        let positions = Dictionary(uniqueKeysWithValues: HeadphoneTrial.positions.enumerated().map { ("trial-\($0.offset)", $0.element) })
        preview.setHeadphoneSettings(candidate)
        preview.load(sequence, instruments: [:], positions: positions)
        auditionedSettings = candidate
        preview.onCursor = { _, index in
            if let index, HeadphoneTrial.labels.indices.contains(index) { cue = HeadphoneTrial.labels[index] }
        }
        preview.onFinish = {
            if auditionedSettings == candidate { completed.insert(candidate.profile) }
            cue = "試聴完了 · 感じ方を記録できます"
        }
        preview.play()
    }
}
