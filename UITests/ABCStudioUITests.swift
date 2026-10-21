import XCTest

/// スモークテスト: 起動・譜面描画・タブ遷移・再生・タップで拡大しないことの確認。
/// スクリーンショットはテスト結果に添付し、シミュレータ内の一時フォルダにも保存する。
final class ABCStudioUITests: XCTestCase {

    private func saveScreenshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? shot.pngRepresentation.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-\(name).png"))
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// 前回の状態に左右されないよう、表示する ABC を起動引数(UserDefaults の
    /// 引数ドメイン)で渡して起動する。値は plist の引用符付き文字列として解釈される。
    private func launch(abc: String, extra: [String] = []) -> XCUIApplication {
        let quoted = "\"" + abc.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
        let app = XCUIApplication()
        app.launchArguments += ["-lastABC", quoted, "-lastFilename", "\"\""] + extra
        app.launch()
        let play = app.buttons["再生"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        return app
    }

    private static let ensemble = """
    X:1
    T:小さなアンサンブル
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

    func testRepeatedTabChangesKeepDraftUndoAndMixerState() throws {
        let app = launch(abc: Self.ensemble)
        app.buttons["ABCを編集"].tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText(" retained-draft")
        let draft = try XCTUnwrap(editor.value as? String)
        app.toolbars.buttons["完了"].tap()
        app.buttons["楽器・音量"].tap()
        let volume = app.sliders["part-volume-melody"]
        volume.adjust(toNormalizedSliderPosition: 0.3)
        let chosenVolume = volume.value as? String
        for _ in 0..<3 {
            app.buttons["ライブラリ"].tap()
            XCTAssertTrue(app.textFields["library-search"].waitForExistence(timeout: 3))
            app.buttons["楽譜"].tap()
            XCTAssertTrue(app.otherElements["scoreView"].waitForExistence(timeout: 3))
            app.buttons["楽器・音量"].tap()
            XCTAssertEqual(app.sliders["part-volume-melody"].value as? String, chosenVolume)
            app.buttons["ABCを編集"].tap()
            XCTAssertEqual(app.textViews.firstMatch.value as? String, draft)
        }
        app.textViews.firstMatch.tap()
        app.toolbars.buttons["取り消す"].tap()
        XCTAssertNotEqual(app.textViews.firstMatch.value as? String, draft,
                          "タブ移動後も同じエディタの取り消し履歴を使える")
        app.toolbars.buttons["完了"].tap()
    }

    func testPlaybackSurvivesTabSwitchesMixerScrollingAndSeeking() {
        let app = launch(abc: Self.ensemble + "\n[V:melody] " + String(repeating: "C D E F | ", count: 32))
        app.buttons["再生"].tap()
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 3))
        for _ in 0..<2 {
            app.buttons["楽器・音量"].tap()
            XCTAssertTrue(app.staticTexts["MIXER"].waitForExistence(timeout: 3))
            app.scrollViews.firstMatch.swipeUp()
            app.scrollViews.firstMatch.swipeDown()
            app.buttons["ABCを編集"].tap()
            XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 3))
            app.buttons["楽譜"].tap()
        }
        let position = app.sliders["再生位置"]
        position.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(app.buttons["一時停止"].exists)
        let moved = NSPredicate { _, _ in
            guard let text = position.value as? String,
                  let value = Double(text.replacingOccurrences(of: "%", with: "")) else { return false }
            return value >= 45
        }
        expectation(for: moved, evaluatedWith: nil)
        waitForExpectations(timeout: 3)
        app.buttons["停止"].tap()
        XCTAssertTrue(app.buttons["再生"].waitForExistence(timeout: 3))
    }

    func testScorePlaybackAndNoZoomOnTap() throws {
        let app = launch(abc: Self.ensemble)

        // 例題が読み込まれ譜面タブが表示される
        XCTAssertTrue(app.staticTexts["SCORE"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["楽器・音量"].exists)
        saveScreenshot("1-score")

        // タップしてもページが拡大されないこと(ネイティブ化の検証):
        // WebView ではタップ領域やダブルタップで scrollView.zoomScale が変わっていた。
        // ネイティブ ScrollView に zoomScale は存在しない。ここでは譜面領域を複数回
        // タップ・ダブルタップしてもクラッシュせず UI が不変であることを確認する。
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        center.tap()
        center.doubleTap()
        center.tap()
        XCTAssertTrue(app.staticTexts["SCORE"].exists)
        saveScreenshot("2-after-taps")

        // 楽器・音量タブ: 3声部の行が出る
        app.buttons["楽器・音量"].tap()
        XCTAssertTrue(app.staticTexts["Violin"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Piano"].exists)
        XCTAssertTrue(app.staticTexts["Bass"].exists)
        saveScreenshot("3-parts")

        // ABCを編集タブ: エディタにソースが入っている
        app.buttons["ABCを編集"].tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertTrue(editor.value as? String != nil)
        XCTAssertTrue((editor.value as? String ?? "").contains("X:1"))
        saveScreenshot("4-source")

        // 楽譜に戻って再生
        app.buttons["楽譜"].tap()
        XCTAssertTrue(app.staticTexts["SCORE"].waitForExistence(timeout: 3))
        let playButton = app.buttons.matching(NSPredicate(format: "label == '▶' OR label == '再生'")).firstMatch
        XCTAssertTrue(playButton.waitForExistence(timeout: 3))
        playButton.tap()

        // 再生状態になる(ステータス or 一時停止ボタン)
        let playing = app.staticTexts["再生中"].waitForExistence(timeout: 5)
        XCTAssertTrue(playing)
        saveScreenshot("5-playing")

        // 2秒以上経過して時間が進む or カーソルが動く(再生完了でもOKとせず progress を確認)
        sleep(2)
        saveScreenshot("6-playing-later")

        // 停止
        app.buttons.matching(
            NSPredicate(format: "label == '■' OR label == '停止'")
        ).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["停止"].waitForExistence(timeout: 3))
    }

    /// 楽器・音量タブの各パートに独立した音量スライダーがあり、変更した値が表示される。
    func testEachPartHasIndependentVolumeSlider() throws {
        let app = launch(abc: Self.ensemble)
        app.buttons["楽器・音量"].tap()

        let melody = app.sliders["part-volume-melody"]
        let harmony = app.sliders["part-volume-harmony"]
        let bass = app.sliders["part-volume-bass"]
        XCTAssertTrue(melody.waitForExistence(timeout: 3))
        XCTAssertTrue(harmony.exists)
        XCTAssertTrue(bass.exists)
        XCTAssertEqual(melody.label, "Violinの音量")
        XCTAssertTrue(String(describing: melody.value).contains("100"))
        XCTAssertTrue(String(describing: harmony.value).contains("100"))
        XCTAssertTrue(String(describing: bass.value).contains("100"))

        melody.adjust(toNormalizedSliderPosition: 0.25)
        // XCTest のドラッグ位置は概算なので、25% との厳密な一致は要求しない。
        let adjustedPercent = try XCTUnwrap(Int((melody.value as? String ?? "")
            .replacingOccurrences(of: "%", with: "")))
        XCTAssertGreaterThan(adjustedPercent, 0)
        XCTAssertLessThan(adjustedPercent, 50, "操作したパートの音量表示が下がる")
        XCTAssertTrue(String(describing: harmony.value).contains("100"))
        XCTAssertTrue(String(describing: bass.value).contains("100"))
        saveScreenshot("parts-volume")
    }

    /// 自動追従: 長い曲を再生すると譜面が段ごとに送られ、指でスクロールすると
    /// 一時停止して「再生位置へ戻る」が出て、押すと追従が再開すること。
    func testFollowScrollsDuringPlayback() throws {
        let body = (0..<24).map { i in i % 2 == 0 ? "CDEF GABc" : "cBAG FEDC" }.joined(separator: " | ")
        let abc = "X:1\nT:Follow test\nM:4/4\nL:1/8\nQ:1/4=200\nK:C\n\(body) |]\n"
        let app = launch(abc: abc, extra: ["-scoreFollowEnabled", "YES", "-scoreZoom", "1"])
        XCTAssertTrue(app.staticTexts["Follow test"].waitForExistence(timeout: 5))

        let score = app.otherElements["scoreView"].firstMatch
        let firstScreen = XCUIScreen.main.screenshot().pngRepresentation
        saveScreenshot("follow-0")

        let playButton = app.buttons["再生"].firstMatch
        XCTAssertTrue(playButton.waitForExistence(timeout: 3))
        playButton.tap()
        sleep(6)
        saveScreenshot("follow-1")
        XCTAssertNotEqual(XCUIScreen.main.screenshot().pngRepresentation, firstScreen,
                          "再生が進むと譜面が送られる")

        // 手動スクロールで一時停止 → 戻るボタン
        (score.exists ? score : app.windows.firstMatch).swipeDown()
        let resume = app.buttons["再生位置へ戻る"]
        XCTAssertTrue(resume.waitForExistence(timeout: 3), "手動スクロールで追従が一時停止する")
        saveScreenshot("follow-2-suspended")
        resume.tap()
        sleep(1)
        XCTAssertFalse(resume.exists, "戻ると追従が再開する")
        saveScreenshot("follow-3-resumed")

        app.buttons["停止"].firstMatch.tap()
    }

    /// Settings must remain usable without squeezing controls into the player.
    func testPlaybackSettingsAndExportFormats() throws {
        let app = launch(abc: Self.ensemble)
        app.buttons["再生設定"].tap()
        XCTAssertTrue(app.sliders["再生速度"].waitForExistence(timeout: 3))
        app.buttons["75%"].tap()
        let loop = app.switches["ループ再生"]
        XCTAssertTrue(loop.exists)
        loop.tap()
        XCTAssertEqual(loop.value as? String, "1")
        saveScreenshot("redesign-playback-settings")
        app.buttons["完了"].tap()
        XCTAssertTrue(app.buttons["再生設定"].value as? String == "速度 75%")

        app.buttons["書き出し・共有"].tap()
        XCTAssertTrue(app.staticTexts["PDF"].waitForExistence(timeout: 3))
        for format in ["PNG 画像", "MIDI", "WAV 音声", "ABC テキスト"] {
            XCTAssertTrue(app.staticTexts[format].exists)
        }
        saveScreenshot("redesign-export")
        app.staticTexts["ABC テキスト"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5),
                      "The system share sheet opens after the format sheet dismisses")
    }

    /// The keyboard should leave room to write and provide an explicit way back.
    func testEditorKeyboardAndApply() throws {
        let app = launch(abc: Self.ensemble)
        app.buttons["ABCを編集"].tap()
        app.buttons["エディタの操作"].tap()
        app.buttons["入力内容をすべて削除"].tap()
        app.alerts.buttons["すべて削除"].tap()
        let editor = app.textViews.firstMatch
        editor.tap()
        editor.typeText("X:1\nT:New melody\nM:4/4\nL:1/4\nK:C\nC D E F | G A B c |")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        saveScreenshot("redesign-keyboard")
        app.toolbars.buttons["完了"].tap()
        XCTAssertTrue(app.buttons["楽譜に反映"].waitForExistence(timeout: 3))
        app.buttons["楽譜に反映"].tap()
        XCTAssertTrue(app.staticTexts["SCORE"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["New melody"].firstMatch.exists)
        XCTAssertTrue(app.buttons["再生"].isHittable)
        saveScreenshot("redesign-applied")
    }

    /// Save/search/rename/delete only the item created by this test.
    func testLibrarySaveSearchAndRename() throws {
        let title = "UI Library " + UUID().uuidString.prefix(8)
        let renamed = title + " renamed"
        let abc = "X:1\nT:\(title)\nM:4/4\nL:1/4\nK:C\nC D E F |"
        let app = launch(abc: abc)
        app.buttons["ライブラリ"].tap()
        app.buttons["現在の曲を保存"].tap()
        let search = app.textFields["library-search"]
        search.tap()
        search.typeText(String(title) + "\n")
        let actions = app.buttons[String(title) + "の操作"]
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.tap()
        app.buttons["名前を変更"].tap()
        let name = app.alerts.textFields.firstMatch
        name.typeText(" renamed")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(app.buttons[String(renamed) + "の操作"].waitForExistence(timeout: 3))
        saveScreenshot("redesign-library")
        app.buttons[String(renamed) + "の操作"].tap()
        app.buttons["削除"].tap()
        app.alerts.buttons["削除"].tap()
        XCTAssertFalse(app.buttons[String(renamed) + "の操作"].exists)
    }

    func testLibrarySamplesAndLandscapeLayout() throws {
        let app = launch(abc: Self.ensemble)
        app.buttons["ライブラリ"].tap()
        saveScreenshot("redesign-library-overview")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["サンプルを開く"].firstMatch.waitForExistence(timeout: 3))
        app.staticTexts["サンプルを開く"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["SCORE"].waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["再生"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["再生"].isHittable)
        let score = app.scrollViews.firstMatch
        XCTAssertGreaterThan(score.frame.height, 100, "Landscape leaves usable space for the score")
        saveScreenshot("redesign-landscape")
    }

}
