# shared — 全アプリ共通の仕様

iOS / macOS アプリと Chrome 拡張機能は、どれも **PLaMo 3 Translate の公式 GGUF** を llama.cpp 系エンジンで動かし、
PFML3 プロンプトを **アプリ側で直接組み立てて** 補完（completion）させます。実行時に Jinja テンプレートは使いません。

| ファイル | 内容 |
| --- | --- |
| `models.json` | モデルカタログ（0.8B 既定 / 2B / 8B、量子化ごとの URL・サイズ・SHA-256） |
| `languages.json` | 対応 53 言語と言語コード（`<|plamo:key|>lang<|plamo:val|>` に入れる値） |
| `pfml3-test-vectors.json` | 公式チャットテンプレートから生成した PFML3 プロンプトの正解例。各実装のユニットテストで完全一致を確認する |
| `local-api.md` | macOS アプリが公開するローカル API の仕様（Chrome 拡張機能から呼び出す） |
| `chat_template.reference.jinja` | `pfnet/plamo-3-translate-0.8b-GGUF` 同梱の公式テンプレート（原本のコピー） |

テストベクタの再生成: `python3 tools/gen_pfml3_vectors.py`（要 `jinja2`）

## PFML3 プロンプト（翻訳リクエスト → 文字列）

入力: `text`（必須）, `targetLang`（既定 `ja`）, `sourceLang?`, `form?`（`plain`|`polite`、`targetLang == "ja"` のときのみ）,
`context?`, `glossary?: [{source, target}]`, `history?: [{source, translation}]`

```
<|plamo:tag|>dataset<|plamo:msg|>translation
[ <|plamo:tag|>context<|plamo:msg|>{context} ]                                   ← context が空でなければ
{ 各 history について:
  <|plamo:tag|>input[<|plamo:key|>lang<|plamo:val|>{sourceLang}]<|plamo:msg|>{source}
  <|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>{targetLang}<|plamo:msg|>{translation} }
[ <|plamo:tag|>glossary{ <|plamo:index|>{source}<|plamo:item|>{target} ...} ]     ← glossary が空でなければ
<|plamo:tag|>input[<|plamo:key|>lang<|plamo:val|>{sourceLang}]<|plamo:msg|>{text}
<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>{targetLang}[<|plamo:key|>form<|plamo:val|>{form}]<|plamo:msg|>
```

- 改行は入れずに連結する（上は見やすさのための折り返し）。
- 先頭の `<|plamo:bos|>` は **プロンプト文字列に含めず**、トークナイズ時に BOS を付加する（llama.cpp: `add_special = true`, `parse_special = true`）。
- 原文・文脈・用語に `<|plamo:` を含む場合はエラーにする（公式テンプレートと同じ）。
- 生成: `temperature = 0`（greedy）、停止トークン `<|plamo:tag|>` / `<|plamo:bos|>`（EOG 判定でも可）。出力末尾に停止文字列が残れば除去し、前後の空白は保持しない（trim）。
- 学習時の最大長は入出力合計 32,768 トークン。アプリの既定コンテキストは 8,192。長文は段落ごとに分割して翻訳し、直前の段落を `history` に入れると訳語・文体が揃う。
