import XCTest
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
        XCTAssertEqual(Instruments.guess(forPartName: "Bass Drum").id, "drums")
        XCTAssertEqual(Instruments.guess(forPartName: "Bass").id, "bass")
        XCTAssertEqual(Instruments.guess(forPartName: "Violin").id, "violin")
        XCTAssertEqual(Instruments.guess(forPartName: "Piano").id, "piano")
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
}
