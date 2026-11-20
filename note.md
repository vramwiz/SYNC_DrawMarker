# SYNC_DrawMarker 作業ノート

## 参照元と構成

- `D:\DelphiProg\MyApp\SYNC_AutoWriting` の Delphi 37.0 / Win64 設定、SDK 型、登録ユニットとライセンスを継承した。SDK 型は公式 2026-11-14 版から本プロジェクトで使う項目を追加した。
- プロジェクト名は `SYNC_DrawMarker`、表示名は「手描きマーカー」、グループは `SYNC`。バージョン `0.1.0` は内部版。正式初版の配布と公開は別途扱う。
- DrawMarker のインストールは本体 AUX2 を使用する。
- 横型スライダーと HSV カラーピッカーは自作の MapRaku から再利用した。
- 参照元やユーザーの AUP2、他プラグインは作業対象外。IDE と AviUtl2 の起動・操作はユーザーの明示依頼がある場合に行う。

## ビルド

プロジェクトルートから実行する。

```powershell
cmd /c 'call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat" && msbuild SYNC_DrawMarker.dproj /t:Rebuild /p:Config=Debug /p:Platform=Win64'
cmd /c 'call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat" && msbuild SYNC_DrawMarker.dproj /t:Rebuild /p:Config=Release /p:Platform=Win64'
```

- Debug / Release は参照元のビルド設定を使用する。配置先は `C:\ProgramData\aviutl2\Plugin\SYNC_DrawMarker\`。DCU は構成別の `Win64\Debug\DCU` と `Win64\Release\DCU`。
- ビルド後イベントは参照元と同じ1行の `copy /Y` と `del /Q` を使い、拡張子は汎用プラグインの AUX2 に合わせる。Release は RSM も削除する。両構成の IDE デバッガーホストは参照元と同じ `D:\aviutl2_v2.1.16\aviutl2.exe`。
- 新しいユニットは DPR の `in` と DPROJ の `DCCReference` に登録する。日本語の .pas / .dpr / .ps1 は UTF-8 BOM 付き・CRLF。
- `Tests\DrawMarker_Smoke.dpr` は描画モデルを検査し、本番 AUX2 を Win64 DLL として読み込み SDK コールバックを模擬する。実機入力取得の検査は [AVIUTL2_FILTER_INPUT_CAPTURE.md](AVIUTL2_FILTER_INPUT_CAPTURE.md) を参照。

## 実装上の判断

- JSON は設定欄に表示する1行文字列項目「描画データ」に格納する。順序は `strokes` 配列で保持し、スキーマは `version` で管理する。元の画像寸法を参照座標として保存する。従来の AUP2 も同じ項目名と形式で読み込める。
- 自由線は座標と時刻を記録し、ペン入力では筆圧も線幅に反映する。マウスの自由線は設定の太さで描く。連続線は位置、相対ハンドル、頂点の種類を記録する。ベジェは評価用の折れ線へ展開し、区間の挿入には de Casteljau 分割を使う。連続線の基準は幅 1920 の画像で 600 px/秒。
- 描画時間はオブジェクト内の時刻と速度の積で求める。画間は作成順につなぐ。完成時の描画バッファを再利用し、各フレームでは入力画像の GPU 読み戻しなしでマーカーのみをアップロードし、SDK の描画ブレンドを使う。
- 設定ボタンに限り入力取得を1件要求する。要求スレッドと描画スレッドで共有するロックはホスト呼び出しの前に解除する。ホスト所有バッファと編集セクションのハンドルは呼び出し内で借用する。
- UI の反映はエフェクト ID、オブジェクト ID、シーンと元の JSON が一致する場合に行う。編集 UI は確定した変更の履歴を最大40操作まで保持する。

## 描画データの保存容量

- v2.1.18b 対応の [公式 SDK（2026-11-14 版）](https://spring-fragrance.mints.ne.jp/aviutl/) の `filter2.h` では、非表示の汎用データ `FILTER_ITEM_DATA` は1項目16 KB以下。`plugin2.h` の `PROJECT_FILE` のバイナリ値は1キー4,096バイト以下で、プラグイン単位の領域に格納される。
- 描画データは ScreenLayout の「配置データ」と同じ `FILTER_ITEM_STRING` で、設定欄に表示する。SDK ヘッダーにこの型の数値上限の記載はない。DrawMarker は書き込み直後の読み戻しを照合し、不一致なら元の値の復元を試みる。
- 現行シリアライザーで合成した自由線400点は23,375バイト、20,000点は1,195,425バイト、上限の80,000点は4,781,555バイトだった。全点が復元でき、同じ JSON に再変換できた。1項目の汎用データへ全ストロークを収納する方式は、この容量に合わない。
- v2.1.18b での大容量データの書き込み、AUP2 への保存と再読み込み後の一致は未確認。

## 2026-11-19 の確認

- Win64 Debug / Release ともに警告0・エラー0。両構成のスモーク検査で JSON 往復、曲線分割、5種のペン、逆シーク、速度、入力要求の一回消費と通常描画時の読み戻し0回を確認した。[ビルド・検査ログ](Win64/LatestVerification/)
- 実機 v2.1.18b の設定ボタンで B を2回検証し、各回で正しい入力を1枚取得した。[検証手順と結果](AVIUTL2_FILTER_INPUT_CAPTURE.md)
- 実機の検証範囲は取得プローブ。製品 UI の一連の操作、実機での AUP2 保存・再起動後の復元、液晶タブレットの実入力は未確認。
- 参照元のビルド設定を適用後、通常の出力先で Debug / Release を再ビルドし、警告0・エラー0を確認。配置した Release は4,446,208 バイト。SHA-256 は `B6BFD1B39049B258E80B6E80667DC89A6DE7DFDBB945F7B35D50659AAD697DF3`。
