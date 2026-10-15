from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import time
from datetime import datetime, timezone

from render_bokeh import probe_video, read_frame_map, smpte_from_utc_ns


def run(cmd: list[str]) -> None:
    print('> ' + ' '.join(f'"{x}"' if ' ' in x else x for x in cmd), flush=True)
    subprocess.check_call(cmd)


def probe_color(movie: pathlib.Path) -> dict[str, str]:
    data = json.loads(subprocess.check_output([
        'ffprobe','-v','error','-select_streams','v:0',
        '-show_entries','stream=color_range,color_space,color_transfer,color_primaries',
        '-of','json',str(movie)
    ], text=True))
    s = data['streams'][0]
    return {
        'range': s.get('color_range') or 'tv',
        'space': s.get('color_space') or 'bt709',
        'transfer': s.get('color_transfer') or 'bt709',
        'primaries': s.get('color_primaries') or 'bt709',
    }



def orientation_filter(name: str) -> str:
    if name == 'portrait':
        return 'transpose=clock'
    if name == 'portraitUpsideDown':
        return 'transpose=cclock'
    if name == 'landscapeLeft':
        return 'hflip,vflip'
    return ''
def main() -> None:
    ap = argparse.ArgumentParser(description='Fast depth-aware cinematic render using LiDAR mask + FFmpeg/NVENC')
    ap.add_argument('package', type=pathlib.Path)
    ap.add_argument('output', type=pathlib.Path)
    ap.add_argument('--mask-width', type=int, default=960)
    ap.add_argument('--focus-x', type=float, default=None)
    ap.add_argument('--focus-y', type=float, default=None)
    ap.add_argument('--dof', type=float, default=0.16)
    ap.add_argument('--transition', type=float, default=0.28)
    ap.add_argument('--strength', type=float, default=0.90)
    ap.add_argument('--edge-protect', type=int, default=2)
    ap.add_argument('--max-radius', type=int, default=40, help='maximum full-resolution variable blur radius')
    ap.add_argument('--renderer', choices=('varblur','vulkan'), default='varblur')
    ap.add_argument('--vulkan-width', type=int, default=1600)
    ap.add_argument('--vulkan-sigma', type=float, default=18.0, help='apparent sigma at full output width')
    ap.add_argument('--cq', type=int, default=18, help='NVENC constant-quality target')
    ap.add_argument('--limit', type=int, default=0)
    args = ap.parse_args()

    package = args.package.resolve()
    movie = package / 'master.mov'
    orientation = 'landscapeRight'
    manifest_path = package / 'manifest.json'
    if manifest_path.exists():
        orientation = json.loads(manifest_path.read_text('utf-8-sig')).get('capture_interface_orientation', orientation)
    frames_path = package / 'frames.jsonl'
    depth_path = package / 'depth.bin'
    for required in (movie, frames_path, depth_path):
        if not required.exists():
            raise SystemExit(f'missing {required}')

    args.output.parent.mkdir(parents=True, exist_ok=True)
    mask = args.output.with_suffix(args.output.suffix + '.depthmask.mkv')
    mask_meta = mask.with_suffix(mask.suffix + '.json')

    src_w, src_h, fps, probed_count = probe_video(movie)
    rows = [r for r in read_frame_map(frames_path) if r.get('video_appended')]
    frame_count = min(len(rows), probed_count or len(rows))
    if args.limit > 0:
        frame_count = min(frame_count, args.limit)
    if frame_count <= 0:
        raise SystemExit('no video frames')
    duration = frame_count / fps

    first_utc_ns = int(rows[0]['utc_ns'])
    timecode, creation_iso = smpte_from_utc_ns(first_utc_ns, fps)
    color = probe_color(movie)

    tool_dir = pathlib.Path(__file__).resolve().parent
    mask_cmd = [
        sys.executable, str(tool_dir / 'make_bokeh_mask.py'), str(package), str(mask),
        '--width', str(args.mask_width),
        '--dof', str(args.dof), '--transition', str(args.transition),
        '--strength', str(args.strength), '--edge-protect', str(args.edge_protect),
    ]
    if args.focus_x is not None:
        mask_cmd += ['--focus-x', str(args.focus_x)]
    if args.focus_y is not None:
        mask_cmd += ['--focus-y', str(args.focus_y)]
    if args.limit > 0:
        mask_cmd += ['--limit', str(frame_count)]

    started = time.perf_counter()
    run(mask_cmd)
    mask_seconds = time.perf_counter() - started

    trim = f'trim=end_frame={frame_count},setpts=PTS-STARTPTS'
    mask_chain = f'[1:v]setpts=PTS-STARTPTS,scale={src_w}:{src_h}:flags=bicubic,format=gray[radius]'

    if args.renderer == 'varblur':
        max_r = max(1, min(255, args.max_radius))
        graph = (
            f'[0:v]{trim},format=yuv444p[base];'
            f'{mask_chain};'
            f'[base][radius]varblur=min_r=0:max_r={max_r}:planes=7[blur];'
            f'[base][blur][radius]maskedmerge[merged]'
        )
        hw_prefix: list[str] = []
    else:
        vw = max(320, min(src_w, args.vulkan_width))
        vh = max(2, int(round(src_h * vw / src_w)))
        vh -= vh % 2
        sigma_work = args.vulkan_sigma * vw / src_w
        kernel = max(3, int(round(sigma_work * 4.0)) | 1)
        kernel = min(127, kernel)
        graph = (
            f'[0:v]{trim},split=2[base0][gpu0];'
            f'[gpu0]format=rgba,hwupload,scale_vulkan=w={vw}:h={vh},'
            f'gblur_vulkan=sigma={sigma_work:.4f}:size={kernel},'
            f'scale_vulkan=w={src_w}:h={src_h},hwdownload,format=rgba,format=yuv444p[blur];'
            f'[base0]format=yuv444p[base];'
            f'{mask_chain};'
            f'[base][blur][radius]maskedmerge[merged]'
        )
        hw_prefix = ['-init_hw_device','vulkan=vk:0','-filter_hw_device','vk']

    orient_filter = orientation_filter(orientation)
    if orient_filter:
        graph += f';[merged]{orient_filter}[outv]'
    else:
        graph += ';[merged]null[outv]'

    render_cmd = [
        'ffmpeg','-y','-v','warning',*hw_prefix,
        '-noautorotate','-i',str(movie),'-i',str(mask),
        '-filter_complex',graph,
        '-map','[outv]','-map','0:a:0?',
        '-t',f'{duration:.9f}',
        '-c:v','hevc_nvenc','-preset','p6','-tune','hq','-rc','vbr','-cq',str(args.cq),'-b:v','0',
        '-pix_fmt','yuv420p',
        '-color_range',color['range'], '-colorspace',color['space'],
        '-color_primaries',color['primaries'], '-color_trc',color['transfer'],
        '-timecode',timecode,'-metadata',f'creation_time={creation_iso}',
        '-c:a','copy','-shortest',str(args.output)
    ]

    render_started = time.perf_counter()
    run(render_cmd)
    render_seconds = time.perf_counter() - render_started

    info = json.loads(mask_meta.read_text('utf-8-sig')) if mask_meta.exists() else {}
    result_meta = {
        'source_package': str(package),
        'source_movie': str(movie),
        'output': str(args.output.resolve()),
        'renderer': args.renderer,
        'width': src_w,
        'height': src_h,
        'fps': fps,
        'frames': frame_count,
        'duration_seconds': duration,
        'first_frame_utc_ns': first_utc_ns,
        'first_frame_utc_iso': datetime.fromtimestamp(first_utc_ns / 1e9, tz=timezone.utc).isoformat(),
        'timecode': timecode,
        'mask': str(mask.resolve()),
        'mask_settings': info,
        'max_radius': args.max_radius,
        'vulkan_width': args.vulkan_width if args.renderer == 'vulkan' else None,
        'vulkan_sigma': args.vulkan_sigma if args.renderer == 'vulkan' else None,
        'nvenc_cq': args.cq,
        'color': color,
        'capture_interface_orientation': orientation,
        'mask_seconds': mask_seconds,
        'render_seconds': render_seconds,
        'total_seconds': mask_seconds + render_seconds,
    }
    result_path = args.output.with_suffix(args.output.suffix + '.render.json')
    result_path.write_text(json.dumps(result_meta, indent=2), 'utf-8')

    print(f'mask:   {mask_seconds:.2f}s')
    print(f'render: {render_seconds:.2f}s')
    print(f'total:  {mask_seconds + render_seconds:.2f}s')
    print(f'timecode: {timecode} / UTC {creation_iso}')
    print(f'wrote {args.output}')
    print(f'wrote {result_path}')


if __name__ == '__main__':
    main()
