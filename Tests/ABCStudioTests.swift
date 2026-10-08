import XCTest
import AVFoundation
@testable import ABCStudio

/// パーサー/ビーム/シーケンサー/MIDI/楽器推測のユニットテスト
final class ABCStudioTests: XCTestCase {

    private func parse(_ src: String) -> ABCBook {
        ABCBeaming.apply(to: ABCParser.parse(src))
    }

    private func tune(_ src: String) -> ABCTune {
        parse(src).tunes[0]
    }

    private func notes(_ t: ABCTune, _ voice: Int = 0) -> [ABCNote] {
        t.voices[voice].elements.compactMap {
            if case .note(let n) = $0 { return n }
            return nil
        }
    }

    private func seq(_ src: String) -> PlaybackSequence {
        ABCSequencer.sequence(tune(src))
    }

    private func midi(_ s: PlaybackSequence, _ track: Int = 0) -> [Int] {
        s.tracks[track].events.map { $0.midi }
    }

    // MARK: - パーサー

    func testBasicParse() {
        let t = tune("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC D E F |")
        let ns = notes(t)
        XCTAssertEqual(ns.count, 4)
        XCTAssertEqual(ns[0].pitches.first?.midi, 60) // C4
        XCTAssertEqual(ns[3].pitches.first?.midi, 65) // F4
        XCTAssertEqual(ns[0].line, 6)
    }

    func testDiagnosticsReportErrors() {
        // 閉じられていない和音 [ はエラー診断になる
        let book = parse("X:1\nT:t\nM:4/4\nL:1/4\nK:C\n[CEG\n")
        XCTAssertTrue(book.diagnostics.contains { $0.severity == .error })
    }

    func testInvalidNoteLengthsAreDiagnosedWithoutCrashing() {
        let book = parse("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC/0 D999999999999999999999 E/////// F |\n")
        XCTAssertTrue(book.diagnostics.contains { $0.severity == .error })
        XCTAssertEqual(book.tunes.count, 1)
        XCTAssertEqual(notes(book.tunes[0]).count, 4)
        XCTAssertTrue(ABCSequencer.sequence(book.tunes[0]).totalSeconds.isFinite)
    }

    func testInvalidTemposKeepFiniteDefault() {
        for tempo in ["0", "1/4=0", "1/4=nan", "1/4=1e300"] {
            let book = parse("X:1\nT:t\nM:4/4\nL:1/4\nQ:\(tempo)\nK:C\nC |\n")
            XCTAssertTrue(book.diagnostics.contains { $0.severity == .warning }, tempo)
            XCTAssertEqual(book.tunes[0].tempo.quarterNoteBPM, 120, tempo)
            XCTAssertTrue(ABCSequencer.sequence(book.tunes[0]).totalSeconds.isFinite, tempo)
        }
    }

    func testEmptyChordIsDiagnosedAndSkipped() {
        let book = parse("X:1\nT:t\nM:4/4\nL:1/4\nK:C\n[] C |\n")
        XCTAssertTrue(book.diagnostics.contains { $0.severity == .error })
        XCTAssertEqual(notes(book.tunes[0]).count, 1)
        XCTAssertNotNil(ScoreExporter.pngData(tune: book.tunes[0]))
    }

    func testChordDurationsIncludeInnerAndOuterLengths() {
        let pairs = [
            ("[C2E2G2]", "[CEG]2"),
            ("[C2E2G2]3", "[CEG]6"),
            ("[C/E/G/]", "[CEG]/"),
            ("[C/2E/2G/2]3/2", "[CEG]3/4"),
            ("[C2EG]", "[CEG]2"),
            ("[CE2G2]", "[CEG]"),
            ("(3[C2E2G2][D2F2A2][E2G2B2]", "(3[CEG]2[DFA]2[EGB]2"),
            ("[C2E2G2]>[D2F2A2]", "[CEG]2>[DFA]2")
        ]
        for (inner, outer) in pairs {
            let prefix = "X:1\nT:t\nM:4/4\nL:1/8\nK:C\n"
            let actual = notes(tune(prefix + inner + " A |"))
            let expected = notes(tune(prefix + outer + " A |"))
            XCTAssertEqual(actual.map(\.duration), expected.map(\.duration), inner)
            XCTAssertEqual(actual.map(\.dots), expected.map(\.dots), inner)
            XCTAssertEqual(actual.map(\.glyph), expected.map(\.glyph), inner)
            XCTAssertEqual(actual.map { $0.pitches.map(\.midi) },
                           expected.map { $0.pitches.map(\.midi) }, inner)
        }
    }

    func testChordPartsStaySynchronizedAcrossLongRepeatedPassage() {
        let melody = Array(repeating: "CDEF GABc", count: 24).joined(separator: " | ")
        let chords = Array(repeating: "[C,4E,4G,4] [G,,4B,,4D,4]", count: 24)
            .joined(separator: " | ")
        let s = seq("""
        X:1
        T:Part synchronization
        M:4/4
        L:1/8
        V:upper
        V:lower clef=bass
        K:C
        [V:upper] |: \(melody) :|
        [V:lower] |: \(chords) :|
        """)
        let upperStarts = s.tracks[0].events.filter { $0.midi == 60 }.map(\.startBeat)
        let lowerStarts = s.tracks[1].events.filter { $0.midi == 48 }.map(\.startBeat)
        XCTAssertEqual(upperStarts.count, 48)
        XCTAssertEqual(lowerStarts, upperStarts, "毎小節の頭が反復後も一致する")
        for track in s.tracks {
            XCTAssertEqual(track.events.map { $0.startBeat + $0.durationBeats }.max(), 192)
        }
    }

