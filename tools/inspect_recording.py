from __future__ import annotations
import argparse
import json
import math
import pathlib
import struct
from datetime import datetime, timezone

FILE_HEADER = struct.Struct("<8sII")
FRAME_HEADER = struct.Struct("<4sIQqiqiqIIIII")


def iso_from_ns(ns: int) -> str:
    return datetime.fromtimestamp(ns / 1_000_000_000, tz=timezone.utc).isoformat()


def read_json(path: pathlib.Path) -> dict:
    return json.loads(path.read_text("utf-8-sig")) if path.exists() else {}


def read_frame_rows(path: pathlib.Path) -> list[dict]:
    if not path.exists():
        raise SystemExit(f"missing {path}")
    return [json.loads(line) for line in path.read_text("utf-8-sig").splitlines() if line.strip()]


def inspect_depth(depth_path: pathlib.Path, sample_depth: bool) -> tuple[int, list[dict]]:
    frames: list[dict] = []
    with depth_path.open("rb") as f:
        header = f.read(FILE_HEADER.size)
        if len(header) != FILE_HEADER.size:
            raise SystemExit("truncated depth file header")
        magic, version, endian = FILE_HEADER.unpack(header)
        if magic != b"DRDEPTH1":
            raise SystemExit(f"bad depth file magic: {magic!r}")
        if endian != 0x01020304:
            raise SystemExit(f"unexpected endian marker: {endian:#x}")
        while True:
            offset = f.tell()
            raw = f.read(FRAME_HEADER.size)
            if not raw:
                break
            if len(raw) != FRAME_HEADER.size:
                raise SystemExit(f"truncated frame header at {offset}")
            (fm, header_size, capture_index, v_value, v_scale, d_value, d_scale,
             utc_ns, width, height, bpr, pixel_format, payload_bytes) = FRAME_HEADER.unpack(raw)
            if fm != b"DPT1" or header_size != FRAME_HEADER.size:
                raise SystemExit(f"bad frame header at {offset}: {fm!r}, size={header_size}")
            payload = f.read(payload_bytes)
            if len(payload) != payload_bytes:
                raise SystemExit(f"truncated payload for frame {capture_index}")
            item = {
                "offset": offset, "capture_index": capture_index,
                "video_pts": v_value / v_scale if v_scale else None,
                "depth_pts": d_value / d_scale if d_scale else None,
                "utc_ns": utc_ns, "width": width, "height": height,
                "bpr": bpr, "pixel_format": pixel_format, "payload_bytes": payload_bytes,
            }
            if sample_depth and payload_bytes >= 2:
                count = min(width * height, 4096)
                step = max(1, (width * height) // max(count, 1))
                vals: list[float] = []
                for idx in range(0, width * height, step):
                    pos = idx * 2
                    if pos + 2 > len(payload):
                        break
                    val = struct.unpack_from("<e", payload, pos)[0]
                    if math.isfinite(val) and val > 0:
                        vals.append(float(val))
                    if len(vals) >= count:
                        break
                if vals:
                    vals.sort()
                    item["depth_min_m"] = vals[0]
                    item["depth_median_m"] = vals[len(vals)//2]
                    item["depth_max_m"] = vals[-1]
            frames.append(item)
    return version, frames


def inspect(package: pathlib.Path, sample_depth: bool) -> None:
    package = package.resolve()
    movie = package / "master.mov"
    frames_path = package / "frames.jsonl"
    if not movie.exists():
        raise SystemExit(f"missing {movie}")
    rows = read_frame_rows(frames_path)
    manifest = read_json(package / "manifest.json")
    depth_expected = bool(manifest.get("depth_available", True))

    appended = [row for row in rows if row.get("video_appended")]
    utc_values = [int(row["utc_ns"]) for row in appended if row.get("utc_ns") is not None]
    if any(b < a for a, b in zip(utc_values, utc_values[1:])):
        raise SystemExit("video UTC timestamps are not monotonic")
    print(f"frames.jsonl records: {len(rows)}")
    print(f"video frames appended: {len(appended)}")
    if utc_values:
        print(f"first video UTC: {utc_values[0]} ({iso_from_ns(utc_values[0])})")
        print(f"last  video UTC: {utc_values[-1]} ({iso_from_ns(utc_values[-1])})")

    depth_path = package / "depth.bin"
    if not depth_expected:
        print("depth: intentionally unavailable (RGB-only lens mode)")
        if manifest:
            print(f"camera: {manifest.get('rear_lens_equivalent_mm', '?')} mm / {manifest.get('camera_device_type', 'unknown')}")
        print("validation: OK")
        return

    if not depth_path.exists():
        raise SystemExit(f"manifest expects depth but {depth_path} is missing")
    version, depth_frames = inspect_depth(depth_path, sample_depth)
    print(f"depth format version: {version}")
    print(f"depth frames: {len(depth_frames)}")
    if depth_frames:
        print(f"depth size: {depth_frames[0]['width']}x{depth_frames[0]['height']} payload={depth_frames[0]['payload_bytes']} bytes/frame")
        if sample_depth and "depth_median_m" in depth_frames[0]:
            f = depth_frames[0]
            print(f"first-frame sampled depth m: min={f['depth_min_m']:.3f} median={f['depth_median_m']:.3f} max={f['depth_max_m']:.3f}")
    for a, b in zip(depth_frames, depth_frames[1:]):
        if b["capture_index"] <= a["capture_index"]:
            raise SystemExit("depth capture_index is not strictly increasing")
        if b["utc_ns"] < a["utc_ns"]:
            raise SystemExit("depth UTC timestamps are not monotonic")
    if manifest.get("depth_frames_written") is not None and int(manifest["depth_frames_written"]) != len(depth_frames):
        raise SystemExit("manifest depth count does not match depth.bin")
    if rows and depth_frames:
        first_depth_row = next((r for r in rows if not r.get("depth_dropped") and int(r.get("depth_payload_bytes") or 0) > 0), None)
        if first_depth_row and int(first_depth_row["utc_ns"]) != depth_frames[0]["utc_ns"]:
            raise SystemExit("UTC mismatch between frames.jsonl and depth.bin first valid depth frame")
    print("validation: OK")


def main() -> None:
    ap = argparse.ArgumentParser(description="Validate a Depth Recorder .depthrec package")
    ap.add_argument("package", type=pathlib.Path)
    ap.add_argument("--sample-depth", action="store_true")
    args = ap.parse_args()
    inspect(args.package, args.sample_depth)


if __name__ == "__main__":
    main()
