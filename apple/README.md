# PLaMo Translate（iOS / macOS アプリ）

PFN の **PLaMo 3 Translate**（GGUF）を llama.cpp で端末上に読み込んで動かす、DeepL 風の SwiftUI 翻訳アプリです。
翻訳テキストは端末の外に出ません（通信するのはモデルのダウンロード時のみ）。非公式アプリです。

## 機能

- **2ペイン翻訳画面**: macOS / iPad は左右、iPhone は上下。言語を検出・⇄入れ替え・訳文言語、文字数、×クリア、訳文のコピー/共有/保存
- **入力しながら自動翻訳**: 入力が約 0.5 秒止まると翻訳（ペーストは即時）。編集すると進行中の生成を中断。⌘↩ で手動実行。長文は段落ごとに `translateDocument` で順次表示
- **言語の自動検出**（NaturalLanguage、端末内）。確信度が低い/未対応のときはモデルに原文言語を渡しません。検出言語と訳文言語が同じなら ja⇄en に自動切替
- **文体**（自動 / 常体 / 敬体。訳文が日本語のときのみ）と **用語集**（訳文ペインから開く。設定画面と同じデータ）
- モデル管理（0.8B / 2B / 8B、量子化選択、ダウンロード/キャンセル/削除、メモリ警告）、初回オンボーディング、履歴（直近100件）、設定、About
- **履歴**: 入力しながらの翻訳は途中経過を記録せず、結果が約 4 秒そのままのとき・「翻訳」ボタン/⌘↩・コピー/共有/保存・原文のクリアや置き換えのときに記録します。直前の文章の書き足し・手直しは新しい項目を増やさず先頭を置き換えます。
  「直前の翻訳を文脈として使う」は原文言語・訳文言語が同じ履歴だけを使い、いま翻訳中の文章は除きます。履歴は Application Support 内の `history.json` に保存します（端末の外には出ません）
- **訳文が長さの上限で切れたとき**は、途中までの訳文を表示したまま「設定の最大トークン数を増やすか、文を分けてください」と警告します（翻訳画面・クイック翻訳・ショートカット）。長文は切れた段落の数を表示します。切れた訳は履歴に残しません
- iOS: App Intent「PLaMoで翻訳」（ショートカット）、URL スキーム `plamotranslate://translate?text=...&target=en&source=ja`（macOS でも可）。入力済みの原文を置き換えたときは「元に戻す」を表示します
- macOS: **⌘C を2回押して翻訳**（どのアプリでも）、メニューバーのクイック翻訳、Services メニュー「PLaMoで翻訳」、`.txt` / `.md` のドラッグ&ドロップ、Chrome 拡張機能向けローカル API サーバ（既定で有効、`127.0.0.1:18080`）、URL スキーム `plamotranslate://open`

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

## 文字サイズの調整

原文・訳文の文字サイズを 75%〜300% で変えられます（設定は保存され、全画面で共通）。

| 操作 | macOS | iOS / iPadOS |
| --- | --- | --- |
| 大きく | ⌘+（US 配列は ⌘= でも可、JIS 配列は ⌘⇧;） | 外部キーボードの ⌘+、ピンチアウト |
| 小さく | ⌘− | 外部キーボードの ⌘−、ピンチイン |
| 標準に戻す | ⌘0 | 外部キーボードの ⌘0 |

表示メニュー、訳文ツールバーの「文字サイズ」メニュー、設定画面のスライダーからも変更できます。
macOS ではトラックパッドのピンチ、メニューバーのクイック翻訳・⌘C×2 のパネルにも同じサイズが適用されます。

## 原文と訳文のスクロール連動

原文・訳文のどちらかをスクロールすると、もう片方も対応する位置までスクロールします（長い文書でどこを読んでいるか分かるように）。

- 空行で区切られた段落の数が両方で同じなら **段落単位** で対応づけます（段落の何割まで読んだかも合わせる）。長い文書・PDF は段落ごとに翻訳するので、通常はこの方式になります。
- 段落数が違えば行単位、それも違えば全体に対する割合で合わせます。先頭・末尾は必ずそろえます。
- 訳文の生成中や文字サイズの変更後も、直前にスクロールした側に合わせ直します。
- オン／オフは訳文ツールバーの 🔗 ボタン、または設定画面で切り替えます（既定はオン）。

## ファイルの翻訳（PDF・テキスト・RTF）

PDF（.pdf）、テキスト（.txt / .md）、リッチテキスト（.rtf）を読み込んで翻訳できます。

