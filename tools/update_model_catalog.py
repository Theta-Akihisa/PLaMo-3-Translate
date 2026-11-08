#!/usr/bin/env python3
"""Regenerate shared/models.json from the Hugging Face API.

Download URLs are pinned to a commit (resolve/<revision>/<file>) so that the
size and SHA-256 recorded in the catalog always match what the apps download,
even when PFN re-uploads the files on main. Run this to move to a newer
revision on purpose, then run apple/scripts/sync-shared.sh and the tests.

usage: python3 tools/update_model_catalog.py            # latest main of each repo
       python3 tools/update_model_catalog.py 0.8b=<sha>  # pin a specific revision
"""
import json
import pathlib
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "shared" / "models.json"
QUANT_ORDER = ["Q4_K_M", "Q4_0", "Q3_K_M", "Q2_K"]
META = {
    "0.8b": {"label": "0.8B", "description": "既定。スマートフォンでも高速に動作", "minRamGB": 2, "default": True},
    "2b": {"label": "2B", "description": "精度と速度のバランス", "minRamGB": 4, "default": False},
    "8b": {"label": "8B", "description": "高精度。Mac・PC向け（iPhoneは8GB以上のRAMが必要）", "minRamGB": 8, "default": False},
}


def api(path):
    with urllib.request.urlopen(f"https://huggingface.co/api/{path}", timeout=60) as r:
        return json.load(r)


def main():
    pins = dict(a.split("=", 1) for a in sys.argv[1:])
    models = []
    for size, meta in META.items():
        repo = f"pfnet/plamo-3-translate-{size}-GGUF"
        rev = pins.get(size) or api(f"models/{repo}")["sha"]
        info = api(f"models/{repo}/revision/{rev}?blobs=true")
        by_name = {s["rfilename"]: s for s in info["siblings"]}
        files = []
        for q in QUANT_ORDER:
            name = f"plamo-3-translate-{size}-{q}.gguf"
            s = by_name.get(name)
            if not s:
                continue
            files.append({
                "quant": q,
                "file": name,
                "sizeBytes": s["size"],
                "sha256": s["lfs"]["sha256"],
                "url": f"https://huggingface.co/{repo}/resolve/{rev}/{name}",
            })
        models.append({"id": f"plamo-3-translate-{size}", "size": size, **meta, "repo": repo,
                       "revision": rev, "defaultQuant": "Q4_K_M", "files": files})
        print(f"{repo}@{rev[:10]} ({info.get('lastModified')}): {len(files)} files")
    doc = {
        "description": "PLaMo 3 Translate GGUF model catalog shared by all apps. URLs are pinned to a revision; "
                       "sizes and sha256 come from the Hugging Face API. Regenerate with tools/update_model_catalog.py.",
        "license": {"name": "PLaMo Community License", "url": "https://plamo.preferredai.jp/info/plamo-community-license-ja"},
        "contextLength": {"trained": 32768, "recommended": 8192},
        "generation": {"temperature": 0, "stop": ["<|plamo:tag|>", "<|plamo:bos|>"], "addBos": True},
        "models": models,
    }
    OUT.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
