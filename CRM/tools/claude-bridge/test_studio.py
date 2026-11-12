"""Tests for studio.py without the cut-out model: photo check, main photo rules, swatch. Run: python3 test_studio.py"""
import json, subprocess, sys, tempfile
from pathlib import Path
import numpy as np
from PIL import Image

HERE = Path(__file__).parent
tmp = Path(tempfile.mkdtemp())
fails = 0
def ok(cond, name):
    global fails
    print(("PASS " if cond else "FAIL ") + name); fails += 0 if cond else 1
def job(kind, inputs, params=None):
    out = tmp / f"out_{kind}"
    (tmp / "j.json").write_text(json.dumps({"kind": kind, "inputs": [str(p) for p in inputs], "params": params or {}}))
    subprocess.run([sys.executable, str(HERE / "studio.py"), str(tmp / "j.json"), str(out)], check=True, capture_output=True)
    return json.loads((out / "result.json").read_text()), out

# sharp, well-lit photo vs small blurry dark one
rng = np.random.default_rng(0)
sharp = Image.fromarray((rng.random((2400, 1800, 3)) * 120 + 60).astype(np.uint8)); sharp.save(tmp / "sharp.jpg")
dark = Image.new("RGB", (800, 600), (30, 30, 30)); dark.save(tmp / "dark.jpg")
r, _ = job("check", [tmp / "sharp.jpg", tmp / "dark.jpg"])
ok(r["result"]["0"]["score"] >= 85 and r["result"]["1"]["score"] < 60, "ST-PY1 photo check: good photo scores high, small dark blurry one low")
ok(any(c["code"] == "size" and not c["ok"] for c in r["result"]["1"]["checks"]), "ST-PY2 too small is reported with what to do")

# a cut-out (RGBA) -> main photo
cut = Image.new("RGBA", (900, 1200), (0, 0, 0, 0))
cut.paste(Image.new("RGBA", (800, 1100), (160, 90, 40, 255)), (50, 50))
cut.save(tmp / "cut.png")
r, out = job("main", [tmp / "cut.png"])
m = r["files"][0]
arr = np.asarray(Image.open(out / "main.jpg").convert("RGB"))
ok(arr.shape[:2] == (2000, 2000) and m["meta"]["white_bg"] and (arr[:4] == 255).all() and (arr[:, -4:] == 255).all(), "ST-PY3 main photo: 2000x2000, edges pure white")
ok(80 <= m["meta"]["fill_pct"] <= 90, "ST-PY4 product fills ~85% of the frame")
centre = arr[1000, 1000].astype(int)
ok(abs(centre[0] - 160) < 8 and abs(centre[1] - 90) < 8 and abs(centre[2] - 40) < 8, "ST-PY5 product colour unchanged")

# swatch from a chosen square
Image.new("RGB", (1000, 1000), (150, 80, 40)).save(tmp / "cover.jpg")
r, out = job("swatch", [tmp / "cover.jpg"], {"box": {"x": 0.2, "y": 0.2, "w": 0.3, "h": 0.3}})
sw = Image.open(out / "swatch.jpg")
ok(sw.size == (500, 500) and r["files"][0]["checks"][0]["ok"], "ST-PY6 swatch: 500x500 plain texture")
r, _ = job("nope", [tmp / "cover.jpg"])
ok(r["ok"] is False and "Unknown" in r["error"], "ST-PY7 unknown job reported, not crashed")
print("ALL STUDIO PY TESTS PASSED" if not fails else f"{fails} FAILED"); sys.exit(1 if fails else 0)