    func testAccidentalsPersistWithinVoiceAndMeasure() {
        let t = tune("X:1\nT:t\nM:4/4\nL:1/4\nV:1\nV:2\nK:C\n[V:1] ^F F | F =F F |\n[V:2] F F | F F |\n")
        XCTAssertEqual(notes(t, 0).compactMap { $0.pitches.first?.midi }, [66, 66, 65, 65, 65])
        XCTAssertEqual(notes(t, 1).compactMap { $0.pitches.first?.midi }, [65, 65, 65, 65])

        let keyed = tune("X:1\nT:t\nM:4/4\nL:1/4\nK:G\nF =F F | F |\n")
        XCTAssertEqual(notes(keyed).compactMap { $0.pitches.first?.midi }, [66, 65, 65, 66])
    }

    func testFailedLoadClearsPreviousSequence() {
        let model = StudioModel()
        model.loadABC("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC |\n", filename: "valid.abc", persist: false)
        XCTAssertGreaterThan(model.engine.duration, 0)
        model.loadABC("invalid ABC", filename: "invalid.abc", persist: false)
        XCTAssertNil(model.tune)
        XCTAssertEqual(model.engine.duration, 0)
        model.shareMIDI()
        XCTAssertNil(model.shareFile)
    }

    func testPartVolumesAreIndependentAndClamped() {
        let model = StudioModel()
        model.loadABC("""
        X:1
        T:volume test
        M:4/4
        L:1/4
        V:melody name="Violin"
        V:bass clef=bass name="Bass"
        K:C
        [V:melody] C |
        [V:bass] C, |
        """, filename: "volume.abc", persist: false)

        XCTAssertEqual(model.partVolume(for: "melody"), 1, accuracy: 0.0001)
        XCTAssertEqual(model.partVolume(for: "bass"), 1, accuracy: 0.0001)

        model.setPartVolume("melody", volume: 0.25)
        XCTAssertEqual(model.partVolume(for: "melody"), 0.25, accuracy: 0.0001)
        XCTAssertEqual(model.partVolume(for: "bass"), 1, accuracy: 0.0001)

        model.setPartVolume("melody", volume: -0.5)
        XCTAssertEqual(model.partVolume(for: "melody"), 0, accuracy: 0.0001)
        model.setPartVolume("bass", volume: 1.5)
        XCTAssertEqual(model.partVolume(for: "bass"), 1, accuracy: 0.0001)
        model.setPartVolume("bass", volume: .nan)
        XCTAssertEqual(model.partVolume(for: "bass"), 1, accuracy: 0.0001)
    }

    func testTrackGainsApplyImmediatelyAndClamp() {
        var nodes: [RecordingPlayerNode] = []
        let engine = PlaybackEngine(makePlayerNode: {
            let node = RecordingPlayerNode()
            nodes.append(node)
            return node
        })
        let tracks = [
            PlaybackTrack(voiceID: "melody", name: "Violin", isPercussion: false,
                          events: []),
            PlaybackTrack(voiceID: "bass", name: "Bass", isPercussion: false,
                          events: [])
        ]
        engine.load(PlaybackSequence(tracks: tracks,
                                     tempoMap: [TempoPoint(beat: 0, quarterNoteBPM: 120)],
                                     totalBeats: 1), instruments: [:])
        defer { engine.stop() }

        engine.setTrackGains(["melody": 0.25, "bass": 1.5])
        XCTAssertEqual(nodes[0].volume, 0.25, accuracy: 0.0001)
        XCTAssertEqual(nodes[1].volume, 1, accuracy: 0.0001)
        engine.setTrackGains(["melody": -1])
        XCTAssertEqual(nodes[0].volume, 0, accuracy: 0.0001)
    }

    func testSpeedChangePreservesPlaybackPosition() {
        let engine = PlaybackEngine()
        let sequence = PlaybackSequence(tracks: [],
                                        tempoMap: [TempoPoint(beat: 0, quarterNoteBPM: 120)],
                                        totalBeats: 100)
        engine.load(sequence, instruments: [:])
        engine.play()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let before = engine.progress
        XCTAssertGreaterThan(before, 0.005)
        engine.setSpeed(200)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let after = engine.progress
        engine.stop()
        XCTAssertLessThan(after - before, 0.004, "速度変更で再生位置が飛ばない")
    }

