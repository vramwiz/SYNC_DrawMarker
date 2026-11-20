# SYNC_DrawMarker の配布 ZIP

`make_release_zip.bat` はビルド済みの Win64 Release を `SYNC_DrawMarker.zip` にまとめ、`SYNC_DrawMarker.catalog.json` の末尾バージョンに同梱した AUX2 の XXH3-128 を書き込みます。

1. Delphi で Win64 Release をビルドします。既定の参照先は `C:\ProgramData\aviutl2\Plugin\SYNC_DrawMarker` です。
2. `Setup\make_release_zip.bat` を実行します。ハッシュ計算用の `xxhsum.exe` が見つからない場合は、初回に [xxHash 公式 Windows 版](https://github.com/Cyan4973/xxHash/releases/tag/v0.8.4) を取得し、`Win64\Dependencies\xxHash-0.8.4\` に保存します。

別の場所にある Release や、オフラインで使用する `xxhsum.exe` は引数で指定できます。

```bat
Setup\make_release_zip.bat -ReleaseDirectory "D:\Release\SYNC_DrawMarker" -XxhsumPath "D:\Tools\xxhsum.exe"
```

ZIP の `SYNC_DrawMarker/` フォルダに、本体 AUX2、README、GPL ライセンス、第三者ライセンスの一覧、AviUtl2 SDK のライセンスが入ります。手動で導入する場合は、このフォルダを AviUtl2 の `Plugin` フォルダへ配置します。

初版のタグは `v1.0.0` です。公開日が変わる場合は、配布前にカタログの `release_date` を更新してください。
