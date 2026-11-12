#!/usr/bin/env python3
"""Nitaniya Studio worker: runs on the owner's Mac, called by bridge.mjs for one photo job at a time.

  python3 studio.py <job.json> <outdir>

job.json: {"kind": "check" | "cutout" | "main" | "swatch" | "scene" | "sheet", "inputs": ["/path/a.jpg", ...], "params": {...}}
Writes <outdir>/result.json: {"ok": true, "result": {...}, "files": [{"name", "kind", "width", "height", "checks", "score"}]}

Rule: the product's own pixels are never redrawn. Cut-out only removes the background; the main photo only places the
cut-out on pure white. Free, open model only: rembg with IS-Net (Apache-2.0); ~1.3-2.4 GB RAM, safe on a 16 GB Mac.
(BiRefNet was tested and rejected: it needs more than 8 GB RAM and could freeze the Mac.)
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps

MAIN_SIZE = 2000          # Amazon zoom needs >= 1000 px; 2000 gives a sharp zoom
MAIN_FILL = 0.85          # product fills ~85% of the frame (Amazon guidance for the main image)
MIN_SIDE = 1600           # below this we ask for a better photo
MAX_BYTES = 10 * 1024 * 1024


def load(path):
    im = Image.open(path)
    im = ImageOps.exif_transpose(im)      # phone photos: respect the rotation flag
    return im


def sharpness(gray):
    """Variance of the Laplacian on a 1024 px copy: low = blurry."""
    g = gray.astype(np.float32)
    lap = -4 * g[1:-1, 1:-1] + g[:-2, 1:-1] + g[2:, 1:-1] + g[1:-1, :-2] + g[1:-1, 2:]
    return float(lap.var())


def photo_checks(im):
    """Is this upload good enough to work from? Returns (checks, score 0-100)."""
    w, h = im.size
    small = im.convert("RGB").copy()
    small.thumbnail((1024, 1024))
    a = np.asarray(small).astype(np.float32)
    gray = a.mean(axis=2)
    sharp = sharpness(gray)
    bright = float(gray.mean())
    glare = float(((a > 250).all(axis=2)).mean() * 100)
    checks = []

    def add(code, ok, msg, warn=False):
        checks.append({"code": code, "ok": ok, "level": "ok" if ok else ("warn" if warn else "bad"), "message": msg})

    add("size", max(w, h) >= MIN_SIDE, f"{w}x{h} px" + ("" if max(w, h) >= MIN_SIDE else f": take it closer or in higher quality (at least {MIN_SIDE} px)"))
    add("sharp", sharp >= 60, "Sharp" if sharp >= 60 else "Looks blurry: hold the phone still, tap to focus on the cover", warn=sharp >= 30)
    if bright < 70:
        add("light", False, "Too dark: shoot near a window in daylight", warn=bright >= 50)
    elif bright > 235:
        add("light", False, "Too bright / washed out: move away from direct sun", warn=True)
    else:
        add("light", True, "Good light")
    add("glare", glare < 4, "No strong glare" if glare < 4 else f"Glare on {glare:.0f}% of the photo: tilt the diary so the light does not reflect", warn=glare < 10)
    score = 100
    for c in checks:
        score -= 0 if c["ok"] else (12 if c["level"] == "warn" else 30)
    return checks, max(0, score), {"sharpness": round(sharp, 1), "brightness": round(bright, 1), "glare_pct": round(glare, 2)}


_SESSION = None


def cutout(path, mode):
    """mode "soft": natural soft edges. mode "fine": extra edge refinement (alpha matting) for straps, clasps, stitching."""
    global _SESSION
    from rembg import new_session, remove
    if _SESSION is None:
        _SESSION = new_session("isnet-general-use")
    im = load(path).convert("RGB")
    if mode == "fine":
        im.thumbnail((1800, 1800))
        out = remove(im, session=_SESSION, alpha_matting=True, alpha_matting_foreground_threshold=240,
                     alpha_matting_background_threshold=15, alpha_matting_erode_size=8)
    else:
        im.thumbnail((2600, 2600))
        out = remove(im, session=_SESSION)
    a = np.asarray(out)[:, :, 3]
    ys, xs = np.where(a > 8)
    if len(xs) == 0:
        raise ValueError("No product found in the photo")
    pad = 8
    box = (max(0, xs.min() - pad), max(0, ys.min() - pad), min(out.width, xs.max() + pad + 1), min(out.height, ys.max() + pad + 1))
    out = out.crop(box)
    cover = float((a > 128).mean() * 100)
    soft = float(((a > 8) & (a < 247)).sum() / max(1, (a > 128).sum()) * 100)   # % of half-transparent edge pixels
    return out, {"product_area_pct": round(cover, 1), "soft_edge_pct": round(soft, 2)}


def white_border(arr, frame=4):
    top, bottom = arr[:frame], arr[-frame:]
    left, right = arr[:, :frame], arr[:, -frame:]
    return all(bool((x == 255).all()) for x in (top, bottom, left, right))


def make_main(path, out_path):
    """Cut-out (RGBA) -> 2000x2000 pure white JPEG, product ~85% of the frame. Pixels are only scaled, never redrawn."""
    cut = load(path).convert("RGBA")
    a = np.asarray(cut)[:, :, 3]
    ys, xs = np.where(a > 8)
    cut = cut.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))
    scale = (MAIN_SIZE * MAIN_FILL) / max(cut.size)
    cut = cut.resize((max(1, round(cut.width * scale)), max(1, round(cut.height * scale))), Image.LANCZOS)
    canvas = Image.new("RGB", (MAIN_SIZE, MAIN_SIZE), (255, 255, 255))
    x, y = (MAIN_SIZE - cut.width) // 2, (MAIN_SIZE - cut.height) // 2
    alpha = np.asarray(cut)[:, :, 3].astype(np.float32) / 255.0
    alpha[alpha < 0.03] = 0.0                       # no grey haze around the product
    rgb = np.asarray(cut)[:, :, :3].astype(np.float32)
    region = np.asarray(canvas)[y:y + cut.height, x:x + cut.width].astype(np.float32)
    mixed = rgb * alpha[..., None] + region * (1 - alpha[..., None])
    arr = np.asarray(canvas).copy()
    arr[y:y + cut.height, x:x + cut.width] = np.clip(mixed + 0.5, 0, 255).astype(np.uint8)
    Image.fromarray(arr).save(out_path, "JPEG", quality=93, subsampling=0, optimize=True)
    # re-open what Amazon will receive and check it
    back = np.asarray(Image.open(out_path).convert("RGB"))
    fill = max(cut.size) / MAIN_SIZE * 100
    size = Path(out_path).stat().st_size
    checks = [
        {"code": "white_bg", "ok": white_border(back), "level": "ok" if white_border(back) else "bad",
         "message": "Pure white background (255,255,255)" if white_border(back) else "Edges are not pure white"},
        {"code": "fill", "ok": 80 <= fill <= 90, "level": "ok" if 80 <= fill <= 90 else "warn", "message": f"Product fills {fill:.0f}% of the frame"},
        {"code": "size", "ok": True, "level": "ok", "message": f"{MAIN_SIZE}x{MAIN_SIZE} px (zoom works)"},
        {"code": "bytes", "ok": size < MAX_BYTES, "level": "ok" if size < MAX_BYTES else "bad", "message": f"{size / 1e6:.1f} MB"},
        {"code": "no_text", "ok": True, "level": "ok", "message": "Nothing added: no text, logo or props"},
    ]
    return checks, {"white_bg": white_border(back), "fill_pct": round(fill, 1), "bytes": size}


def make_swatch(path, box, out_path):
    """A clean colour swatch: a square of the real cover texture (the owner picks it, away from any text)."""
    im = load(path).convert("RGB")
    W, H = im.size
    x, y, w, h = (float(box.get(k, 0)) for k in ("x", "y", "w", "h"))
    side = max(8, int(min(w * W, h * H)))
    left, top = int(x * W), int(y * H)
    crop = im.crop((left, top, min(W, left + side), min(H, top + side))).resize((500, 500), Image.LANCZOS)
    crop.save(out_path, "JPEG", quality=92, subsampling=0)
    arr = np.asarray(crop).astype(np.float32)
    spread = float(arr.std(axis=(0, 1)).mean())
    checks = [{"code": "plain", "ok": spread < 40, "level": "ok" if spread < 40 else "warn",
               "message": "Plain texture, no text" if spread < 40 else "Busy area: make sure there is no text or logo in it"}]
    return checks, {"spread": round(spread, 1)}

SCENE_SIZE = 2000
FONTS = ["/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/SFNS.ttf", "/Library/Fonts/Arial.ttf",
         "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]


def font(size):
    for f in FONTS:
        if Path(f).exists():
            try:
                return ImageFont.truetype(f, size)
            except OSError:
                continue
    return ImageFont.load_default(size=size)


def cover_square(im, side):
    """Fill a square with the background photo (centre crop, like CSS cover)."""
    r = max(side / im.width, side / im.height)
    im = im.resize((max(side, round(im.width * r)), max(side, round(im.height * r))), Image.LANCZOS)
    x, y = (im.width - side) // 2, (im.height - side) // 2
    return im.crop((x, y, x + side, y + side))


def make_scene(cut_path, bg_path, params, out_path, small_path):
    """Real cut-out on a background photo. The product's pixels are only scaled; the background is softened a little so the
    product stays the sharp subject, and a soft shadow grounds it. Optional small "Props not included" note."""
    side = SCENE_SIZE
    bg = cover_square(load(bg_path).convert("RGB"), side).filter(ImageFilter.GaussianBlur(1.6))
    cut = load(cut_path).convert("RGBA")
    a = np.asarray(cut)[:, :, 3]
    ys, xs = np.where(a > 8)
    if len(xs) == 0:
        raise ValueError("The cut-out is empty")
    cut = cut.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))
    scale = float(params.get("scale", 0.5))
    w = side * scale
    h = w * cut.height / cut.width
    if h > side * 0.85:                       # tall products: keep inside the frame
        h = side * 0.85
        w = h * cut.width / cut.height
    cut = cut.resize((max(1, round(w)), max(1, round(h))), Image.LANCZOS)
    cx, cy = float(params.get("x", 0.5)) * side, float(params.get("y", 0.55)) * side
    x = int(min(max(cx - cut.width / 2, side * 0.02), side * 0.98 - cut.width))
    y = int(min(max(cy - cut.height / 2, side * 0.02), side * 0.98 - cut.height))
    # soft drop shadow + contact shadow under the product
    alpha = cut.split()[3]
    shadow = Image.new("L", (side, side), 0)
    off = int(cut.width * 0.025)
    shadow.paste(alpha.point(lambda v: int(v * 0.38)), (x + off, y + off * 2))
    d = ImageDraw.Draw(shadow)
    d.ellipse((x + cut.width * 0.04, y + cut.height - cut.height * 0.03, x + cut.width * 0.96, y + cut.height + cut.height * 0.035), fill=95)
    shadow = shadow.filter(ImageFilter.GaussianBlur(max(6, cut.width * 0.03)))
    dark = Image.new("RGB", (side, side), (25, 20, 15))
    bg = Image.composite(dark, bg, shadow)
    bg.paste(cut, (x, y), cut)
    if params.get("note", True):
        f = font(38)
        text = "Props not included"
        d = ImageDraw.Draw(bg, "RGBA")
        tw = d.textlength(text, font=f)
        px, py = 44, side - 44 - 64
        d.rounded_rectangle((px, py, px + tw + 48, py + 64), radius=32, fill=(255, 255, 255, 215))
        d.text((px + 24, py + 12), text, font=f, fill=(29, 29, 31, 255))
    bg.save(out_path, "JPEG", quality=92, subsampling=0, optimize=True)
    small = bg.copy()
    small.thumbnail((1024, 1024))
    small.save(small_path, "JPEG", quality=85)
    area = cut.width * cut.height / (side * side) * 100
    size = Path(out_path).stat().st_size
    checks = [
        {"code": "hero", "ok": 15 <= area <= 70, "level": "ok" if 15 <= area <= 70 else "warn",
         "message": f"Product covers {area:.0f}% of the photo" + ("" if area >= 15 else ": make it bigger so buyers see it") + ("" if area <= 70 else ": make it smaller so the scene shows")},
        {"code": "note", "ok": bool(params.get("note", True)), "level": "ok" if params.get("note", True) else "warn",
         "message": "\"Props not included\" note added" if params.get("note", True) else "No props note: only fine if nothing else in the photo could look included"},
        {"code": "size", "ok": True, "level": "ok", "message": f"{side}x{side} px"},
        {"code": "bytes", "ok": size < MAX_BYTES, "level": "ok" if size < MAX_BYTES else "bad", "message": f"{size / 1e6:.1f} MB"},
    ]
    return checks, {"product_area_pct": round(area, 1), "bytes": size, "x": x, "y": y}


def make_sheet(paths, out_path, label=""):
    """One strip of numbered thumbnails (a listing's photos in order) so Claude can look at many photos cheaply."""
    tile, gap = 320, 12
    n = max(1, len(paths))
    sheet = Image.new("RGB", (n * tile + (n + 1) * gap, tile + 2 * gap + 44), (235, 235, 238))
    d = ImageDraw.Draw(sheet)
    f = font(28)
    d.text((gap, 8), label[:80], font=f, fill=(29, 29, 31))
    for i, p in enumerate(paths):
        try:
            im = load(p).convert("RGB")
        except Exception:
            im = Image.new("RGB", (tile, tile), (200, 200, 200))
        im.thumbnail((tile, tile))
        cell = Image.new("RGB", (tile, tile), (255, 255, 255))
        cell.paste(im, ((tile - im.width) // 2, (tile - im.height) // 2))
        x = gap + i * (tile + gap)
        sheet.paste(cell, (x, 44 + gap))
        d.rounded_rectangle((x + 6, 44 + gap + 6, x + 50, 44 + gap + 46), radius=8, fill=(0, 98, 204))
        d.text((x + 18, 44 + gap + 10), str(i + 1), font=f, fill=(255, 255, 255))
    sheet.save(out_path, "JPEG", quality=85)



def run(job, outdir):
    kind, inputs, params = job["kind"], job.get("inputs") or [], job.get("params") or {}
    outdir = Path(outdir)
    files, result = [], {}
    if kind == "check":
        for i, p in enumerate(inputs):
            im = load(p)
            checks, score, metrics = photo_checks(im)
            result[str(i)] = {"checks": checks, "score": score, "metrics": metrics, "width": im.width, "height": im.height}
    elif kind == "cutout":
        for mode in params.get("modes") or ["soft", "fine"]:
            out, m = cutout(inputs[0], mode)
            name = f"cutout_{mode}.png"
            out.save(outdir / name, "PNG", optimize=True)
            files.append({"name": name, "kind": "cutout", "width": out.width, "height": out.height,
                          "meta": {"model": "isnet-general-use", "mode": mode, **m}, "checks": [], "score": None})
    elif kind == "main":
        checks, m = make_main(inputs[0], outdir / "main.jpg")
        score = 100 - sum(30 if c["level"] == "bad" else 10 for c in checks if not c["ok"])
        files.append({"name": "main.jpg", "kind": "main", "width": MAIN_SIZE, "height": MAIN_SIZE, "checks": checks, "score": score, "meta": m})
    elif kind == "swatch":
        checks, m = make_swatch(inputs[0], params.get("box") or {}, outdir / "swatch.jpg")
        files.append({"name": "swatch.jpg", "kind": "swatch", "width": 500, "height": 500, "checks": checks,
                      "score": 100 if checks[0]["ok"] else 80, "meta": m})
    elif kind == "scene":
        if len(inputs) < 2:
            raise ValueError("The background photo is missing")
        checks, m = make_scene(inputs[0], inputs[1], params, outdir / "scene.jpg", outdir / "scene_small.jpg")
        score = 100 - sum(30 if c["level"] == "bad" else 10 for c in checks if not c["ok"])
        files.append({"name": "scene.jpg", "kind": "scene", "width": SCENE_SIZE, "height": SCENE_SIZE, "checks": checks, "score": score,
                      "meta": m, "preview": "scene_small.jpg"})
    elif kind == "sheet":
        # params.groups: [{"label": "...", "count": n}] over the flat inputs list
        k = 0
        for gi, g in enumerate(params.get("groups") or []):
            n = int(g.get("count", 0))
            name = f"sheet_{gi}.jpg"
            make_sheet(inputs[k:k + n], outdir / name, g.get("label", ""))
            files.append({"name": name, "kind": "sheet"})
            k += n
    else:
        raise ValueError(f"Unknown job kind {kind}")
    return {"ok": True, "result": result, "files": files}


if __name__ == "__main__":
    job = json.loads(Path(sys.argv[1]).read_text())
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    try:
        res = run(job, out)
    except Exception as e:  # reported to the CRM in plain words
        res = {"ok": False, "error": str(e)[:300]}
    (out / "result.json").write_text(json.dumps(res))
    print(json.dumps({"ok": res["ok"]}))