    func testTracksShareClockWhenLookaheadSchedulesLaterNotes() throws {
        var nodes: [RecordingPlayerNode] = []
        let engine = PlaybackEngine(makePlayerNode: {
            let node = RecordingPlayerNode()
            nodes.append(node)
            return node
        })
        let tracks = [[0.0, 1.0, 2.0, 24.5], [4.0, 24.5]].enumerated().map { index, beats in
            PlaybackTrack(voiceID: "\(index)", name: "\(index)", isPercussion: false,
                          events: beats.map {
                PlaybackEvent(elementID: index, midi: 60, startBeat: $0,
                              durationBeats: 0.25, velocity: 80)
            })
        }
        engine.load(PlaybackSequence(tracks: tracks,
                                     tempoMap: [TempoPoint(beat: 0, quarterNoteBPM: 120)],
                                     totalBeats: 32), instruments: [:])
        engine.setMasterVolume(0)
        defer { engine.stop() }
        let toppedUp = expectation(description: "両パートの先読み窓の外の音符が追加される")
        toppedUp.expectedFulfillmentCount = 2
        let laterFrame = AVAudioFramePosition(12.25 * SoundFontPlayer.sampleRate)
        for node in nodes {
            node.onSchedule = { time in
                if time.isSampleTimeValid && time.sampleTime == laterFrame { toppedUp.fulfill() }
            }
        }
        engine.play()
        XCTAssertEqual(nodes.map { $0.scheduledTimes.count }, [3, 1], "最初は12秒までを予約する")
        wait(for: [toppedUp], timeout: 5)
        let start = try XCTUnwrap(nodes.first?.starts.first)
        XCTAssertTrue(start.isHostTimeValid)
        for (index, node) in nodes.enumerated() {
            XCTAssertEqual(node.starts.count, 1)
            XCTAssertEqual(node.starts.first?.hostTime, start.hostTime,
                           "冒頭に休符があるパートも同じ時刻から開始する")
            XCTAssertTrue(node.initialBuffersPrecedeStart)
            XCTAssertEqual(node.scheduledTimes.count, tracks[index].events.count)
            for (time, event) in zip(node.scheduledTimes, tracks[index].events) {
                XCTAssertTrue(time.isSampleTimeValid)
                XCTAssertEqual(time.sampleTime,
                               AVAudioFramePosition(event.startBeat * 0.5 * SoundFontPlayer.sampleRate),
                               "追加予約でも曲頭を基準にした時刻を保つ")
            }
        }

        // A seek, speed change and resume must each establish a shared new zero.
        nodes.forEach { $0.onSchedule = nil }
        engine.seek(toFraction: 0.5) // beat 16 = 8 seconds
        XCTAssertEqual(nodes.map { $0.scheduledTimes.last?.sampleTime },
                       Array(repeating: AVAudioFramePosition(4.25 * SoundFontPlayer.sampleRate), count: 2))
        engine.setSpeed(200)
        XCTAssertEqual(nodes[0].scheduledTimes.last?.sampleTime, nodes[1].scheduledTimes.last?.sampleTime)
        engine.pause()
        engine.play()
        XCTAssertEqual(nodes[0].starts.count, 4)
        XCTAssertEqual(nodes[0].starts.map(\.hostTime), nodes[1].starts.map(\.hostTime))
        XCTAssertEqual(nodes[0].scheduledTimes.last?.sampleTime, nodes[1].scheduledTimes.last?.sampleTime)
    }

    // MARK: - ビーム(スペース切断)

    func testSpaceBreaksBeam() {
        // 6/8・16分音符で書くとビーム単位内に全音符が入り、スペースだけが切断要因になる
        let joined = tune("X:1\nT:t\nM:6/8\nL:1/16\nK:C\nCDEFGA |")
        let separated = tune("X:1\nT:t\nM:6/8\nL:1/16\nK:C\nCDE FGA |")
        let j = notes(joined)
        let s = notes(separated)
        XCTAssertEqual(j.count, 6); XCTAssertEqual(s.count, 6)
        XCTAssertTrue(j[0].beamStart); XCTAssertTrue(j[5].beamEnd)
        XCTAssertFalse(j[2].beamEnd, "スペースなしでは途中で切れない")
        XCTAssertTrue(s[3].spaceBefore, "スペースが記録される")
        XCTAssertTrue(s[2].beamEnd, "スペース直前でビームが切れる")
        XCTAssertTrue(s[3].beamStart, "スペース直後でビームが再開する")
    }

    /// 拍の境界ちょうどでビームが切れること(従来は境界で unitPos が 0 に戻るだけで
    /// グループが閉じず、小節全体が 1 本のビームになっていた)
    func testBeamBreaksAtBeatBoundary() {
        let n = notes(tune("X:1\nT:t\nM:4/4\nL:1/8\nK:C\nCDEFGABc |"))
        XCTAssertEqual(n.count, 8)
        for i in stride(from: 0, to: 8, by: 2) {
            XCTAssertTrue(n[i].beamStart, "\(i) 番目で拍が始まる")
            XCTAssertTrue(n[i + 1].beamEnd, "\(i + 1) 番目で拍が終わる")
        }
    }

    // MARK: - リピート展開

    func testPlainRepeat() {
        let s = seq("X:1\nT:t\nM:4/4\nL:1/4\nK:C\n|: C D :| E\n")
        XCTAssertEqual(midi(s), [60, 62, 60, 62, 64])
    }

    func testTwoEndings() {
        let s = seq("X:1\nT:t\nM:4/4\nL:1/4\nK:C\n|: C |1 D :|2 E |]\n")
        XCTAssertEqual(midi(s), [60, 62, 60, 64])
    }

    /// 3番目のエンディングも鳴ること(従来は 1/2 しか処理されなかった)
    func testThreeEndings() {
        let s = seq("X:1\nT:t\nM:4/4\nL:1/4\nK:C\n|: C |1 D :|2 E |3 F |]\n")
        XCTAssertEqual(midi(s), [60, 62, 60, 64, 60, 65])
    }

    // MARK: - 装飾の演奏反映

    /// フェルマータでテンポマップにディップが作られ、あとで元テンポへ戻る
    func testFermataDipsTempo() {
        let s = seq("X:1\nT:t\nM:4/4\nL:1/4\nQ:1/4=100\nK:C\nHC D |\n")
        XCTAssertTrue(s.tempoMap.contains { $0.quarterNoteBPM < 99 },
                      "フェルマータ付き音符でテンポが落ちる")
        XCTAssertTrue(s.tempoMap.contains { $0.beat > 0 && abs($0.quarterNoteBPM - 100) < 0.01 },
                      "フェルマータの後にテンポが戻る")
    }

    /// トリルが実音符列に分解される
    func testTrillRealized() {
        let s = seq("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nTC4 |\n")
        XCTAssertGreaterThan(midi(s).count, 4, "トリルは複数イベントに分解される")
    }

    /// クレッシェンドで途中の音符ベロシティが上がる
    func testCrescendoRaisesVelocity() {
        let s = seq("X:1\nT:t\nM:4/4\nL:1/4\nK:C\n!crescendo(! C D E !crescendo)! F |\n")
        let vs = s.tracks[0].events.map { $0.velocity }
        XCTAssertGreaterThan(vs[2], vs[0])
    }

    /// スタッカートでデュレーションが短くなる
    func testStaccatoShortens() {
        let s = seq("X:1\nT:t\nM:4/4\nL:1/4\nK:C\n!staccato! C |\n")
        let ev = s.tracks[0].events.first { $0.midi == 60 }
        XCTAssertNotNil(ev)
        XCTAssertLessThan(ev!.durationBeats, 0.75)
    }

