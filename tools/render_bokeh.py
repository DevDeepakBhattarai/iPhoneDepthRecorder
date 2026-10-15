from __future__ import annotations

import argparse
import json
import math
import pathlib
import struct
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone

import cv2
import numpy as np

FILE_HEADER = struct.Struct("<8sII")
FRAME_HEADER = struct.Struct("<4sIQqiqiqIIIII")


@dataclass
class DepthFrame:
    capture_index: int
    utc_ns: int
    depth: np.ndarray


def read_depth_file(path: pathlib.Path) -> dict[int, DepthFrame]:
    result: dict[int, DepthFrame] = {}
    with path.open("rb") as f:
        magic, version, endian = FILE_HEADER.unpack(f.read(FILE_HEADER.size))
        if magic != b"DRDEPTH1" or version != 1 or endian != 0x01020304:
            raise RuntimeError("unsupported depth.bin header")
        while True:
            raw = f.read(FRAME_HEADER.size)
            if not raw:
                break
            if len(raw) != FRAME_HEADER.size:
                raise RuntimeError("truncated depth frame header")
            (fm, header_size, capture_index, _vv, _vs, _dv, _ds, utc_ns,
             width, height, bpr, _pixel_format, payload_bytes) = FRAME_HEADER.unpack(raw)
            if fm != b"DPT1" or header_size != FRAME_HEADER.size:
                raise RuntimeError(f"bad depth frame {capture_index}")
            payload = f.read(payload_bytes)
            if len(payload) != payload_bytes:
                raise RuntimeError(f"truncated depth payload {capture_index}")
            packed_bpr = width * 2
            if bpr != packed_bpr:
                # The recorder currently row-packs Float16, but tolerate explicit BPR.
                rows = [payload[y * bpr:y * bpr + packed_bpr] for y in range(height)]
                payload = b"".join(rows)
            depth = np.frombuffer(payload, dtype="<f2").astype(np.float32).reshape(height, width)
            result[capture_index] = DepthFrame(capture_index, utc_ns, depth)
    if not result:
        raise RuntimeError("depth.bin contains no frames")
    return result


def read_frame_map(path: pathlib.Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text("utf-8-sig").splitlines() if line.strip()]


def interpolate_depths(rows: list[dict], available: dict[int, DepthFrame]) -> list[np.ndarray]:
    valid_indices = np.array(sorted(available), dtype=np.int32)
    output: list[np.ndarray] = []
    for row in rows:
        ci = int(row["capture_index"])
        if ci in available:
            output.append(available[ci].depth.copy())
            continue
        pos = int(np.searchsorted(valid_indices, ci))
        if pos <= 0:
            output.append(available[int(valid_indices[0])].depth.copy())
        elif pos >= len(valid_indices):
            output.append(available[int(valid_indices[-1])].depth.copy())
        else:
            lo, hi = int(valid_indices[pos - 1]), int(valid_indices[pos])
            t = (ci - lo) / float(hi - lo)
            output.append((available[lo].depth * (1.0 - t) + available[hi].depth * t).astype(np.float32))
    return output


def temporal_median(depths: list[np.ndarray], radius: int = 1) -> list[np.ndarray]:
    if radius <= 0:
        return depths
    out: list[np.ndarray] = []
    for i in range(len(depths)):
        lo, hi = max(0, i - radius), min(len(depths), i + radius + 1)
        out.append(np.median(np.stack(depths[lo:hi], axis=0), axis=0).astype(np.float32))
    return out


def smoothstep(edge0: float, edge1: float, x: np.ndarray) -> np.ndarray:
    if edge1 <= edge0:
        return (x >= edge1).astype(np.float32)
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def guided_filter_gray(guide: np.ndarray, target: np.ndarray, radius: int, eps: float) -> np.ndarray:
    """Small self-contained guided filter; guide/target are float32 in [0, 1]."""
    k = (radius * 2 + 1, radius * 2 + 1)
    mean_i = cv2.boxFilter(guide, cv2.CV_32F, k, borderType=cv2.BORDER_REFLECT)
    mean_p = cv2.boxFilter(target, cv2.CV_32F, k, borderType=cv2.BORDER_REFLECT)
    corr_i = cv2.boxFilter(guide * guide, cv2.CV_32F, k, borderType=cv2.BORDER_REFLECT)
    corr_ip = cv2.boxFilter(guide * target, cv2.CV_32F, k, borderType=cv2.BORDER_REFLECT)
    var_i = corr_i - mean_i * mean_i
    cov_ip = corr_ip - mean_i * mean_p
    a = cov_ip / (var_i + eps)
    b = mean_p - a * mean_i
    mean_a = cv2.boxFilter(a, cv2.CV_32F, k, borderType=cv2.BORDER_REFLECT)
    mean_b = cv2.boxFilter(b, cv2.CV_32F, k, borderType=cv2.BORDER_REFLECT)
    return np.clip(mean_a * guide + mean_b, 0.0, 1.0)


