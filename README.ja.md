# Simple LUT

[English](README.md) | 日本語

バージョンは [`VERSION`](VERSION)、変更履歴は [`CHANGELOG.md`](CHANGELOG.md) を参照してください。

Simple LUT は 3D LUT（`.cube`・`.3dl`・`.m3d`）を、最近傍・四面体・トライリニアのいずれかの補間で
適用します。8bit の入力値は `x * (size - 1) / 255` で格子点に対応付けられ、ffmpeg の `lut3d`
フィルタとの差は 1 階調以内です。格子サイズは 129 点まで対応しています。`DOMAIN_MIN`/`DOMAIN_MAX`
と `LUT_3D_INPUT_RANGE` は入力範囲として扱い、アルファが 0 のピクセルは変更しません。

> **0.5.0 で出力が変わりました。** 以前のバージョンは元プロジェクトの `size / 256` という入力スケールを
> 引き継いでおり、色が全体的に明るい側へずれ、ハイライトが飛んでいました。詳しくは変更履歴を
> 参照してください。

## 単体の PNG 変換ツール

```sh
zig build
zig build run -- test/sample.png test/MagicHour.cube test/output.png tetrahedral
```

引数は `<入力.png> <LUT> <出力.png> [nearest|tetrahedral|trilinear] [強さ]` です。ビルドには
システムの `libpng` 開発用ライブラリが必要です。`simple-lut --diff a.png b.png [許容差]` で
2 枚の画像を比較できます。

## ベンチマーク

プラグインと同じマルチスレッドのピクセル処理（論理 CPU 数のスレッド、最大 16）の速度を測ります。PNG の読み込みと
LUT の読み込みは計測の前に済ませます。

```sh
zig build benchmark
zig build benchmark -- test/sample.png test/MagicHour.cube 50
```

## AviUtl（1.x）用スクリプトプラグイン

Visual Studio や MinGW なしで 32bit DLL をビルドできます。

```sh
zig build plugin -Doptimize=ReleaseSmall
```

`zig-out/bin/Simple_LUT.dll` と `Simple_LUT.anm` を `exedit.auf` と同じ場所にある `script`
フォルダにコピーし、AviUtl を再起動してください。オブジェクトにアニメーション効果として
Simple LUT を追加して使います。

DLL は `lua51.dll` を動的に読み込み、解析済みの LUT を DLL 内に最大 16 個キャッシュします。
LUT ファイルがディスク上で変更されると自動的に読み込み直します。Extram は不要になりました。
Lua からは次のように呼び出します（`type`: 1 最近傍、2 四面体、3 トライリニア）。

```lua
local ok, err = Simple_LUT.LUT(data, w, h, strength, type, path) -- 成功時は true、失敗時は nil とエラーメッセージ
```

DLL は Universal C Runtime を使用します。Windows 10 以降には標準で含まれています。
Windows 7 / 8.1 では先に
[Universal C Runtime の更新プログラム（KB2999226）](https://support.microsoft.com/kb/2999226)
をインストールしてください。

`Simple_LUT.anm` の改行コードは Windows 形式（CRLF）のままにしてください。改行が LF だと
拡張編集はスクリプトを実行しませんが、多くのエディタでは見た目に違いがありません。Git による
変換は `.gitattributes` で防いでいるので、編集して保存する前にエディタの改行コード設定を
確認してください。

## AviUtl2 用ネイティブフィルタ

```sh
zig build aviutl2 -Doptimize=ReleaseSmall
```

`zig-out/bin/Simple_LUT.auf2` を AviUtl2 のデータフォルダ内にある `Plugin` フォルダにコピーし、
AviUtl2 を再起動してください。

- インストール版: `C:\ProgramData\aviutl2\Plugin`
- ポータブル版（`aviutl2.exe` の隣に `data` フォルダがある場合）: `data\Plugin`。
  `aviutl2.exe` と同じ場所にある `Plugin` フォルダは読み込まれません。

`.auf2` を AviUtl2 のプレビュー画面にドラッグ＆ドロップしても、正しいフォルダにインストールされます。

フィルタには LUT ファイルの選択、強さ、補間方法の設定項目があります。LUT は最大 16 個まで
キャッシュされます。パスはワイド文字の API で開くため、日本語などを含むフォルダ名でも使えます。

フィルタが表示されない場合は、`zig build debug-plugins` で何もしないテスト用フィルタをビルドし、
`zig-out/debug/NoopFilterCpp.auf2`（公式 SDK のヘッダからビルド）と `NoopFilterZig.auf2`
（Simple LUT と同じ方法でビルド）を同じ手順でインストールしてください。どちらも「Noop filter」
として表示され、AviUtl2 からの呼び出しを `C:\Users\Public\aviutl2_noop.log` に記録します。
ログが空なら AviUtl2 はこれらを読み込んでおらず、たいていはコピー先のフォルダが間違っています。
ビルドには `sdk-check` と同じく SDK が必要です。

## テスト

| コマンド | 確認する内容 |
| --- | --- |
| `zig build test` | パーサ（各種サイズ・ビット深度の恒等 LUT、不正なファイル、`DOMAIN`）、ピクセル処理、キャッシュ。メモリリークがあるとテストが失敗します。 |
| `zig build golden` | 全補間方法について ffmpeg の `lut3d` と出力を比較します（`ffmpeg` が必要）。`--` の後に LUT を指定すると追加で確認できます。 |
| `LUA51_DLL=<aviutl>/lua51.dll tools/run_harness.sh` | 実際の `.auf2` と `.dll`（後者は AviUtl の Lua 経由）を Wine 上、または Windows 上で読み込み、ASCII 名と日本語名の両方のフォルダから動作を確認します。 |
| `zig build sdk-check` | `aviutl2_layout.zig` を AviUtl2 SDK のヘッダと照合します（既定は `../aviutl2_sdk`、`-Daviutl2-sdk=<dir>` で変更可。Windows 以外では Wine が必要）。`aviutl2_sdk.zig` はこの構造体レイアウトをコンパイル時に検証します。 |

CI（`.github/workflows/ci.yml`）は Linux でテストと ffmpeg との比較を、Windows でハーネスを
実行します。

リリース前には、Wine 上の実際の AviUtl と AviUtl2、続いて Windows の仮想マシンで、次の項目を
手作業で確認してください：ファイル選択、プロジェクトの保存と再読み込み、異なる LUT を使う
2 つのオブジェクト、使用中の LUT ファイルの書き換え。

## ライセンス

Simple LUT 0.4.0 以降は元の ffmpeg 実装をもとに全面的に書き直したもので、
[LGPLv2.1 ライセンス](./LICENSE)に従います。

0.4.0 より前のバージョンは
[こちらの実装](https://github.com/cpuimage/FFmpeg_Lut3D/)に基づいており、GPLv2.1 ライセンスに
従います。
