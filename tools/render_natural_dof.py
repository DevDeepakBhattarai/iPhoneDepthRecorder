from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import time
from datetime import datetime, timezone

from render_bokeh import probe_video, read_frame_map, smpte_from_utc_ns
from render_bokeh_fast import probe_color, orientation_filter


def run(cmd: list[str]) -> None:
    print('> ' + ' '.join(f'"{x}"' if ' ' in x else x for x in cmd), flush=True)
    subprocess.check_call(cmd)


def main() -> None:
    ap = argparse.ArgumentParser(description='Natural bidirectional LiDAR DOF renderer')
    ap.add_argument('package', type=pathlib.Path)
    ap.add_argument('output', type=pathlib.Path)
    ap.add_argument('--mask-width', type=int, default=960)
    ap.add_argument('--segment-every', type=int, default=3)
    ap.add_argument('--model', type=pathlib.Path, default=None)
    ap.add_argument('--work-width', type=int, default=1600)
    ap.add_argument('--cq', type=int, default=17)
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--keep-masks', action=argparse.BooleanOptionalAction, default=True)
    args = ap.parse_args()

    package = args.package.resolve()
    output = args.output.resolve()
    movie = package / 'master.mov'
    frames_path = package / 'frames.jsonl'
    depth_path = package / 'depth.bin'
    for required in (movie, frames_path, depth_path):
        if not required.exists():
            raise SystemExit(f'missing {required}')

    tools = pathlib.Path(__file__).resolve().parent
    project_root = tools.parent
    model = (args.model or (project_root / 'models' / 'u2net_human_seg.onnx')).resolve()
    if not model.exists():
        raise SystemExit(f'missing subject model: {model}')

    output.parent.mkdir(parents=True, exist_ok=True)
    prefix = pathlib.Path(str(output) + '.natural')
    meta_path = pathlib.Path(str(prefix) + '_meta.json')
    soft = pathlib.Path(str(prefix) + '_soft.mkv')
    mid = pathlib.Path(str(prefix) + '_mid.mkv')
    far = pathlib.Path(str(prefix) + '_far.mkv')
    subject = pathlib.Path(str(prefix) + '_subject.mkv')

    mask_cmd = [
        sys.executable, str(tools / 'make_natural_dof_masks_v3.py'),
        str(package), str(prefix), '--width', str(args.mask_width),
        '--segment-every', str(args.segment_every), '--model', str(model),
    ]
    if args.limit > 0:
        mask_cmd += ['--limit', str(args.limit)]

    started = time.perf_counter()
    run(mask_cmd)
    mask_seconds = time.perf_counter() - started
    meta = json.loads(meta_path.read_text('utf-8-sig'))
    frame_count = int(meta['frames'])
    fps = float(meta['fps'])
    if frame_count <= 0:
        raise SystemExit('no rendered frames')

    src_w, src_h, _, _ = probe_video(movie)
    work_w = max(320, min(src_w, args.work_width))
    work_h = int(round(src_h * work_w / src_w))
    work_h -= work_h % 2

    manifest_path = package / 'manifest.json'
    manifest = json.loads(manifest_path.read_text('utf-8-sig')) if manifest_path.exists() else {}
    orientation = manifest.get('capture_interface_orientation', 'landscapeRight')
    orient = orientation_filter(orientation)
    rows = [r for r in read_frame_map(frames_path) if r.get('video_appended')]
    first_utc_ns = int(rows[0]['utc_ns'])
    timecode, creation_iso = smpte_from_utc_ns(first_utc_ns, fps)
    color = probe_color(movie)

    trim = f'trim=end_frame={frame_count},setpts=PTS-STARTPTS'
    graph = (
        f'[0:v]{trim},split=4[b0][s0][m0][f0];'
        f'[b0]format=yuv444p[base];'
        f'[s0]format=rgba,hwupload,scale_vulkan=w={work_w}:h={work_h},'
        f'gblur_vulkan=sigma=0.9:size=5,scale_vulkan=w={src_w}:h={src_h},'
        f'hwdownload,format=rgba,format=yuv444p[sb];'
        f'[m0]format=rgba,hwupload,scale_vulkan=w={work_w}:h={work_h},'
        f'gblur_vulkan=sigma=1.8:size=9,scale_vulkan=w={src_w}:h={src_h},'
        f'hwdownload,format=rgba,format=yuv444p[mb];'
        f'[f0]format=rgba,hwupload,scale_vulkan=w={work_w}:h={work_h},'
        f'gblur_vulkan=sigma=3.2:size=15,scale_vulkan=w={src_w}:h={src_h},'
        f'hwdownload,format=rgba,format=yuv444p[fb];'
        f'[1:v]{trim},gblur=sigma=1.1,scale={src_w}:{src_h}:flags=bicubic,format=gray[ms];'
        f'[2:v]{trim},gblur=sigma=1.1,scale={src_w}:{src_h}:flags=bicubic,format=gray[mm];'
        f'[3:v]{trim},gblur=sigma=1.1,scale={src_w}:{src_h}:flags=bicubic,format=gray[mf];'
        f'[base][sb][ms]maskedmerge[c1];'
        f'[c1][mb][mm]maskedmerge[c2];'
        f'[c2][fb][mf]maskedmerge[c3]'
    )
    if orient:
        graph += f';[c3]{orient}[outv]'
    else:
        graph += ';[c3]null[outv]'

    render_cmd = [
        'ffmpeg', '-y', '-v', 'warning',
        '-init_hw_device', 'vulkan=vk:0', '-filter_hw_device', 'vk',
        '-noautorotate', '-i', str(movie), '-i', str(soft), '-i', str(mid), '-i', str(far),
        '-filter_complex', graph, '-map', '[outv]', '-map', '0:a:0?',
        '-frames:v', str(frame_count),
        '-c:v', 'hevc_nvenc', '-preset', 'p6', '-tune', 'hq', '-rc', 'vbr', '-cq', str(args.cq), '-b:v', '0',
        '-pix_fmt', 'yuv420p',
        '-color_range', color['range'], '-colorspace', color['space'],
        '-color_primaries', color['primaries'], '-color_trc', color['transfer'],
        '-timecode', timecode, '-metadata', f'creation_time={creation_iso}',
        '-c:a', 'copy', '-shortest', str(output),
    ]
    render_started = time.perf_counter()
    run(render_cmd)
    render_seconds = time.perf_counter() - render_started

    result = {
        'pipeline': 'natural-dof-v3-bidirectional',
        'source_package': str(package),
        'source_movie': str(movie),
        'output': str(output),
        'frames': frame_count,
        'fps': fps,
        'source_width': src_w,
        'source_height': src_h,
        'capture_interface_orientation': orientation,
        'first_frame_utc_ns': first_utc_ns,
        'first_frame_utc_iso': datetime.fromtimestamp(first_utc_ns / 1e9, tz=timezone.utc).isoformat(),
        'timecode': timecode,
        'model': str(model),
        'mask_meta': meta,
        'work_width': work_w,
        'work_height': work_h,
        'nvenc_cq': args.cq,
        'color': color,
        'mask_seconds': mask_seconds,
        'render_seconds': render_seconds,
        'total_seconds': mask_seconds + render_seconds,
        'foreground_dof': True,
        'background_dof': True,
    }
    sidecar = output.with_suffix(output.suffix + '.render.json')
    sidecar.write_text(json.dumps(result, indent=2), 'utf-8')

    if not args.keep_masks:
        # Intentionally no automatic deletion. The project safety policy preserves generated intermediates.
        print('--no-keep-masks requested, but automatic deletion is disabled for safety; masks were preserved.')

    print(f'masks:  {mask_seconds:.2f}s')
    print(f'render: {render_seconds:.2f}s')
    print(f'total:  {mask_seconds + render_seconds:.2f}s')
    print(f'timecode: {timecode} / UTC {creation_iso}')
    print(f'wrote {output}')
    print(f'wrote {sidecar}')


if __name__ == '__main__':
    main()