def robust_focus_depth(depth: np.ndarray, x: float, y: float, radius_fraction: float = 0.045) -> float:
    h, w = depth.shape
    cx = int(np.clip(x, 0.0, 1.0) * (w - 1))
    cy = int(np.clip(y, 0.0, 1.0) * (h - 1))
    r = max(2, int(min(w, h) * radius_fraction))
    patch = depth[max(0, cy-r):min(h, cy+r+1), max(0, cx-r):min(w, cx+r+1)]
    valid = patch[np.isfinite(patch) & (patch > 0.05) & (patch < 20.0)]
    if valid.size == 0:
        valid = depth[np.isfinite(depth) & (depth > 0.05) & (depth < 20.0)]
    if valid.size == 0:
        return 1.0
    # Median is stable against a few background samples around hair/shoulders.
    return float(np.median(valid))


def normalized_masked_blur(image: np.ndarray, support: np.ndarray, sigma: float) -> np.ndarray:
    if sigma <= 0.01:
        return image
    # Background-only normalized convolution prevents foreground color from bleeding
    # into the blurred background along hair/shoulder edges.
    support3 = support[..., None]
    weighted = image * support3
    num = cv2.GaussianBlur(weighted, (0, 0), sigmaX=sigma, sigmaY=sigma, borderType=cv2.BORDER_REFLECT)
    den = cv2.GaussianBlur(support, (0, 0), sigmaX=sigma, sigmaY=sigma, borderType=cv2.BORDER_REFLECT)
    return num / np.maximum(den[..., None], 1e-4)