    // MARK: - テンポ・時間

    func testTempoConversion() {
        XCTAssertEqual(ABCTempo(unit: ABCFraction(1, 8), bpm: 80).quarterNoteBPM,
                       40, accuracy: 0.001)
        XCTAssertEqual(ABCTempo(unit: ABCFraction(1, 4), bpm: 120).quarterNoteBPM,
                       120, accuracy: 0.001)
    }

    /// tempoMap から拍→秒変換が得られる
    func testSecondsForBeat() {
        let s = seq("X:1\nT:t\nM:4/4\nL:1/4\nQ:1/4=120\nK:C\nC D E F |\n")
        XCTAssertEqual(s.seconds(forBeat: 2), 1.0, accuracy: 0.001) // 120bpm → 0.5s/拍
        XCTAssertEqual(s.totalSeconds, 2.0, accuracy: 0.001)
    }

    // MARK: - 楽器推測

    func testInstrumentGuess() {
        XCTAssertEqual(Instruments.guess(forPartName: "Bass Drum").id, "bass_drum")
        XCTAssertEqual(Instruments.guess(forPartName: "Bass").id, "bass")
        XCTAssertEqual(Instruments.guess(forPartName: "Violin").id, "violin")
        XCTAssertEqual(Instruments.guess(forPartName: "Piano").id, "piano")
    }

    func testOrchestralAndJazzPartNames() {
        let cases: [(String, String)] = [
            ("Flauto", "flute"), ("Oboe", "oboe"), ("Corni in C", "horn"),
            ("Trombe in C", "trumpet"), ("Timpani (C-G)", "timpani"),
            ("Violino I", "violin"), ("Violino II", "violin"), ("Viola", "viola"),
            ("Violoncello e Basso", "cello_bass"), ("Contrabbassi", "contrabass"),
            ("Bassoon", "bassoon"), ("Cor anglais", "english_horn"),
            ("Tenor Saxophone", "tenor_sax"), ("Baritone Sax", "baritone_sax"),
            ("Electric Piano", "electric_piano"), ("Muted Trumpet", "muted_trumpet"),
            ("Vibraphone", "vibraphone"), ("大太鼓", "bass_drum"),
            ("Cl.", "clarinet"), ("Vln. II", "violin")
        ]
        for (name, expected) in cases {
            XCTAssertEqual(Instruments.guess(forPartName: name).id, expected, name)
        }
    }

