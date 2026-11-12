#!/usr/bin/env python3
"""Nitaniya Studio AI backgrounds: runs on the owner's Mac (Apple silicon), called by bridge.mjs.

  python3 studio_ai.py setup <aidir>               first time: download Z-Image-Turbo, save a 4-bit copy, remove the download
  python3 studio_ai.py gen <job.json> <outdir>     2 empty backgrounds for a theme -> <outdir>/result.json

Free and local: mflux (MIT) running Z-Image-Turbo (Tongyi-MAI, Apache-2.0) with Apple MLX. 4-bit keeps it near 6-8 GB RAM,
safe on a 16 GB Mac Mini M4. Only the BACKGROUND is generated: the diary in every scene is the owner's real photo,
placed on top afterwards. Prompts always ask for an empty middle and no people, hands, text, logos or books.
"""
import json
import shutil
import sys
from pathlib import Path

QUANT = 4
GEN = 1024           # generated size; scaled to 2000 for the scene (the background is softened anyway)
STEPS = 9

THEMES = {
    "desk": "a clean wooden study desk beside a window, a cup of tea and a small potted plant at the far edges",
    "gift": "a festive gift table with wrapped gift boxes and satin ribbon at the far edges",
    "cafe": "a cozy cafe table with a cup of coffee at the far edge",
    "office": "a modern minimal office desk with a closed laptop at the far edge",
    "festive": "an Indian Diwali table with lit clay diyas and marigold petals at the far edges",
    "nature": "a weathered wooden bench outdoors with soft green leaves behind it",
}
TAIL = ("empty space in the middle of the surface, eye-level view, soft natural light, shallow depth of field, realistic photograph, "
        "no people, no hands, no text, no letters, no logos, no books, no notebooks, no diaries")


def model_dir(aidir):
    return Path(aidir) / "zimage-turbo-q4"


def setup(aidir):
    from mflux.models.z_image import ZImage
    aidir = Path(aidir)
    aidir.mkdir(parents=True, exist_ok=True)
    m = ZImage(quantize=QUANT)                  # downloads to HF_HOME (set by the bridge to <aidir>/hf)
    tmp = aidir / "zimage-turbo-q4.tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    m.save_model(str(tmp))
    shutil.rmtree(model_dir(aidir), ignore_errors=True)
    tmp.rename(model_dir(aidir))
    shutil.rmtree(aidir / "hf", ignore_errors=True)   # the full download is no longer needed (~30 GB freed)
    print("ready")


def gen(job, outdir):
    from mflux.models.z_image import ZImage
    from PIL import Image
    p = job.get("params") or {}
    theme = THEMES.get(p.get("theme"))
    if not theme:
        raise ValueError("Unknown theme")
    words = str(p.get("words") or "")[:120]
    prompt = f"{theme}{', ' + words if words else ''}, {TAIL}"
    seed = int(p.get("seed") or 1)
    m = ZImage(model_path=str(model_dir(job["aidir"])))      # the saved copy is already 4-bit
    files = []
    for i in range(2):
        img = m.generate_image(seed=seed + i, prompt=prompt, num_inference_steps=STEPS, width=GEN, height=GEN)
        raw = Path(outdir) / f"raw{i}.png"
        img.save(str(raw), overwrite=True)
        im = Image.open(raw).convert("RGB").resize((2000, 2000), Image.LANCZOS)
        name = f"background_{i}.jpg"
        im.save(Path(outdir) / name, "JPEG", quality=92, subsampling=0)
        files.append({"name": name, "kind": "background", "width": 2000, "height": 2000, "checks": [], "score": None,
                      "meta": {"source": "ai", "model": "Z-Image-Turbo (4-bit, mflux)", "theme": p.get("theme"), "words": words, "seed": seed + i}})
    return {"ok": True, "result": {"prompt": prompt}, "files": files}


if __name__ == "__main__":
    if sys.argv[1] == "setup":
        setup(sys.argv[2])
        sys.exit(0)
    job = json.loads(Path(sys.argv[2]).read_text())
    out = Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    try:
        res = gen(job, out)
    except Exception as e:
        res = {"ok": False, "error": str(e)[:300]}
    (out / "result.json").write_text(json.dumps(res))
    print(json.dumps({"ok": res["ok"]}))
