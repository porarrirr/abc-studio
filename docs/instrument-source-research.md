# GM以外の専用音源の調査

現時点で以下は調査候補です。アプリには同梱していません。

|音源|対象となる不足分|一次資料の記載|実装上の確認点|
|---|---|---|---|
|[VCSL](https://versilian-studios.com/vcsl/)|ゴング、フレクサトーン、ラチェット、スラップスティック、ベルツリー、金床、ブレーキドラム、オーシャンドラムなど|CC0。商用ソフトへの組み込みも可能と明記|SFZ/WAVのマッピング、専用音色の取り込み、GMにない楽器のMIDI表現|
|[VSCO 2 CE](https://versilian-studios.com/vsco-community/)|管弦楽器・打楽器の追加音色|CC0。原WAVとSFZを公開|GM音源を置き換える場合の音量・発音・音域の整合|
|[University of Iowa MIS](https://theremin.music.uiowa.edu/MIS.html)|バスクラリネット、バスフルートなど|楽器サンプルの公開元|個々の利用条件、連続録音のノート分割、ループとリリース処理|
|[Virtual Playing Orchestra](https://virtualplaying.com/standard-orchestra-documentation/)|アルトフルート、バスクラリネット、コントラファゴットなど|専用パッチを掲載|複数の原音源とライセンスが混在。楽器単位で出典を確認する必要がある|

全楽器や現代音楽の全奏法を網羅する単一の音源は、この調査では確認できていません。専用音色を追加する際には、別楽器のプログラム名を追加するだけで対応済みとしないこと。