| 方法 | macOS | iOS / iPadOS |
| --- | --- | --- |
| ファイルを選ぶ | ⌘O、原文欄の「ファイル（PDF など）」ボタン | 原文欄の「ファイル（PDF など）」ボタン、外部キーボードの ⌘O |
| ドラッグ＆ドロップ | Finder から原文欄へ | ファイル App から原文欄へ（iPad の Split View など） |
| 他のアプリから | Finder の「このアプリケーションで開く」 | 共有シートの「PLaMo Translate で開く」 |

- **PDF**: ページの文字を取り出し、行ごとの改行を段落に組み直してから翻訳します（英文の行末ハイフネーションの解除、ページ番号の除去、番号付き見出し・箇条書きの区切り）。
  段落ごとに翻訳し、直前の段落を文脈として渡すため、長い PDF でも訳語・文体がそろいます。
- **スキャン PDF**: 文字情報の無いページは端末内の文字認識（Vision、日本語・英語）で読み取ります。読み取ったページ数は原文欄の下に表示されます。
- パスワード付き PDF は読み込めません。訳文は「訳文を保存」でテキストファイルに書き出せます。

## macOS: ⌘C×2 翻訳とアクセシビリティ権限

1. 初回起動時にシステムの許可ダイアログが出ます（設定 > ショートカット からも再度リクエストできます）
2. システム設定 > プライバシーとセキュリティ > アクセシビリティ でアプリを許可
3. どのアプリでもテキストを選択して ⌘C を 0.4 秒以内に2回押すと、マウス付近に翻訳ウィンドウが開きます

翻訳ウィンドウは文章量に合わせた大きさで開きます（短い文は小さく、長い文は画面の 6 割幅・8 割高さまで）。訳文が見込みより長くなると下に広がります（手で大きさを変えた後は自動では変えません）。
原文と訳文の間の境界線をドラッグすると、それぞれの高さを調整できます。メインウィンドウへ移ると自動で閉じます。

キー入力の内容は保存・送信しません（⌘C の2回押しの検出にのみ使用）。設定でオフにできます。

## Chrome 拡張機能との連携（macOS）

Chrome 拡張機能（`chrome-extension/`）は、**この macOS アプリを翻訳エンジンとして呼び出す方式が既定**です。
アプリは `127.0.0.1:18080` で llama-server 互換のローカル API を公開し、拡張機能はそこへ PFML3 プロンプトを送ります。
仕様（エンドポイント・エラー形式・セキュリティ）は [`shared/local-api.md`](../shared/local-api.md) が正です。

1. このアプリを起動し、「モデル」画面でモデル（0.8B / 2B / 8B）をダウンロードする
2. Chrome 拡張機能をインストールする（既定のバックエンドは「macOS アプリ」、`http://127.0.0.1:18080`）
3. 拡張機能のポップアップ / オプションに「接続済み」と表示されれば完了

- **API サーバは既定で有効**（アプリ起動中は常に待ち受け）。設定 > Chrome 拡張機能 で状態の確認・オン/オフ・ポート変更・接続テスト用 curl のコピーができます。メニューバーのクイック翻訳にも状態を表示します
- ウィンドウを閉じても**メニューバーに常駐**して待ち受けを続けます。設定 > Chrome 拡張機能 >「**ログイン時に起動**」をオンにすると、拡張機能からいつでも使えます（`SMAppService`）
- アプリが起動していないと、拡張機能は「アプリを起動」ボタンで `plamotranslate://open` を開きます（アプリを前面に出し、API サーバを待ち受け状態にします）。設定で API をオフにしている場合は**勝手にオンにせず**、メインウィンドウに「Chrome 拡張機能が接続を求めています」と表示し、「API をオンにする」を押したときだけオンにします
- 拡張機能でモデルサイズを切り替えると `POST /v1/models/select` でアプリの使用モデルも切り替わります（アプリの設定・UI にも反映）。未ダウンロードのモデルは選べないので、アプリでダウンロードしてください
- 翻訳はアプリ内の同じエンジンで直列に実行されます。拡張機能側で中断（接続を閉じる）すると生成も止まります

### セキュリティ

- `127.0.0.1` のみにバインド（LAN からは接続不可）
- `Host` ヘッダが `127.0.0.1` / `localhost`（`:<ポート>` 付きも可）以外なら `403 forbidden_host`（DNS リバインディング対策）
- `Origin` ヘッダがある場合は `chrome-extension://` だけ許可し、一般の Web ページからは `403 forbidden_origin`。`Origin` が無いリクエスト（curl など）は許可
- CORS は許可した Origin をそのまま返し（`*` は使わない）、`Vary: Origin`。プリフライトにも同じ判定を適用し、`Access-Control-Allow-Private-Network: true` を返します
- ボディ上限 1 MB、`Transfer-Encoding: chunked` は非対応

### curl で確認

