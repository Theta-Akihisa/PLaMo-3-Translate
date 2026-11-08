#!/usr/bin/env python3
"""Generate shared/pfml3-test-vectors.json from the official chat template.

The official GGUF chat template (shared/chat_template.reference.jinja, copied
verbatim from pfnet/plamo-3-translate-0.8b-GGUF) is the source of truth for the
PFML3 prompt format. Every app in this repository builds PFML3 prompts itself
(no Jinja at runtime), and must reproduce these vectors byte for byte.

`bos_token` is rendered as "" because llama.cpp adds <|plamo:bos|> itself when
tokenizing with add_special=true; the apps must do the same.

usage: python3 -I tools/gen_pfml3_vectors.py
"""
import json
import pathlib

from jinja2.sandbox import ImmutableSandboxedEnvironment

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "shared" / "chat_template.reference.jinja"
OUT = ROOT / "shared" / "pfml3-test-vectors.json"


def raise_exception(msg):
    raise ValueError(msg)


# Each case uses the request shape every app implements:
#   text (required), target_lang (default "ja"), source_lang, form, context,
#   glossary [{source, target}], history [{source, translation}]
CASES = [
    {"name": "basic_en_to_ja", "text": "The meeting has been rescheduled to next Monday.", "target_lang": "ja"},
    {"name": "ja_to_en", "text": "会議は来週の月曜日に変更されました。", "target_lang": "en"},
    {"name": "explicit_source", "text": "Hello.", "source_lang": "en", "target_lang": "ja"},
    {"name": "form_plain", "text": "This system is convenient.", "target_lang": "ja", "form": "plain"},
    {"name": "form_polite", "text": "This system is convenient.", "target_lang": "ja", "form": "polite"},
    {"name": "context", "text": "The bank was muddy.", "target_lang": "ja",
     "context": "They were walking beside a river after heavy rain."},
    {"name": "glossary", "text": "Please open the project dashboard.", "target_lang": "ja",
     "glossary": [{"source": "dashboard", "target": "管理画面"}, {"source": "project", "target": "プロジェクト"}]},
    {"name": "history", "text": "You can also filter them by owner.", "source_lang": "en", "target_lang": "ja",
     "history": [
         {"source": "Open the project dashboard.", "translation": "プロジェクトの管理画面を開きます。"},
         {"source": "It lists all active tasks.", "translation": "進行中のタスクがすべて表示されます。"},
     ]},
    {"name": "all_options", "text": "You can also filter them by owner.", "source_lang": "en", "target_lang": "ja",
     "context": "Help page of a project management tool.",
     "glossary": [{"source": "owner", "target": "オーナー"}], "form": "polite",
     "history": [
         {"source": "Open the project dashboard.", "translation": "プロジェクトの管理画面を開きます。"},
         {"source": "It lists all active tasks.", "translation": "進行中のタスクがすべて表示されます。"},
     ]},
    {"name": "zh_hans_target", "text": "Good morning.", "target_lang": "zh-hans"},
    {"name": "easy_japanese", "text": "Evacuate to higher ground immediately.", "target_lang": "ja-easy"},
    # 旧表記 ja(easy) は公式テンプレートで ja-easy の別名として扱われる
    {"name": "easy_japanese_alias", "text": "Evacuate to higher ground immediately.", "target_lang": "ja(easy)"},
    {"name": "multiline_text", "text": "Line one.\nLine two.\n\nParagraph two with `code`.", "target_lang": "ja"},
]


def render(env, case):
    messages = []
    for pair in case.get("history", []):
        messages.append({"role": "user", "content": pair["source"]})
        messages.append({"role": "assistant", "content": pair["translation"]})
    messages.append({"role": "user", "content": case["text"]})
    kwargs = {k: case[k] for k in ("target_lang", "source_lang", "form", "context", "glossary") if k in case}
    tpl = env.from_string(TEMPLATE.read_text(encoding="utf-8"))
    return tpl.render(messages=messages, bos_token="", raise_exception=raise_exception, **kwargs)


def main():
    env = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True)
    vectors = []
    for case in CASES:
        inp = {k: v for k, v in case.items() if k != "name"}
        vectors.append({"name": case["name"], "input": inp, "prompt": render(env, case)})
    doc = {
        "description": "PFML3 prompts rendered from the official PLaMo 3 Translate GGUF chat template "
                       "(bos_token omitted: add it via the tokenizer). Regenerate with tools/gen_pfml3_vectors.py.",
        "stop": ["<|plamo:tag|>", "<|plamo:bos|>"],
        "vectors": vectors,
    }
    OUT.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(vectors)} vectors to {OUT}")


if __name__ == "__main__":
    main()
