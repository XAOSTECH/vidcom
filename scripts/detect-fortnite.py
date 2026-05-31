#!/usr/bin/env python3
"""
detect-fortnite.py - OCR-based Fortnite elimination detector (the "teacher").

Fortnite has no persistent icon kill-feed like Valorant/CS. Eliminations show
up as transient on-screen text ("Knocked down ...", "You eliminated ...").
This detector samples frames via GPU ffmpeg (NVDEC), crops the elimination
banner region, runs Tesseract OCR, and matches kill keywords.

It does two jobs in a single pass:
  1. DETECT  -> writes output/highlights.json (schema consumed by process-batch.sh)
  2. HARVEST -> saves auto-labelled crops to dataset/fortnite/{kill,nokill}/
               so a fast Crispy-style model can later be trained on real data.

Only ffmpeg + tesseract + numpy/PIL are required (all from build-deps.sh).
"""

import argparse
import io
import json
import os
import re
import subprocess
import sys
import time

import numpy as np
from PIL import Image

# Keywords that indicate a Fortnite elimination / knock event.
KILL_KEYWORDS = [
    "ELIMINATED", "KNOCKED", "KNOCKED DOWN", "FINISHED",
    "YOU ELIMINATED", "YOU KNOCKED", "HEADSHOT", "ELIMINATION",
]

# Verbs that separate the eliminator (left) from the victim (right) in the feed.
ELIM_VERBS = ["ELIMINATED", "KNOCKED OUT", "KNOCKED DOWN", "KNOCKED", "FINISHED"]

# Phrases Fortnite shows in the top-middle when the local player gets the kill.
SELF_PHRASES = ["YOU ELIMINATED", "YOU KNOCKED", "YOU FINISHED", "YOU HEADSHOT"]


