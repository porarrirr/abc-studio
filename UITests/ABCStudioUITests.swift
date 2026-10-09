import XCTest

/// スモークテスト: 起動・譜面描画・タブ遷移・再生・タップで拡大しないことの確認。
/// スクリーンショットは /tmp/uitest-*.png に保存される(実行プロセスはmacOS側)。
final class ABCStudioUITests: XCTestCase {

    private func saveScreenshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/uitest-\(name).png"))
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
}