    func testEveryInstrumentHasBundledAudibleSamples() throws {
        XCTAssertEqual(Set(Instruments.all.map(\.id)).count, Instruments.all.count)
        let root = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("SoundFont")
        let player = SoundFontPlayer()
        var checked = Set<String>()
        for instrument in Instruments.all {
            XCTAssertTrue(Instruments.categories.contains(instrument.category))
            let directory = root.appendingPathComponent(instrument.soundFontDir)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), instrument.id)
            let note = instrument.soundingNote(60)
            if checked.insert("\(instrument.soundFontDir)|\(note)").inserted {
                let buffer = try XCTUnwrap(player.makeBuffer(dir: instrument.soundFontDir,
                    midi: note, seconds: 1, velocity: 110), instrument.id)
                XCTAssertGreaterThan(buffer.frameLength, 0, instrument.id)
                let samples = try XCTUnwrap(buffer.floatChannelData)[0]
                let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) }
                XCTAssertGreaterThan(peak, 0.001, instrument.id)
            }
        }
    }

    func testCombinedCelloBassExportsBothInstruments() {
        let track = PlaybackTrack(voiceID: "1", name: "Violoncello e Basso", isPercussion: false,
            events: [PlaybackEvent(elementID: 1, midi: 48, startBeat: 0, durationBeats: 1, velocity: 100)])
        let sequence = PlaybackSequence(tracks: [track], tempoMap: [TempoPoint(beat: 0, quarterNoteBPM: 120)], totalBeats: 1)
        let bytes = [UInt8](MIDIWriter.data(for: sequence, instruments: ["1": Instruments.byID("cello_bass")!]))
        XCTAssertEqual(bytes[11], 3) // テンポ＋チェロ＋コントラバス
        XCTAssertTrue((0..<(bytes.count - 1)).contains { Array(bytes[$0...($0 + 1)]) == [0xC0, 42] })
        XCTAssertTrue((0..<(bytes.count - 1)).contains { Array(bytes[$0...($0 + 1)]) == [0xC1, 43] })
    }

    func testAssignedPercussionMIDIChannelAndPitch() {
        let instrument = Instruments.byID("triangle")!
        let track = PlaybackTrack(voiceID: "1", name: "Triangle", isPercussion: false,
            events: [PlaybackEvent(elementID: 1, midi: 60, startBeat: 0, durationBeats: 1, velocity: 100)])
        let sequence = PlaybackSequence(tracks: [track], tempoMap: [TempoPoint(beat: 0, quarterNoteBPM: 120)], totalBeats: 1)
        let bytes = [UInt8](MIDIWriter.data(for: sequence, instruments: ["1": instrument]))
        XCTAssertEqual(instrument.soundingNote(60), 81)
        XCTAssertTrue((0..<(bytes.count - 2)).contains { Array(bytes[$0...($0 + 2)]) == [0x99, 81, 100] })
        XCTAssertEqual(Instruments.byID("timpani")!.soundingNote(60), 60)
    }

    // MARK: - MIDI

    /// SMF ヘッダ(MThd)と 2 トラック(テンポ+パート)が出力される
    func testMIDIWriter() {
        let s = seq("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC D E F |\n")
        let data = MIDIWriter.data(for: s, instruments: [:])
        XCTAssertTrue(data.starts(with: Array("MThd".utf8)))
        XCTAssertGreaterThan(data.count, 40)
        // "MTrk" がテンポ + パートの 2 回出てくる
        let trk = Array("MTrk".utf8)
        var count = 0
        for i in 0...(data.count - 4) {
            if Array(data[i..<i+4]) == trk { count += 1 }
        }
        XCTAssertEqual(count, 2)
    }

    // MARK: - 楽譜エクスポート

    /// PNG エクスポートが画像を返す(最小スモーク)
    func testScoreExportPNG() {
        let t = tune("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC D E F |\n")
        let png = ScoreExporter.pngData(tune: t)
        XCTAssertNotNil(png)
        if let png {
            XCTAssertTrue(png.starts(with: [0x89, 0x50, 0x4E, 0x47])) // PNG シグネチャ
        }
    }

    /// 譜面レイアウト: 幅に収まること、段(systems)が上から順に並ぶこと、
    /// scaled() が全ジオメトリを等倍で拡大すること。
    func testScoreSystemsAndScaling() {
        let t = tune("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC D E F | G A B c | c4 |]\n")
        let score = ScoreEngraver.engrave(t, width: 390)
        XCTAssertFalse(score.systems.isEmpty, "段情報がある")
        XCTAssertFalse(score.targets.isEmpty, "音符ターゲットがある")
        XCTAssertEqual(score.size.width, 390, accuracy: 0.01,
                       "譜面幅は常にレイアウト幅に収まる(横スクロールしない)")
        for i in 1..<score.systems.count {
            XCTAssertGreaterThan(score.systems[i].band.minY, score.systems[i - 1].band.minY,
                                 "段は上から順に並ぶ")
        }

        let big = score.scaled(by: 2)
        XCTAssertEqual(big.size.width, score.size.width * 2, accuracy: 0.01)
        XCTAssertEqual(big.size.height, score.size.height * 2, accuracy: 0.01)
        XCTAssertEqual(big.systems.count, score.systems.count)
        XCTAssertEqual(big.shapes.count, score.shapes.count)
        if let id = score.targets.keys.sorted().first,
           let a = score.targets[id], let b = big.targets[id] {
            XCTAssertEqual(b.rect.midX, a.rect.midX * 2, accuracy: 0.01)
            XCTAssertEqual(b.rect.midY, a.rect.midY * 2, accuracy: 0.01)
            XCTAssertEqual(b.shapeRange, a.shapeRange, "shapeRange はそのまま引き継ぐ")
            XCTAssertEqual(b.system, a.system)
        }
    }

    /// 楽譜記号フォント(Bravura)がバンドルから読めること
    func testMusicFontLoads() {
        XCTAssertTrue(MusicFont.isAvailable, "Bravura.otf が同梱されている")
        XCTAssertNotNil(MusicFont.glyph(0xE050, size: 32), "ト音記号のグリフがある")
    }

    /// 段の構造: band が上から隙間なく並び、全音符が自分の段の中にあり、
    /// 図形範囲が段ごとに連続して全体を覆うこと(段単位の描画・追従の前提)。
    func testSystemsTileAndOwnTheirNotes() {
        let body = Array(repeating: "CDEF GABc", count: 24).joined(separator: " | ")
        let t = tune("X:1\nT:t\nM:4/4\nL:1/8\nV:1 name=\"Melody\"\nV:2 clef=bass name=\"Bass\"\nK:G\n[V:1] \(body) |]\n[V:2] \(Array(repeating: "C,8", count: 24).joined(separator: " | ")) |]\n")
        let score = ScoreEngraver.engrave(t, width: 390)
        XCTAssertGreaterThan(score.systems.count, 3, "長い曲は複数段になる")
        XCTAssertEqual(score.systems.first?.band.minY ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(score.systems.last?.band.maxY ?? -1, score.size.height, accuracy: 0.01)
        for i in 1..<score.systems.count {
            XCTAssertEqual(score.systems[i].band.minY, score.systems[i - 1].band.maxY, accuracy: 0.01,
                           "段 \(i) が前の段に接している")
            XCTAssertEqual(score.systems[i].shapeRange.lowerBound, score.systems[i - 1].shapeRange.upperBound,
                           "段 \(i) の図形範囲が連続している")
        }
        XCTAssertEqual(score.systems.last?.shapeRange.upperBound, score.shapes.count)
        for (id, target) in score.targets {
            let sys = score.systems[target.system]
            XCTAssertTrue(sys.band.contains(CGPoint(x: target.rect.midX, y: target.rect.midY)),
                          "音符 \(id) は段 \(target.system) の帯の中にある")
            XCTAssertLessThanOrEqual(target.rect.maxX, 390 + 0.01, "右端からはみ出さない")
        }
        // 各段の五線どうしが重ならない(上の段の下端 < 下の段の上端)
        for sys in score.systems {
            XCTAssertGreaterThan(sys.staffBottom - sys.staffTop, 8 * 4 * 2, "2 パートの五線が縦に並ぶ")
        }
    }

    /// 拍ごとのビームが譜面でも別々の連桁になること(従来は終了後の開始で
    /// 同じグループ番号に戻り、小節全体が 1 本に繋がっていた)
    func testEngravedBeamsFollowBeamGroups() {
        let four = ScoreEngraver.engrave(tune("X:1\nT:t\nM:4/4\nL:1/8\nK:C\nCDEFGABc |]\n"), width: 600)
        let one = ScoreEngraver.engrave(tune("X:1\nT:t\nM:6/8\nL:1/8\nK:C\nCDEFGA |]\n"), width: 600)
        // 連桁 = 横に長く(符頭より幅広)厚みのある 4 頂点の塗り。
        // 8 分音符 8 個 = 4 本、6/8 の 6 個 = 2 本
        func beamCount(_ s: EngravedScore) -> Int {
            s.shapes.filter {
                guard case .fill(let p, _) = $0 else { return false }
                var n = 0
                p.applyWithBlock { e in if e.pointee.type == .addLineToPoint { n += 1 } }
                let b = p.boundingBoxOfPath
                return n == 3 && b.width > 12 && b.height >= 3.9
            }.count
        }
        XCTAssertEqual(beamCount(four), 4)
        XCTAssertEqual(beamCount(one), 2)
    }

    /// 同時に鳴る音符はパートが違っても同じ x に揃うこと
    func testSimultaneousNotesAlignAcrossVoices() {
        let t = tune("X:1\nT:t\nM:4/4\nL:1/8\nV:1\nV:2 clef=bass\nK:C\n[V:1] CDEF GABc |]\n[V:2] C,4 G,,4 |]\n")
        let score = ScoreEngraver.engrave(t, width: 500)
        let upper = notes(t, 0), lower = notes(t, 1)
        guard let a0 = score.targets[upper[0].id], let a4 = score.targets[upper[4].id],
              let b0 = score.targets[lower[0].id], let b1 = score.targets[lower[1].id] else {
            return XCTFail("ターゲットがない")
        }
        XCTAssertEqual(a0.rect.midX, b0.rect.midX, accuracy: 0.01, "1 拍目が揃う")
        XCTAssertEqual(a4.rect.midX, b1.rect.midX, accuracy: 0.01, "3 拍目が揃う")
    }

    /// タップ位置から音符を引けること
    func testTargetLookup() {
        let t = tune("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC D E F |]\n")
        let score = ScoreEngraver.engrave(t, width: 390)
        for (id, target) in score.targets {
            XCTAssertEqual(score.target(near: CGPoint(x: target.rect.midX, y: target.rect.midY),
                                        in: target.system), id)
        }
    }

    // MARK: - ライブラリ

    private func tempLibrary() -> (LibraryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-test-\(UUID().uuidString)", isDirectory: true)
        return (LibraryStore(directory: dir), dir)
    }

    func testLibrarySaveListReadRenameDelete() throws {
        let (store, dir) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let abc = "X:1\nT:テスト曲\nX:2\nT:二曲目\nM:4/4\nL:1/4\nK:C\nC |\n"
        let item = try store.save(name: "テスト曲", abc: abc)

        XCTAssertEqual(try store.read(item), abc)
        let items = store.items()
        XCTAssertEqual(items.map(\.id), [item.id])
        XCTAssertEqual(items.first?.tuneCount, 2, "X: フィールドの数が曲数")

        try store.rename(item, to: "新しい名前")
        XCTAssertEqual(store.items().first?.name, "新しい名前")

        try store.delete(item)
        XCTAssertTrue(store.items().isEmpty)
        XCTAssertThrowsError(try store.read(item))
    }

    /// index.json が無くてもフォルダ内の .abc を取り込み、T: 行を名前に使う
    func testLibraryRecoversOrphanFiles() throws {
        let (store, dir) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let abc = "X:1\nT:orphan 曲\nM:4/4\nL:1/4\nK:C\nC |\n"
        try Data(abc.utf8).write(to: dir.appendingPathComponent("x.abc"))

        let items = store.items()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "orphan 曲")
        XCTAssertEqual(try store.read(items[0]), abc)
    }

    /// 消えたファイルは一覧から取り除かれる
    func testLibraryDropsMissingFiles() throws {
        let (store, dir) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try store.save(name: "消える曲", abc: "X:1\nK:C\nC |\n")
        try FileManager.default.removeItem(at: dir.appendingPathComponent(item.filename))
        XCTAssertTrue(store.items().isEmpty)
    }

    // MARK: - レビュー指摘の回帰テスト

    /// 各音部記号の最下線ステップ(C4=0)。公開値なので誤りは利用者を誤導する。
    func testClefBottomLineSteps() {
        XCTAssertEqual(ABCClef.treble.bottomLineStep, 2)    // E4
        XCTAssertEqual(ABCClef.bass.bottomLineStep, -10)    // G2
        XCTAssertEqual(ABCClef.alto.bottomLineStep, -4)     // F3
        XCTAssertEqual(ABCClef.tenor.bottomLineStep, -6)    // D3
    }

    /// 休符のフェルマータ(Hz)もテンポマップのディップになる
    /// (従来は休符が装飾処理の前に早期リターンしていて無視されていた)
    func testFermataOnRestDipsTempo() {
        let s = seq("X:1\nT:t\nM:4/4\nL:1/4\nQ:1/4=100\nK:C\nHz C |\n")
        XCTAssertTrue(s.tempoMap.contains { $0.quarterNoteBPM < 99 },
                      "休符のフェルマータでテンポが落ちる")
        XCTAssertTrue(s.tempoMap.contains { $0.beat > 0 && abs($0.quarterNoteBPM - 100) < 0.01 },
                      "休符のあとでテンポが戻る")
    }

    /// フェルマータ終端の復帰テンポが、同じ拍にある明示的な Q: を消さない
    func testFermataRestoreKeepsExplicitTempo() {
        let s = seq("X:1\nT:t\nM:4/4\nL:1/4\nQ:1/4=100\nK:C\nHC2 [Q:1/4=60] D2 |]\n")
        let atEnd = s.tempoMap.filter { abs($0.beat - 2) < 0.001 }
        XCTAssertEqual(atEnd.count, 1)
        XCTAssertEqual(atEnd.first?.quarterNoteBPM ?? 0, 60, accuracy: 0.01,
                       "beat 2 の明示的なテンポ 60 が残る")
    }

    /// 休符に付いた前打音も鳴る(親が休符でも装飾と同様に処理する)
    func testGraceNoteBeforeRestSounds() {
        let s = seq("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC {e}z D |\n")
        XCTAssertTrue(midi(s).contains(76), "休符に付いた前打音 e5 が鳴る")
        XCTAssertEqual(midi(s).filter { $0 == 76 }.count, 1)
    }

    /// トリルの上方隣音は調に沿う(全音とは限らない)
    func testTrillUsesDiatonicUpperNeighbor() {
        let cMajor = seq("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nTE4 |\n")
        XCTAssertTrue(midi(cMajor).contains(65), "C 調では E のトリルの上音は F")
        XCTAssertFalse(midi(cMajor).contains(66), "C 調では F# は鳴らない")
        let gMajor = seq("X:1\nT:t\nM:4/4\nL:1/4\nK:G\nTE4 |\n")
        XCTAssertTrue(midi(gMajor).contains(66), "G 調では E のトリルの上音は F#")
        XCTAssertFalse(midi(gMajor).contains(65), "G 調では F ナチュラルは鳴らない")
    }

    /// 本文中の拍子変更が meterMap に集約される(MIDI エクスポート等で使う)
    func testInlineMeterChangeCollected() {
        let s = seq("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC D E F | [M:3/4] G A B |]\n")
        XCTAssertEqual(s.meterMap.map { $0.beat }, [0, 4])
        guard case .fraction(let n0, let d0) = s.meterMap[0].meter.style,
              case .fraction(let n1, let d1) = s.meterMap[1].meter.style else {
            return XCTFail("meterMap が分数拍子を保持していない")
        }
        XCTAssertEqual(n0, 4)
        XCTAssertEqual(d0, 4)
        XCTAssertEqual(n1, 3)
        XCTAssertEqual(d1, 4)
    }

    /// ±7 を超える調号は警告になり、臨時記号は 7 個に丸められる
    func testKeySignatureBeyondSevenWarns() {
        let sharp = parse("X:1\nT:t\nM:4/4\nL:1/4\nK:G#\nC |\n")
        XCTAssertTrue(sharp.diagnostics.contains { $0.severity == .warning },
                      "G# major (8#) は警告になる")
        XCTAssertEqual(sharp.tunes[0].voices[0].keySignature.accidentals.count, 7)

        let flat = parse("X:1\nT:t\nM:4/4\nL:1/4\nK:Fb\nC |\n")
        XCTAssertTrue(flat.diagnostics.contains { $0.severity == .warning },
                      "Fb major (8b) は警告になる")

        let ok = parse("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC |\n")
        XCTAssertFalse(ok.diagnostics.contains {
            $0.severity == .warning && $0.message.contains("臨時記号")
        }, "通常の調では警告しない")
    }

    /// 歌詞の音節は休符を飛ばして音符にだけ割り当てられる
    func testLyricsSkipRests() {
        let t = tune("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC z D |\nw: a b\n")
        let ns = notes(t)
        XCTAssertEqual(ns.count, 3)
        XCTAssertEqual(ns[0].lyric?.syllable, "a")
        XCTAssertNil(ns[1].lyric, "休符には歌詞を付けない")
        XCTAssertEqual(ns[2].lyric?.syllable, "b", "休符は音節を消費しない")
    }

    /// 音節が音符より多い場合・同じ範囲を繰り返す複数番の w: 行は警告になる
    func testSurplusLyricsWarn() {
        let surplus = parse("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC D |\nw: a b c\n")
        XCTAssertTrue(surplus.diagnostics.contains {
            $0.severity == .warning && $0.message.contains("歌詞")
        }, "余った音節は警告になる")

        let verses = parse("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC D |\nw: a b\nw: c d\n")
        XCTAssertTrue(verses.diagnostics.contains {
            $0.severity == .warning && $0.message.contains("歌詞")
        }, "2番以降の w: 行は未対応として警告になる")
    }

    /// 空行で曲が切れた後の行は「読み込まれない」エラーになる
    func testDroppedLineDiagnosed() {
        let diags = ABCDiagnostics.validate(
            "X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC D |\n\n% コメントは飛ばす\nE F |\n")
        XCTAssertTrue(diags.contains {
            $0.severity == .error && $0.line == 9 && $0.message.contains("読み込まれません")
        })
        // 新しい X: で始まる次の曲は「読み捨て」ではない
        let nextTune = ABCDiagnostics.validate(
            "X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC D |\n\nX:2\nT:t2\nK:C\nE F |\n")
        XCTAssertFalse(nextTune.contains { $0.message.contains("読み込まれません") })
    }

    /// 3音以上の連続する2度のクラスターでは、外側の符頭は同じ列に揃い、
    /// 真ん中だけが反対側へずれる(従来は上位2音が同じ側に重なっていた)。
    /// 上符尾 [CDE] は中央が右へ、下符尾 [fga] は中央が左へ。
    func testClusterSecondHeadsAlternate() throws {
        let t = tune("X:1\nT:t\nM:4/4\nL:1/4\nK:C\n[CDE] [fga] |]\n")
        let ns = notes(t)
        XCTAssertEqual(ns.count, 2)
        let score = ScoreEngraver.engrave(t, width: 400)
        for (n, direction) in [(ns[0], 1.0), (ns[1], -1.0)] {
            let target = try XCTUnwrap(score.targets[n.id])
            // 符頭は shapeRange の先頭3個に pitch 昇順で並ぶ(後ろは加線等)
            let heads = target.shapeRange.prefix(3).compactMap { idx -> CGPoint? in
                guard case .fill(let p, _) = score.shapes[idx] else { return nil }
                let b = p.boundingBoxOfPath
                return CGPoint(x: b.midX, y: b.midY)
            }
            XCTAssertEqual(heads.count, 3)
            // y 降順 = 低い音から(画面座標は y-down)
            let byPitch = heads.sorted { $0.y > $1.y }
            XCTAssertEqual(byPitch[0].x, byPitch[2].x, accuracy: 0.5,
                           "外側の2音は同じ列に揃う")
            XCTAssertGreaterThan((byPitch[1].x - byPitch[0].x) * CGFloat(direction), 2,
                                 "中央の音だけがずれる")
        }
    }

    /// 2音の2度は従来どおり上位音だけがずれる
    func testTwoNoteSecondHeads() throws {
        let t = tune("X:1\nT:t\nM:4/4\nL:1/4\nK:C\n[CD] |]\n")
        let score = ScoreEngraver.engrave(t, width: 400)
        let n = try XCTUnwrap(notes(t).first)
        let target = try XCTUnwrap(score.targets[n.id])
        let heads = target.shapeRange.prefix(2).compactMap { idx -> CGPoint? in
            guard case .fill(let p, _) = score.shapes[idx] else { return nil }
            let b = p.boundingBoxOfPath
            return CGPoint(x: b.midX, y: b.midY)
        }
        XCTAssertEqual(heads.count, 2)
        let byPitch = heads.sorted { $0.y > $1.y }
        XCTAssertGreaterThan(byPitch[1].x - byPitch[0].x, 2, "上符尾では上位音が右へ")
    }

    /// MIDI トラック0 に拍子メタイベント(FF 58 04)が入る。途中変更も出す。
    func testMIDITimeSignatureEvents() {
        let s = seq("X:1\nT:t\nM:4/4\nL:1/4\nK:C\nC D E F | [M:3/4] G A B |]\n")
        let data = [UInt8](MIDIWriter.data(for: s, instruments: [:]))
        let sig44: [UInt8] = [0xFF, 0x58, 0x04, 0x04, 0x02, 24, 8]
        let sig34: [UInt8] = [0xFF, 0x58, 0x04, 0x03, 0x02, 24, 8]
        func index(of sig: [UInt8]) -> Int? {
            guard data.count >= sig.count else { return nil }
            for i in 0...(data.count - sig.count)
                where Array(data[i..<i + sig.count]) == sig { return i }
            return nil
        }
        let i44 = index(of: sig44), i34 = index(of: sig34)
        XCTAssertNotNil(i44, "4/4 の拍子メタイベントがある")
        XCTAssertNotNil(i34, "途中の 3/4 変更もメタイベントになる")
        if let i44, let i34 { XCTAssertLessThan(i44, i34, "時系列順に並ぶ") }
    }

    /// 再生していない時のルート変更では onAutoPause を呼ばない
    /// (誤って「一時停止」表示になるのを防ぐ)。再生中は呼ばれて一時停止する。
    func testRouteChangeAutoPauseOnlyWhilePlaying() {
        var nodes: [RecordingPlayerNode] = []
        let engine = PlaybackEngine(makePlayerNode: {
            let node = RecordingPlayerNode()
            nodes.append(node)
            return node
        })
        let sequence = PlaybackSequence(
            tracks: [PlaybackTrack(voiceID: "v", name: "v", isPercussion: false,
                                   events: [PlaybackEvent(elementID: 0, midi: 60,
                                                          startBeat: 0, durationBeats: 64,
                                                          velocity: 80)])],
            tempoMap: [TempoPoint(beat: 0, quarterNoteBPM: 120)],
            totalBeats: 64)
        engine.load(sequence, instruments: [:])
        var autoPauses = 0
        engine.onAutoPause = { autoPauses += 1 }
        func postRouteChange() {
            NotificationCenter.default.post(
                name: AVAudioSession.routeChangeNotification, object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey:
                            AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        }
        // 停止中: 呼ばれない(オブザーバー未装着なので一度再生して止めてから試す)
        engine.play()
        engine.pause()
        postRouteChange()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(autoPauses, 0, "停止中のルート変更では通知しない")

        // 再生中: 呼ばれて一時停止になる
        engine.play()
        XCTAssertTrue(engine.isPlaying)
        postRouteChange()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(autoPauses, 1, "再生中のルート変更は自動一時停止として通知")
        XCTAssertFalse(engine.isPlaying)
        engine.stop()
    }

    /// 速度はモデル側でも 50–200% にクランプされる(表示値と実再生がずれない)
    func testSpeedIsClamped() {
        let model = StudioModel()
        model.setSpeed(500)
        XCTAssertEqual(model.speed, 200)
        model.setSpeed(10)
        XCTAssertEqual(model.speed, 50)
        model.setSpeed(120)
        XCTAssertEqual(model.speed, 120)
    }

    /// 巨大なファイルのインポートはエラーになる(メインスレッドの重いパースを防ぐ)
    func testImportFileRejectsOversizedFile() throws {
        let model = StudioModel()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("huge-\(UUID().uuidString).abc")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x63, count: 9 * 1024 * 1024).write(to: url)
        model.importError = nil
        model.importFile(url)
        XCTAssertNotNil(model.importError, "8 MB 超のファイルは拒否される")
        XCTAssertNil(model.tune, "拒否したファイルで楽譜は更新されない")
    }
}

/// Observes the actual commands sent to AVAudioPlayerNode, including timer top-ups.
private final class RecordingPlayerNode: AVAudioPlayerNode {
    var scheduledTimes: [AVAudioTime] = []
    var starts: [AVAudioTime] = []
    var initialBuffersPrecedeStart = false
    var onSchedule: ((AVAudioTime) -> Void)?

    override func scheduleBuffer(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime?,
                                 options: AVAudioPlayerNodeBufferOptions = [],
                                 completionHandler: AVAudioNodeCompletionHandler? = nil) {
        if let when {
            scheduledTimes.append(when)
            onSchedule?(when)
        }
        super.scheduleBuffer(buffer, at: when, options: options, completionHandler: completionHandler)
    }

    override func play(at when: AVAudioTime?) {
        if starts.isEmpty { initialBuffersPrecedeStart = !scheduledTimes.isEmpty }
        if let when { starts.append(when) }
        super.play(at: when)
    }
}
