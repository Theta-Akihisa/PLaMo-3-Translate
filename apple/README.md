# PLaMo Translate（iOS / macOS アプリ）

PFN の **PLaMo 3 Translate**（GGUF）を llama.cpp で端末上に読み込んで動かす、DeepL 風の SwiftUI 翻訳アプリです。
翻訳テキストは端末の外に出ません（通信するのはモデルのダウンロード時のみ）。非公式アプリです。

## 機能

- **2ペイン翻訳画面**: macOS / iPad は左右、iPhone は上下。言語を検出・⇄入れ替え・訳文言語、文字数、×クリア、訳文のコピー/共有/保存
- **入力しながら自動翻訳**: 入力が約 0.5 秒止まると翻訳（ペーストは即時）。編集すると進行中の生成を中断。⌘↩ で手動実行。長文は段落ごとに `translateDocument` で順次表示
- **言語の自動検出**（NaturalLanguage、端末内）。確信度が低い/未対応のときはモデルに原文言語を渡しません。検出言語と訳文言語が同じなら ja⇄en に自動切替
- **文体**（自動 / 常体 / 敬体。訳文が日本語のときのみ）と **用語集**（訳文ペインから開く。設定画面と同じデータ）
- モデル管理（0.8B / 2B / 8B、量子化選択、ダウンロード/キャンセル/削除、メモリ警告）、初回オンボーディング、履歴（直近100件）、設定、About
- iOS: App Intent「PLaMoで翻訳」（ショートカット）、URL スキーム `plamotranslate://translate?text=...&target=en&source=ja`
- macOS: **⌘C を2回押して翻訳**（どのアプリでも）、メニューバーのクイック翻訳、Services メニュー「PLaMoで翻訳」、`.txt` / `.md` のドラッグ&ドロップ、ローカル API サーバ

## 必要環境

- Xcode 16 以上、macOS 14 / iOS 17 以上
- **実機（iPhone / iPad / Mac）のみ**。同梱の `llama.xcframework` に iOS シミュレータ用スライスが無いため、シミュレータでは動きません
- XcodeGen（`brew install xcodegen`）。`PlamoTranslateKit`（Swift Package）は `apple/PlamoTranslateKit` にあります

## セットアップ

```sh
cd apple
./scripts/bootstrap.sh      # または make project
open PlamoTranslate.xcodeproj
```

1. `project.yml` のバンドル ID（プレースホルダ `jp.example.plamotranslate`）を自分のものに変更し、`DEVELOPMENT_TEAM` を設定（または Xcode の Signing & Capabilities で Team を選択）して再生成
2. スキーム `PlamoTranslate-iOS`（実機）または `PlamoTranslate-macOS` を実行
3. iOS は `com.apple.developer.kernel.increased-memory-limit` エンタイトルメントを使います（2B/8B に必要）。有料 Developer Program のアカウントで、App ID にこの機能が付与される必要があります

### macOS はサンドボックス無し

⌘C×2 のグローバル監視（`NSEvent.addGlobalMonitorForEvents`、アクセシビリティ権限）が App Sandbox と相性が悪いため、macOS ターゲットは **App Sandbox 無効 + Hardened Runtime 有効** です。
そのため **Mac App Store ではなく Developer ID 署名 + Notarization での配布**向けです。

## モデルのダウンロードと保存先

モデルは Hugging Face（`pfnet/plamo-3-translate-*-GGUF`）から `ModelStore` がダウンロードし、アプリのデータ領域（Application Support 配下）に保存されます。SHA-256 を検証します。
「モデル」画面で削除できます。macOS では手元の GGUF を「GGUFファイルを読み込む…」で取り込めます。

| モデル | 既定量子化 | サイズ | メモリ目安 |
| --- | --- | --- | --- |
| 0.8B（既定） | Q4_K_M | 約 0.57 GB | 2 GB 以上。iPhone でも快適 |
| 2B | Q4_K_M | 約 1.8 GB | 4 GB 以上。上位 iPhone / iPad / Mac |
| 8B | Q4_K_M | 約 5.3 GB | 8 GB 以上。Mac 推奨。iPhone は 8GB 機のみ・他アプリを終了 |

コンテキスト長を大きくするとメモリが増えます（既定 8192）。iOS は不足時に 2B/8B を無効化、Mac は警告のみです。

## macOS: ⌘C×2 翻訳とアクセシビリティ権限

1. 初回起動時にシステムの許可ダイアログが出ます（設定 > ショートカット からも再度リクエストできます）
2. システム設定 > プライバシーとセキュリティ > アクセシビリティ でアプリを許可
3. どのアプリでもテキストを選択して ⌘C を 0.4 秒以内に2回押すと、マウス付近に翻訳ウィンドウが開きます

キー入力の内容は保存・送信しません（⌘C の2回押しの検出にのみ使用）。設定でオフにできます。

## macOS: ローカル API（llama-server 互換）

設定 > ローカルAPI で有効化（既定オフ、127.0.0.1:8080 のみ。ポート変更可）。

```sh
curl http://127.0.0.1:8080/health
curl http://127.0.0.1:8080/v1/models

# 生の PFML3 プロンプトを補完（stream:true で SSE）
curl http://127.0.0.1:8080/v1/completions -H 'Content-Type: application/json' -d '{
  "prompt": "<|plamo:tag|>dataset<|plamo:msg|>translation<|plamo:tag|>input<|plamo:msg|>Hello, world!<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>",
  "max_tokens": 256, "temperature": 0, "stream": false
}'

# 便利エンドポイント（PFML3 プロンプトはアプリ側で組み立て）
curl http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "messages": [{"role":"user","content":"Hello, world!"}],
  "chat_template_kwargs": {"target_lang":"ja","form":"polite","glossary":[{"source":"world","target":"世界"}]},
  "stream": false
}'
```

- 停止文字列は `<|plamo:tag|>` / `<|plamo:bos|>` が常に追加されます。温度は常に greedy（`temperature` は無視）
- CORS（`Access-Control-Allow-Origin: *`）と OPTIONS プリフライトに対応。ボディ上限 1 MB、`Transfer-Encoding: chunked` は非対応
- **Chrome 拡張機能**: オプションでエンドポイントを `http://127.0.0.1:8080` にし、本アプリでサーバを有効にしてモデルをダウンロードしておく（`/health` が 200 になれば接続済み）

## テスト

`PlamoTranslate-macOS` スキームで ⌘U（`App/Tests/APIRouterTests.swift`: HTTP パーサ / ルータ / レスポンス形式）。

## トラブルシューティング

- **ビルドで Kit の型名エラー**: Kit との接点は `App/Shared/KitBridge.swift` に集約しています。そこだけ修正してください
- **ダウンロードが進まない/失敗**: ネットワークとストレージ空き容量を確認。キャンセル後に再開すると続きから/最初からやり直します
- **iOS で落ちる/すぐ終了する**: メモリ不足の可能性。0.8B か低ビットの量子化（Q3_K_M 等）、コンテキスト長 4096 を試す。バックグラウンド移行時は生成を中断します
- **⌘C×2 が反応しない**: アクセシビリティ権限を確認（許可後は数秒かかります。再起動が必要な場合も）
- **ローカル API が起動しない**: ポートの競合（`lsof -i :8080`）。1024〜65535 で指定
- **シミュレータで動かない**: 仕様です（実機のみ）

## ライセンス・クレジット

モデルは [PLaMo Community License](https://plamo.preferredai.jp/info/plamo-community-license-ja) に従います（商用利用は Preferred Networks への登録が必要）。llama.cpp は MIT License。アプリ内「このアプリについて」にも記載しています。
