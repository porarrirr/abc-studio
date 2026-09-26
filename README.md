# ABC Studio

ABC 記譜法のファイルを読み込み、楽譜を表示して再生する iPhone / iPad アプリです。

## 主な機能

- `.abc` / `.txt` の読み込み、複数曲が入ったファイルの曲選択、ABC テキストの編集、最後に開いた楽譜の復元
- ピアノ、ギター、バイオリン、フルート、トランペット、ベース、ドラム、合唱の音色
- `V:` で定義した複数パートへの個別の楽器割り当てと同時再生
- 再生・一時停止・停止・シーク・速度変更（75–150%）
- 再生中の音符の色付け、譜面カーソル、横・縦スクロール追従
- 音色はアプリに同梱。楽譜の再生にインターネット接続は不要

合唱は General MIDI の `Choir Aahs` 音色であり、歌詞を発声する音声合成ではありません。ドラムは General MIDI の打楽器音程配置を使います。`Samples/drum-kit.abc` を参照してください。

## ビルド

Xcode で `ABCStudio.xcodeproj` を開いてビルドします。プロジェクト設定を再生成する場合は `xcodegen generate` を実行してください。iOS 17 以降に対応します。

## 構成とライセンス

譜面描画・再生には [abcjs 6.7.1](https://github.com/paulrosen/abcjs) を使用しています。オフラインの音色には FluidR3_GM の MP3 サンプルを使用しています。ライセンスと帰属表示は `Web/ABCJS-LICENSE.md` と `Web/SOUNDFONT-ATTRIBUTION.md` を参照してください。abcjs の音色読み込みは同時要求数を 12 に抑えるため、同梱した配布版のバッチサイズを調整しています。

音色を再取得するには `python3 scripts/fetch_soundfonts.py` を実行します。
