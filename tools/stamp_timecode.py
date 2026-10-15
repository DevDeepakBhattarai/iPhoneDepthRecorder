from __future__ import annotations

import argparse
import json
import math
import pathlib
import subprocess
from datetime import datetime, timezone


def probe_fps(movie: pathlib.Path) -> float:
    data = json.loads(subprocess.check_output([
        'ffprobe','-v','error','-select_streams','v:0',
        '-show_entries','stream=avg_frame_rate','-of','json',str(movie)
    ], text=True))
    rate=data['streams'][0]['avg_frame_rate']
    num,den=rate.split('/')
    return float(num)/float(den)


def first_video_utc_ns(frames_jsonl: pathlib.Path) -> int:
    for line in frames_jsonl.read_text('utf-8-sig').splitlines():
        if not line.strip():
            continue
        row=json.loads(line)
        if row.get('video_appended'):
            return int(row['utc_ns'])
    raise RuntimeError('frames.jsonl contains no appended video frame')


def smpte_from_utc_ns(utc_ns: int, fps: float) -> tuple[str,str]:
    seconds=utc_ns/1_000_000_000
    whole=math.floor(seconds)
    frac=seconds-whole
    dt=datetime.fromtimestamp(whole,tz=timezone.utc)
    nominal=max(1,int(round(fps)))
    ff=int(math.floor(frac*nominal+0.5))
    if ff>=nominal:
        dt=datetime.fromtimestamp(whole+1,tz=timezone.utc)
        ff=0
    tc=f'{dt.hour:02d}:{dt.minute:02d}:{dt.second:02d}:{ff:02d}'
    iso=datetime.fromtimestamp(seconds,tz=timezone.utc).isoformat(timespec='microseconds').replace('+00:00','Z')
    return tc,iso


def main() -> None:
    ap=argparse.ArgumentParser(description='Add standard QuickTime timecode to a DepthRecorder master without re-encoding')
    ap.add_argument('package',type=pathlib.Path)
    ap.add_argument('output',type=pathlib.Path,nargs='?')
    args=ap.parse_args()

    package=args.package
    movie=package/'master.mov'
    frames=package/'frames.jsonl'
    if not movie.exists() or not frames.exists():
        raise SystemExit('package must contain master.mov and frames.jsonl')

    output=args.output or (package/'master-timecoded.mov')
    fps=probe_fps(movie)
    utc_ns=first_video_utc_ns(frames)
    tc,iso=smpte_from_utc_ns(utc_ns,fps)

    output.parent.mkdir(parents=True,exist_ok=True)
    subprocess.check_call([
        'ffmpeg','-y','-v','error','-i',str(movie),
        '-map','0:v:0','-map','0:a:0?','-c','copy',
        '-timecode',tc,'-metadata',f'creation_time={iso}',str(output)
    ])
    print(f'{tc}  {iso}')
    print(output)


if __name__=='__main__':
    main()
