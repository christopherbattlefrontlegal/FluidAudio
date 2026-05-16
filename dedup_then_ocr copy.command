#!/usr/bin/env python3
"""
dedup_then_transcribe.command

Audio + video only. Nothing else is hashed, nothing else is touched.

Pipeline:
  1. Recursively walk <input_dir> for audio/video files (case-insensitive).
     Skip symlinks and hidden files.
  2. SHA-256 every file in parallel.
  3. Group by hash. For each hash pick ONE path (oldest mtime, then shortest path).
  4. Write <output_dir>/_unique_media_<ts>.txt and <output_dir>/_media_hashes_<ts>.txt.
  5. For each unique file:
       - If video, extract audio to <output_dir>/fluidaudio/_extracted/<sha>.wav via ffmpeg.
       - Run fluidaudiocli transcribe <path> --output-json <output_dir>/fluidaudio/<sha>.json
     Run up to FA_CONCURRENCY files in parallel (default 4).

Usage:
  ./dedup_then_ocr copy.command <input_dir> <output_dir>
  ./dedup_then_ocr copy.command         (prompts interactively)
"""

import hashlib
import os
import shutil
import subprocess
import sys
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from multiprocessing import Pool, cpu_count

HERE = os.path.dirname(os.path.abspath(__file__))
FLUIDAUDIO = os.path.join(HERE, ".build", "release", "fluidaudiocli")

AUDIO_EXTS = {
    ".wav", ".mp3", ".m4a", ".aac", ".flac",
    ".ogg", ".opus", ".aiff", ".aif", ".wma", ".caf",
}
VIDEO_EXTS = {
    ".mp4", ".mov", ".m4v", ".mkv", ".avi", ".webm",
    ".flv", ".wmv", ".mpg", ".mpeg", ".ts", ".3gp",
}

CHUNK = 1 << 20  # 1 MiB read buffer
WORKERS = int(os.environ.get("JOBS", cpu_count()))
FA_CONCURRENCY = int(os.environ.get("FA_CONCURRENCY", 4))