def normalize_name(name):
    """Lowercase and strip non-alphanumerics for fuzzy player-name matching."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def is_player_kill(text, player):
    """Return True if the OCR text represents an elimination *by* `player`.

    Handles two cases:
      1. Top-middle self notification: "YOU ELIMINATED ...".
      2. Kill feed line where `player` is the eliminator (left of the verb).
    If `player` is None, any elimination counts.
    """
    if not player:
        return True
    # Case 1: the game's own "you" notification always means the local player.
    if any(p in text for p in SELF_PHRASES):
        return True
    target = normalize_name(player)
    if not target:
        return True
    # Case 2: parse "<eliminator> <verb> <victim>" and match the eliminator side.
    for line in text.splitlines():
        upper = line.upper()
        for verb in ELIM_VERBS:
            idx = upper.find(verb)
            if idx > 0:
                eliminator = normalize_name(line[:idx])
                if target and target in eliminator:
                    return True
    return False


def build_ffmpeg_cmd(video, fps, crop, use_gpu):
    """Build an ffmpeg command that streams cropped grayscale frames as rawvideo."""
    cx, cy, cw, ch = crop
    vf = f"fps={fps},crop={cw}:{ch}:{cx}:{cy},format=gray"
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error"]
    if use_gpu:
        cmd += ["-hwaccel", "cuda"]
    cmd += [
        "-i", video,
        "-vf", vf,
        "-f", "rawvideo",
        "-pix_fmt", "gray",
        "-",
    ]
    return cmd, cw, ch


def probe_dimensions(video):
    """Return (width, height) of the video via ffprobe."""
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x", video],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    w, h = out.split("x")
    return int(w), int(h)


def ocr_image(gray_arr, psm):
    """Run tesseract on a grayscale numpy array, return uppercased recognised text."""
    img = Image.fromarray(gray_arr, mode="L")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    proc = subprocess.run(
        ["tesseract", "stdin", "stdout", "--psm", str(psm)],
        input=buf.read(), capture_output=True,
    )
    return proc.stdout.decode("utf-8", "ignore").upper()


def match_keywords(text):
    """Return the matched keyword (highlight subtype) or None."""
    for kw in KILL_KEYWORDS:
        if kw in text:
            return kw
    return None


def main():

    # Load kill counter region from config
    region_conf = os.path.join(os.path.dirname(__file__), '../config/killcounter_region.conf')
    kill_crop = None
    if os.path.exists(region_conf):
        with open(region_conf) as f:
            lines = f.readlines()
        vals = {}
        for line in lines:
            if '=' in line:
                k, v = line.strip().split('=')
                vals[k.strip()] = int(v.strip())
        kill_crop = (vals['CROP_X'], vals['CROP_Y'], vals['CROP_WIDTH'], vals['CROP_HEIGHT'])

    def ocr_killcounter(frame):
        # Crop and enhance kill counter region, then OCR
        x, y, w, h = kill_crop
        crop = frame[y:y+h, x:x+w]
        pil = Image.fromarray(crop, mode="L").resize((40,40), Image.LANCZOS).filter(ImageFilter.SHARPEN)
        pil = ImageEnhance.Contrast(pil).enhance(2.0)
        buf = io.BytesIO()
        pil.save(buf, format="PNG")
        buf.seek(0)
        proc = subprocess.run([
            "tesseract", "stdin", "stdout", "--psm", "6", "-c", "tessedit_char_whitelist=0123456789"
        ], input=buf.read(), capture_output=True)
        out = proc.stdout.decode("utf-8", "ignore").strip()
        return int(out) if out.isdigit() else None

    ap = argparse.ArgumentParser(description="Fortnite OCR elimination detector")
    ap.add_argument("video")
    ap.add_argument("--fps", type=float, default=0.33,
        help="Frames per second to sample (default 0.33, i.e., every 3 seconds)")
    ap.add_argument("--output", default="output/highlights.json",
        help="Path to highlights JSON")
    ap.add_argument("--dataset", default="dataset/fortnite",
        help="Directory to harvest labelled crops into")
    ap.add_argument("--no-harvest", action="store_true",
        help="Disable saving training crops")
    ap.add_argument("--cooldown", type=float, default=6.0,
        help="Seconds to merge consecutive hits into one event")
    ap.add_argument("--psm", type=int, default=11,
        help="Tesseract page segmentation mode (11=sparse text)")
    ap.add_argument("--bright-thresh", type=int, default=200,
        help="Pixel value considered 'text' for the pre-filter")
    ap.add_argument("--bright-min", type=int, default=40,
        help="Min bright pixels in crop before OCR is attempted")
    ap.add_argument("--nokill-sample", type=int, default=200,
        help="Harvest 1 in N non-kill frames as negatives")
    ap.add_argument("--train-size", type=int, default=100,
        help="Square size of harvested crops (NxN grayscale)")
    ap.add_argument("--no-gpu", action="store_true", help="Disable NVDEC")
    # Restrict highlights to a specific player's own eliminations.
    # --player and --username are interchangeable aliases.
    ap.add_argument("--player", "--username", dest="player", default=None,
        help="Only keep eliminations performed by this player "
             "(matches the kill-feed eliminator or the "
             "top-middle 'YOU ELIMINATED' notification)")
    # Elimination banner region as fractions of frame (x, y, w, h).
    ap.add_argument("--region", default="0.25,0.40,0.50,0.22",
        help="Crop region x,y,w,h as frame fractions")
    args = ap.parse_args()

    vw, vh = probe_dimensions(args.video)
    fx, fy, fw, fh = (float(v) for v in args.region.split(","))
    # ffmpeg crop needs even dimensions.
    cx, cy = int(fx * vw) & ~1, int(fy * vh) & ~1
    cw, ch = int(fw * vw) & ~1, int(fh * vh) & ~1
    crop = (cx, cy, cw, ch)
    print(f"[fortnite] Video {vw}x{vh}, crop {cw}x{ch}+{cx}+{cy} @ {args.fps}fps")
    if args.player:
        print(f"[fortnite] Filtering to eliminations by player: {args.player}")

    if not args.no_harvest:
        os.makedirs(os.path.join(args.dataset, "kill"), exist_ok=True)
        os.makedirs(os.path.join(args.dataset, "nokill"), exist_ok=True)

    cmd, cw, ch = build_ffmpeg_cmd(args.video, args.fps, crop, not args.no_gpu)
    frame_bytes = cw * ch
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)

    events = []           # list of (timestamp, keyword) raw hits
    frame_idx = 0
    ocr_calls = 0
    prev_killcount = None
    harvested_kill = 0
    harvested_nokill = 0
    t0 = time.time()

    while True:
        raw = proc.stdout.read(frame_bytes)
        if len(raw) < frame_bytes:
            break
        ts = frame_idx / args.fps
        frame_idx += 1
        gray = np.frombuffer(raw, dtype=np.uint8).reshape(ch, cw)

        # OCR kill counter
        killcount = None
        if kill_crop is not None:
            try:
                killcount = ocr_killcounter(gray)
            except Exception:
                killcount = None

        # Only count highlight if kill counter increments
        if killcount is not None and prev_killcount is not None and killcount > prev_killcount:
            events.append((ts, f"KILLCOUNT_{killcount}"))
        prev_killcount = killcount if killcount is not None else prev_killcount

        if frame_idx % 500 == 0:
            elapsed = time.time() - t0
            print(f"\r[fortnite] {frame_idx} frames "
                  f"({ts:.0f}s video), {len(events)} hits, "
                  f"{ocr_calls} OCR calls, {elapsed:.0f}s elapsed",
                  end="", flush=True)

    proc.wait()
    print()

    # Merge raw hits within cooldown into segments.
    events.sort(key=lambda e: e[0])
    segments = []
    for ts, kw in events:
        if segments and ts - segments[-1]["_last"] <= args.cooldown:
            seg = segments[-1]
            seg["end"] = ts
            seg["_last"] = ts
            seg["detections"] += 1
        else:
            segments.append({
                "type": kw.replace(" ", "_"),
                "start": ts,
                "end": ts,
                "confidence": 0.95,
                "detections": 1,
                "_last": ts,
            })
    for seg in segments:
        seg.pop("_last", None)

    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "w") as f:
        json.dump({
            "video": args.video,
            "game": "fortnite",
            "method": "ocr",
            "segments": segments,
        }, f, indent=2)

    print(f"[fortnite] Done: {len(segments)} elimination events "
          f"from {frame_idx} frames ({ocr_calls} OCR calls)")
    print(f"[fortnite] Harvested {harvested_kill} kill / "
          f"{harvested_nokill} nokill crops -> {args.dataset}")
    print(f"[fortnite] Wrote {args.output}")


if __name__ == "__main__":
    main()
