# 楽器対応

画像の Flauto、Oboe、Corni in C、Trombe in C、Timpani (C-G)、Violino I / II、Viola、Violoncello e Basso を自動判定します。イタリア語・英語・日本語の楽器名と主要な略記に対応します。調名やパート番号は音色判定と切り離して扱い、楽器名から移調を勝手に加えません。

楽器割り当ては78種類です。音源はFluidR3 GMの音色を実際にレンダリングして同梱し、再生と音声書き出しで共有します。元音源の発音範囲外にある無音サンプルは同梱せず、同じ楽器の有効なノートから既存のピッチ変換処理で音程を作ります。チェロ＋コントラバスは両音色の合成サンプルです。単独の無音程打楽器は固定GMノートを使用し、ドラムセットは譜面上のGMノート配置を使用します。MIDIでも同じプログラム・打楽器キーを指定します。チェロ＋コントラバスはMIDIでは二つのチャンネルに分けます。

## 対応一覧

|分類|楽器|MIDI（0始まり）|サンプルディレクトリ|
|---|---|---|---|
|鍵盤|ピアノ|0|`acoustic_grand_piano`|
|ギター・ベース|クラシックギター|24|`acoustic_guitar_nylon`|
|弦楽器|バイオリン|40|`violin`|
|木管楽器|フルート|73|`flute`|
|金管楽器|トランペット|56|`trumpet`|
|ギター・ベース|エレキベース|33|`electric_bass_finger`|
|打楽器|ドラム／打楽器セット|128|`percussion`|
|声楽|合唱|52|`choir_aahs`|
|弦楽器|ビオラ|41|`viola`|
|弦楽器|チェロ|42|`cello`|
|弦楽器|コントラバス|43|`contrabass`|
|弦楽器|チェロ＋コントラバス|42|`cello_contrabass`|
|弦楽器|ピチカート弦楽器|45|`pizzicato_strings`|
|弦楽器|トレモロ弦楽器|44|`tremolo_strings`|
|弦楽器|弦楽合奏|48|`string_ensemble_1`|
|弦楽器|ハープ|46|`orchestral_harp`|
|木管楽器|ピッコロ|72|`piccolo`|
|木管楽器|オーボエ|68|`oboe`|
|木管楽器|イングリッシュホルン|69|`english_horn`|
|木管楽器|ファゴット|70|`bassoon`|
|木管楽器|クラリネット|71|`clarinet`|
|木管楽器|ソプラノサックス|64|`soprano_sax`|
|木管楽器|アルトサックス|65|`alto_sax`|
|木管楽器|テナーサックス|66|`tenor_sax`|
|木管楽器|バリトンサックス|67|`baritone_sax`|
|木管楽器|リコーダー|74|`recorder`|
|金管楽器|ホルン|60|`french_horn`|
|金管楽器|トロンボーン|57|`trombone`|
|金管楽器|チューバ|58|`tuba`|
|金管楽器|ミュートトランペット|59|`muted_trumpet`|
|鍵盤|エレクトリックピアノ|4|`electric_piano_1`|
|鍵盤|FMエレクトリックピアノ|5|`electric_piano_2`|
|鍵盤|チェンバロ|6|`harpsichord`|
|鍵盤|クラビネット|7|`clavinet`|
|鍵盤|チェレスタ|8|`celesta`|
|鍵盤|パイプオルガン|19|`church_organ`|
|鍵盤|ジャズオルガン|16|`drawbar_organ`|
|鍵盤|アコーディオン|21|`accordion`|
|ギター・ベース|アコースティックギター（スチール）|25|`acoustic_guitar_steel`|
|ギター・ベース|ジャズギター|26|`electric_guitar_jazz`|
|ギター・ベース|エレキギター|27|`electric_guitar_clean`|
|ギター・ベース|ミュートギター|28|`electric_guitar_muted`|
|ギター・ベース|ディストーションギター|30|`distortion_guitar`|
|ギター・ベース|アコースティックベース（撥弦）|32|`acoustic_bass`|
|ギター・ベース|ピックベース|34|`electric_bass_pick`|
|ギター・ベース|フレットレスベース|35|`fretless_bass`|
|ギター・ベース|バンジョー|105|`banjo`|
|有音程打楽器|ティンパニ|47|`timpani`|
|有音程打楽器|グロッケンシュピール|9|`glockenspiel`|
|有音程打楽器|ビブラフォン|11|`vibraphone`|
|有音程打楽器|マリンバ|12|`marimba`|
|有音程打楽器|シロフォン|13|`xylophone`|
|有音程打楽器|チューブラーベル|14|`tubular_bells`|
|有音程打楽器|ダルシマー|15|`dulcimer`|
|有音程打楽器|スティールパン|114|`steel_drums`|
|有音程打楽器|ウッドブロック（有音程）|115|`woodblock`|
|有音程打楽器|太鼓（有音程）|116|`taiko_drum`|
|打楽器|大太鼓|128|`percussion`|
|打楽器|小太鼓|128|`percussion`|
|打楽器|シンバル|128|`percussion`|
|打楽器|ライドシンバル|128|`percussion`|
|打楽器|ハイハット|128|`percussion`|
|打楽器|タンバリン|128|`percussion`|
|打楽器|トライアングル|128|`percussion`|
|打楽器|カウベル|128|`percussion`|
|打楽器|コンガ|128|`percussion`|
|打楽器|ボンゴ|128|`percussion`|
|打楽器|ティンバレス|128|`percussion`|
|打楽器|クラベス|128|`percussion`|
|打楽器|ウッドブロック|128|`percussion`|
|打楽器|カスタネット（Fluid拡張）|128|`percussion`|
|打楽器|マラカス|128|`percussion`|
|打楽器|カバサ|128|`percussion`|
|打楽器|ギロ|128|`percussion`|
|打楽器|ビブラスラップ|128|`percussion`|
|電子楽器|シンセサイザー（リード）|80|`lead_1_square`|
|電子楽器|シンセサイザー（パッド）|88|`pad_1_new_age`|
|電子楽器|シンセストリングス|50|`synth_strings_1`|

## 音源の範囲と未対応

この一覧は全楽器・全奏法の完全対応を意味しません。GM音源に専用音色がないバスクラリネット、コントラファゴット、アルト／バスフルート、オーボエ・ダモーレ、バセットホルン、ユーフォニアム、ワーグナーチューバ、チェン、ゴング／タムタム、クロテイル、ウォーターフォン、プリペアドピアノ、テルミンなどは専用音色未対応です。弦の特殊奏法、管のマルチフォニックス、四分音・微分音も未対応です。これらを別の楽器の音で対応済みとは扱いません。未知のパート名では既存仕様のピアノ（打楽器譜ならドラムセット）が初期選択されるので、メニューから対応楽器を指定してください。

全楽器対応にはGM以外の専用音源の追加が必要です。楽器名の追加だけでは音色の対応にはなりません。

GM規格の参照: [MIDI Association — General MIDI](https://midi.org/general-midi)。音源のライセンスは [帰属表示](../SoundFont/SOUNDFONT-ATTRIBUTION.md) を参照してください。

## サンプル再生成

```
scripts/render_soundfont.sh /path/to/FluidR3_GM.sf2 SoundFont
```

未生成のディレクトリだけ生成する場合は末尾に `missing` を指定します。アプリの楽器一覧からレンダリング対象を取得するため、プログラム番号とディレクトリを別々に管理する必要はありません。