def render_frame(frame_bgr: np.ndarray, depth_low: np.ndarray, focus_depth: float,
                 dof_m: float, transition_m: float, strength: float, max_sigma: float,
                 blur_work_width: int) -> np.ndarray:
    full_h, full_w = frame_bgr.shape[:2]
    if blur_work_width > 0 and full_w > blur_work_width:
        scale = blur_work_width / float(full_w)
        work_w = blur_work_width
        work_h = max(2, int(round(full_h * scale)))
        work_h -= work_h % 2
        work = cv2.resize(frame_bgr, (work_w, work_h), interpolation=cv2.INTER_AREA)
    else:
        work = frame_bgr
        work_h, work_w = full_h, full_w

    depth = cv2.resize(depth_low, (work_w, work_h), interpolation=cv2.INTER_LINEAR)

    # Background distance only. Anything in front of the chosen subject remains sharp,
    # which is much closer to a real lens than a generic person/background segmentation.
    delta = depth - focus_depth
    bg_alpha = smoothstep(dof_m, dof_m + transition_m, delta).astype(np.float32)

    # Physical-ish circle of confusion: inverse-depth separation grows quickly near the
    # subject and naturally saturates for very distant backgrounds.
    safe_depth = np.maximum(depth, 0.08)
    inv_sep = np.maximum(0.0, (1.0 / max(focus_depth, 0.08)) - (1.0 / safe_depth))
    coc = np.clip(inv_sep * (1.85 * strength), 0.0, 1.0) * bg_alpha

    # RGB-guided edge refinement. RGB never invents geometry; it only sharpens the
    # transition already implied by the metric LiDAR map.
    gray = cv2.cvtColor(work, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
    guide_radius = max(3, int(round(work_w / 320.0)))
    coc = guided_filter_gray(gray, coc.astype(np.float32), guide_radius, 0.008)
    coc = np.clip(coc * bg_alpha, 0.0, 1.0)

    image = work.astype(np.float32) / 255.0
    support = smoothstep(0.06, 0.20, bg_alpha).astype(np.float32)

    # max_sigma is expressed in final-output pixels. Scale it into working pixels so
    # the apparent blur size remains the same after the blur delta is upsampled.
    sigma_scale = work_w / float(full_w)
    sigmas = np.array([0.0, 0.18, 0.42, 0.70, 1.0], dtype=np.float32) * (max_sigma * sigma_scale)
    levels = [image]
    for sigma in sigmas[1:]:
        levels.append(normalized_masked_blur(image, support, float(sigma)))

    pos = coc * (len(levels) - 1)
    lo = np.floor(pos).astype(np.int32)
    hi = np.minimum(lo + 1, len(levels) - 1)
    frac = (pos - lo).astype(np.float32)

    processed = np.zeros_like(image)
    for level_index in range(len(levels)):
        weight = np.where(lo == level_index, 1.0 - frac, 0.0) + np.where(hi == level_index, frac, 0.0)
        processed += levels[level_index] * weight[..., None]

    if (work_w, work_h) == (full_w, full_h):
        final = processed
    else:
        # Upscale only the effect difference. Where coc==0 the difference is exactly
        # zero, so the original subject remains at native source resolution.
        effect_delta = processed - image
        delta_full = cv2.resize(effect_delta, (full_w, full_h), interpolation=cv2.INTER_LINEAR)
        original_full = frame_bgr.astype(np.float32) / 255.0
        final = original_full + delta_full

    return np.clip(final * 255.0 + 0.5, 0, 255).astype(np.uint8)

def probe_video(path: pathlib.Path) -> tuple[int, int, float, int | None]:
    cmd = ["ffprobe", "-v", "error", "-select_streams", "v:0",
           "-show_entries", "stream=width,height,avg_frame_rate,nb_frames",
           "-of", "json", str(path)]
    data = json.loads(subprocess.check_output(cmd, text=True))
    s = data["streams"][0]
    num, den = s["avg_frame_rate"].split("/")
    fps = float(num) / float(den)
    count = int(s["nb_frames"]) if s.get("nb_frames") not in (None, "N/A") else None
    return int(s["width"]), int(s["height"]), fps, count



def smpte_from_utc_ns(utc_ns: int, fps: float) -> tuple[str, str]:
    seconds = utc_ns / 1_000_000_000
    whole = math.floor(seconds)
    frac = seconds - whole
    dt = datetime.fromtimestamp(whole, tz=timezone.utc)
    nominal = max(1, int(round(fps)))
    ff = int(math.floor(frac * nominal + 0.5))
    if ff >= nominal:
        dt = datetime.fromtimestamp(whole + 1, tz=timezone.utc)
        ff = 0
    tc = f"{dt.hour:02d}:{dt.minute:02d}:{dt.second:02d}:{ff:02d}"
    iso = datetime.fromtimestamp(seconds, tz=timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
    return tc, iso
def read_exact(pipe, count: int) -> bytes:
    chunks = []
    left = count
    while left:
        chunk = pipe.read(left)
        if not chunk:
            break
        chunks.append(chunk)
        left -= len(chunk)
    return b"".join(chunks)


def main() -> None:
    ap = argparse.ArgumentParser(description="Render depth-aware cinematic bokeh from a DepthRecorder package")
    ap.add_argument("package", type=pathlib.Path)
    ap.add_argument("output", type=pathlib.Path)
    ap.add_argument("--width", type=int, default=1920, help="output width; 0 keeps source size")
    ap.add_argument("--focus-x", type=float, default=None, help="normalized LiDAR focus point x; defaults to recording metadata")
    ap.add_argument("--focus-y", type=float, default=None, help="normalized LiDAR focus point y; defaults to recording metadata")
    ap.add_argument("--dof", type=float, default=0.16, help="meters behind focus kept effectively sharp")
    ap.add_argument("--transition", type=float, default=0.28, help="meters over which background blur ramps in")
    ap.add_argument("--strength", type=float, default=0.90, help="virtual aperture / blur strength")
    ap.add_argument("--max-blur", type=float, default=34.0, help="max Gaussian sigma at 1920px width")
    ap.add_argument("--blur-work-width", type=int, default=1600, help="working width for expensive blur passes; 0 uses full output size")
    ap.add_argument("--limit", type=int, default=0, help="render only first N frames for testing")
    ap.add_argument("--cpu-encode", action="store_true", help="use libx265 instead of NVIDIA NVENC")
    args = ap.parse_args()

    package = args.package
    movie = package / "master.mov"
    frame_map_path = package / "frames.jsonl"
    depth_path = package / "depth.bin"
    for required in (movie, frame_map_path, depth_path):
        if not required.exists():
            raise SystemExit(f"missing {required}")

    rows = read_frame_map(frame_map_path)
    rows = [r for r in rows if r.get("video_appended")]
    available = read_depth_file(depth_path)
    depths = temporal_median(interpolate_depths(rows, available), radius=1)

    focus_x = args.focus_x
    focus_y = args.focus_y
    manifest_path = package / "manifest.json"
    if manifest_path.exists() and (focus_x is None or focus_y is None):
        manifest = json.loads(manifest_path.read_text("utf-8-sig"))
        if focus_x is None and manifest.get("focus_point_x") is not None:
            focus_x = float(manifest["focus_point_x"])
        if focus_y is None and manifest.get("focus_point_y") is not None:
            focus_y = float(manifest["focus_point_y"])
    if focus_x is None:
        focus_x = 0.50
    if focus_y is None:
        focus_y = 0.45

    src_w, src_h, fps, probed_count = probe_video(movie)
    out_w = src_w if args.width <= 0 else min(args.width, src_w)
    out_h = int(round(src_h * (out_w / src_w)))
    # NVENC prefers even dimensions.
    out_w -= out_w % 2
    out_h -= out_h % 2
    frame_count = min(len(rows), len(depths), probed_count or len(rows))
    if args.limit > 0:
        frame_count = min(frame_count, args.limit)

    decode = subprocess.Popen([
        "ffmpeg", "-v", "error", "-noautorotate", "-i", str(movie), "-map", "0:v:0",
        "-frames:v", str(frame_count), "-f", "rawvideo", "-pix_fmt", "bgr24", "pipe:1"
    ], stdout=subprocess.PIPE)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    codec = ["-c:v", "libx265", "-preset", "medium", "-crf", "18"] if args.cpu_encode else [
        "-c:v", "hevc_nvenc", "-preset", "p6", "-tune", "hq", "-rc", "vbr", "-cq", "18", "-b:v", "0"
    ]
    timecode, creation_iso = smpte_from_utc_ns(int(rows[0]["utc_ns"]), fps)
    orientation_filter = {
        "portrait": "transpose=clock",
        "portraitUpsideDown": "transpose=cclock",
        "landscapeLeft": "hflip,vflip",
    }.get(orientation)
    encode_cmd = [
        "ffmpeg", "-y", "-v", "error",
        "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{out_w}x{out_h}", "-r", f"{fps:.8f}", "-i", "pipe:0",
        "-i", str(movie), "-map", "0:v:0", "-map", "1:a:0?",
        *(["-vf", orientation_filter] if orientation_filter else []), *codec,
        "-pix_fmt", "yuv420p", "-color_range", "pc", "-colorspace", "bt709",
        "-color_primaries", "bt709", "-color_trc", "bt709",
        "-timecode", timecode, "-metadata", f"creation_time={creation_iso}",
        "-c:a", "copy", "-shortest", str(args.output)
    ]
    encode = subprocess.Popen(encode_cmd, stdin=subprocess.PIPE)

    frame_bytes = src_w * src_h * 3
    focus_ema: float | None = None
    scale = out_w / 1920.0
    max_sigma = max(1.0, args.max_blur * scale)

    try:
        for i in range(frame_count):
            raw = read_exact(decode.stdout, frame_bytes)
            if len(raw) != frame_bytes:
                print(f"decoder ended at frame {i}", file=sys.stderr)
                break
            frame = np.frombuffer(raw, dtype=np.uint8).reshape(src_h, src_w, 3)
            if (out_w, out_h) != (src_w, src_h):
                frame = cv2.resize(frame, (out_w, out_h), interpolation=cv2.INTER_AREA)

            measured_focus = robust_focus_depth(depths[i], focus_x, focus_y)
            focus_ema = measured_focus if focus_ema is None else (0.86 * focus_ema + 0.14 * measured_focus)
            rendered = render_frame(frame, depths[i], focus_ema, args.dof, args.transition,
                                    args.strength, max_sigma, args.blur_work_width)
            encode.stdin.write(rendered.tobytes())

            if i == 0 or (i + 1) % 15 == 0 or i + 1 == frame_count:
                print(f"{i+1}/{frame_count} focus={focus_ema:.3f}m", flush=True)
    finally:
        if decode.stdout:
            decode.stdout.close()
        decode.wait()
        if encode.stdin:
            encode.stdin.close()
        code = encode.wait()
        if code != 0:
            raise SystemExit(f"ffmpeg encoder exited with {code}")

    print(f"focus point=({focus_x:.3f},{focus_y:.3f}) timecode={timecode}")
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