def clean(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        s = s[1:-1]
    return os.path.expanduser(s)


def prompt(label: str) -> str:
    return clean(input(f"{label}: "))


def media_kind(path: str):
    ext = os.path.splitext(path)[1].lower()
    if ext in AUDIO_EXTS:
        return "audio"
    if ext in VIDEO_EXTS:
        return "video"
    return None


def iter_media(root: str):
    if os.path.isfile(root) and not os.path.islink(root):
        if media_kind(root):
            yield root
        return
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in filenames:
            if name.startswith("."):
                continue
            if media_kind(name) is None:
                continue
            p = os.path.join(dirpath, name)
            if os.path.isfile(p) and not os.path.islink(p):
                yield p


def sha256_with_size(path: str):
    try:
        h = hashlib.sha256()
        size = 0
        with open(path, "rb", buffering=0) as f:
            while True:
                buf = f.read(CHUNK)
                if not buf:
                    break
                h.update(buf)
                size += len(buf)
        return (path, h.hexdigest(), size, None)
    except OSError as e:
        return (path, None, 0, f"{type(e).__name__}: {e}")


def pick_keep(paths: list[str]) -> str:
    ranked = []
    for p in paths:
        try:
            mt = os.path.getmtime(p)
        except OSError:
            mt = float("inf")
        ranked.append((mt, len(p), p))
    ranked.sort()
    return ranked[0][2]


def extract_audio(src: str, dst_wav: str):
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i", src,
        "-vn", "-ac", "1", "-ar", "16000", "-f", "wav",
        dst_wav,
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError:
        return (False, "ffmpeg not found in PATH")
    if r.returncode != 0:
        tail = (r.stderr or "").strip().splitlines()
        return (False, tail[-1] if tail else f"exit {r.returncode}")
    return (True, "")


def run_transcribe(audio_path: str, out_json: str):
    cmd = [FLUIDAUDIO, "transcribe", audio_path, "--output-json", out_json]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        tail = (r.stderr or r.stdout or "").strip().splitlines()
        msg = tail[-1] if tail else f"exit {r.returncode}"
        return (r.returncode, msg)
    return (0, "")


def process_one(kept_path: str, sha: str, kind: str,
                fa_out: str, extracted_dir: str):
    out_json = os.path.join(fa_out, f"{sha}.json")
    if os.path.isfile(out_json) and os.path.getsize(out_json) > 0:
        return (sha, kept_path, True, "skip-existing")

    audio_input = kept_path
    if kind == "video":
        wav_path = os.path.join(extracted_dir, f"{sha}.wav")
        if not os.path.isfile(wav_path):
            ok, msg = extract_audio(kept_path, wav_path)
            if not ok:
                return (sha, kept_path, False, f"ffmpeg: {msg}")
        audio_input = wav_path

    rc, msg = run_transcribe(audio_input, out_json)
    if rc != 0:
        return (sha, kept_path, False, f"fluidaudio: {msg}")
    return (sha, kept_path, True, "")


def main() -> int:
    if len(sys.argv) >= 3:
        src = clean(sys.argv[1])
        out_dir = clean(sys.argv[2])
    else:
        src = prompt("Source folder to scan")
        out_dir = prompt("Output folder")

    if not os.path.exists(src):
        print(f"Error: input path does not exist: {src}", file=sys.stderr)
        return 1
    os.makedirs(out_dir, exist_ok=True)

    if not os.path.isfile(FLUIDAUDIO):
        print(f"Error: fluidaudiocli binary not found at {FLUIDAUDIO}",
              file=sys.stderr)
        print("Build it first: swift build -c release", file=sys.stderr)
        return 1

    if not shutil.which("ffmpeg"):
        print("Warning: ffmpeg not found in PATH. Video files will fail extraction.",
              file=sys.stderr)

    stamp = time.strftime("%Y%m%d-%H%M%S")

    # ---- Step 1: enumerate audio + video files ----
    print(f"\n[1/4] Walking for audio + video under: {src}")
    files = list(iter_media(src))
    total = len(files)
    print(f"      Found {total:,} media files")
    if total == 0:
        print("Nothing to do.")
        return 0

    # ---- Step 2: SHA-256 ----
    print(f"\n[2/4] SHA-256 with {WORKERS} workers")
    hashes_file = os.path.join(out_dir, f"_media_hashes_{stamp}.txt")
    by_hash: dict[str, list[str]] = defaultdict(list)
    errors: list[tuple[str, str]] = []
    bytes_done = 0
    count = 0
    start = time.time()
    last_report = start

    with open(hashes_file, "w", encoding="utf-8", errors="replace",
              buffering=1 << 16) as fout, Pool(processes=WORKERS) as pool:
        for path, hexd, size, err in pool.imap_unordered(
            sha256_with_size, files, chunksize=1
        ):
            if err:
                errors.append((path, err))
                fout.write(f"# ERROR {err}\t{path}\n")
            else:
                by_hash[hexd].append(path)
                fout.write(f"{hexd}  {size}  {path}\n")
                bytes_done += size
            count += 1
            now = time.time()
            if now - last_report >= 0.5 or count == total:
                elapsed = max(now - start, 1e-9)
                rate = count / elapsed
                mbps = (bytes_done / (1024 * 1024)) / elapsed
                pct = 100 * count / total
                eta = (total - count) / rate if rate > 0 else 0
                sys.stderr.write(
                    f"\r{count:>6,}/{total:,} ({pct:5.1f}%) | "
                    f"{rate:>5,.0f} file/s | {mbps:>6,.1f} MiB/s | "
                    f"err {len(errors)} | ETA {eta:>5.0f}s   "
                )
                sys.stderr.flush()
                last_report = now

    sys.stderr.write("\n")
    elapsed = time.time() - start
    print(f"      Hashed {total:,} files in {elapsed:.1f}s "
          f"({(bytes_done/(1024**3))/max(elapsed,1e-9):.2f} GiB/s)")
    print(f"      Hash report: {hashes_file}")

    # ---- Step 3: pick one path per unique SHA-256 ----
    unique: list[tuple[str, str]] = []
    for h, paths in by_hash.items():
        unique.append((h, pick_keep(paths)))
    unique.sort(key=lambda x: x[1])
    dupes = total - len(unique)
    list_file = os.path.join(out_dir, f"_unique_media_{stamp}.txt")
    with open(list_file, "w", encoding="utf-8") as f:
        f.write("# unique media files by SHA-256 (one KEEP per content hash)\n")
        f.write(f"# source     : {src}\n")
        f.write(f"# total      : {total}\n")
        f.write(f"# unique     : {len(unique)}\n")
        f.write(f"# duplicates : {dupes}\n")
        f.write(f"# errors     : {len(errors)}\n\n")
        for h, p in unique:
            f.write(f"{h}  {p}\n")
    print(f"\n[3/4] Unique files: {len(unique):,}  "
          f"(removed {dupes:,} content-duplicates)")
    print(f"      List file  : {list_file}")

    if not unique:
        return 0

    # ---- Step 4: transcribe ----
    fa_out = os.path.join(out_dir, "fluidaudio")
    extracted = os.path.join(fa_out, "_extracted")
    os.makedirs(fa_out, exist_ok=True)
    os.makedirs(extracted, exist_ok=True)

    n_total = len(unique)
    print(f"\n[4/4] fluidaudiocli transcribe on {n_total:,} files "
          f"with {FA_CONCURRENCY} workers")
    print(f"      Output JSONs: {fa_out}")
    print(f"      Extracted audio cache: {extracted}\n")

    n_done = 0
    n_ok = 0
    n_fail = 0
    fa_start = time.time()
    fa_last = fa_start
    fail_log = os.path.join(fa_out, f"_failures_{stamp}.tsv")

    with open(fail_log, "w", encoding="utf-8") as flog, \
            ThreadPoolExecutor(max_workers=FA_CONCURRENCY) as ex:
        futs = [
            ex.submit(process_one, p, h, media_kind(p), fa_out, extracted)
            for h, p in unique
        ]
        for fut in as_completed(futs):
            sha, src_path, ok, msg = fut.result()
            n_done += 1
            if ok:
                n_ok += 1
            else:
                n_fail += 1
                flog.write(f"{sha}\t{src_path}\t{msg}\n")
                flog.flush()
            now = time.time()
            if now - fa_last >= 0.5 or n_done == n_total:
                elapsed = max(now - fa_start, 1e-9)
                rate = n_done / elapsed
                pct = 100 * n_done / n_total
                eta = (n_total - n_done) / rate if rate > 0 else 0
                sys.stderr.write(
                    f"\r{n_done:>6,}/{n_total:,} ({pct:5.1f}%) | "
                    f"ok {n_ok} | fail {n_fail} | "
                    f"{rate:>5.2f} file/s | ETA {eta:>5.0f}s   "
                )
                sys.stderr.flush()
                fa_last = now

    sys.stderr.write("\n")
    print(f"\nDone. JSONs are in: {fa_out}")
    if n_fail:
        print(f"      Failures: {n_fail}  (see {fail_log})")
    return 0 if n_fail == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