```sh
curl http://127.0.0.1:18080/health
# {"api":1,"app":"PLaMo Translate","model":{"id":"plamo-3-translate-0.8b","label":"0.8B","loaded":false,"quant":"Q4_K_M","size":"0.8b"},"status":"ok","version":"0.1.0"}
# status: ok (200) / loading (503) / no_model (503: 選択中モデルが未ダウンロード)

curl http://127.0.0.1:18080/v1/models     # 別名 plamo-3-translate + 0.8B / 2B / 8B（installed / active / quant / installed_quants / size_bytes）

# 使用モデルを切り替える（未ダウンロードなら 409 model_not_installed、未知の ID は 404）
curl http://127.0.0.1:18080/v1/models/select -H 'Content-Type: application/json' -d '{"model":"plamo-3-translate-2b"}'

# 生の PFML3 プロンプトを補完（stream:true で SSE）。model は省略可（plamo-3-translate = 選択中モデル）
curl http://127.0.0.1:18080/v1/completions -H 'Content-Type: application/json' -d '{
  "model": "plamo-3-translate",
  "prompt": "<|plamo:tag|>dataset<|plamo:msg|>translation<|plamo:tag|>input<|plamo:msg|>Hello, world!<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>",
  "max_tokens": 256, "temperature": 0, "stream": false
}'

# 便利エンドポイント（PFML3 プロンプトはアプリ側で組み立て）
curl http://127.0.0.1:18080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "messages": [{"role":"user","content":"Hello, world!"}],
  "chat_template_kwargs": {"target_lang":"ja","form":"polite","glossary":[{"source":"world","target":"世界"}]},
  "stream": false
}'

# Web ページからのアクセスは拒否される（403 forbidden_origin）
curl -i http://127.0.0.1:18080/health -H 'Origin: https://example.com'
```

- エラーは OpenAI 互換の `{"error":{"message":"…","type":"model_not_installed","code":409}}`（`type`: `forbidden_host` / `forbidden_origin` / `model_not_installed` / `invalid_request` / `not_found` / `unavailable`（503: モデルの切り替え・解放で生成を中断。再試行可） / `server_error`）
- `/v1/completions` の `model` に別のダウンロード済みモデル ID を指定すると、`/v1/models/select` と同様に切り替えてから実行します
- 停止文字列は `<|plamo:tag|>` / `<|plamo:bos|>` が常に追加されます。温度は常に greedy（`temperature` は無視）
- `finish_reason` は生成が `max_tokens`（またはコンテキストの残り）に達して打ち切られたら `"length"`、EOG・停止文字列で終わったら `"stop"`（非ストリーム・SSE とも）
- `max_tokens`（別名 `n_predict` / `max_completion_tokens`）は省略・0 以下なら 2048、上限 8192 に丸めます。数値でない・巨大な値（`1e30` など）は `400 invalid_request`
- プロンプトがコンテキスト長に収まらない場合は `400 invalid_request`
- 旧バージョンの既定ポート 8080 のままだった設定は、初回起動時に 18080 へ移行します（8080 は拡張機能の「llama-server」バックエンドの既定）

## テスト

`PlamoTranslate-macOS` スキームで ⌘U（`App/Tests/APIRouterTests.swift`: HTTP パーサ / Host・Origin 検査 / プリフライト / `/health`・`/v1/models`・`/v1/models/select` / モデル指定 / `max_tokens` の検証 / `finish_reason` / エラー形式）。

## トラブルシューティング

- **ビルドで Kit の型名エラー**: Kit との接点は `App/Shared/KitBridge.swift` に集約しています。そこだけ修正してください
- **ダウンロードが進まない/失敗**: ネットワークとストレージ空き容量を確認。キャンセル後に再開すると続きから/最初からやり直します
- **iOS で落ちる/すぐ終了する**: メモリ不足の可能性。0.8B か低ビットの量子化（Q3_K_M 等）、コンテキスト長 4096 を試す。バックグラウンド移行時は生成を中断します
- **⌘C×2 が反応しない**: アクセシビリティ権限を確認（許可後は数秒かかります。再起動が必要な場合も）
- **ローカル API が起動しない / 拡張機能が接続できない**: 設定 > Chrome 拡張機能 の状態を確認。ポートの競合（`lsof -i :18080`）なら別のポート（1024〜65535）にして拡張機能のオプションも合わせる。`curl http://127.0.0.1:18080/health` で応答を確認
- **シミュレータで動かない**: 仕様です（実機のみ）

## ライセンス・クレジット

モデルは [PLaMo Community License](https://plamo.preferredai.jp/info/plamo-community-license-ja) に従います（商用利用は Preferred Networks への登録が必要）。llama.cpp は MIT License。アプリ内「このアプリについて」にも記載しています。
