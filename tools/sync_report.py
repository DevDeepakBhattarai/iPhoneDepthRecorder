from __future__ import annotations
import argparse, json, pathlib, subprocess
from datetime import datetime, timezone


def first_video_utc(package: pathlib.Path) -> int:
    with (package / 'frames.jsonl').open('r', encoding='utf-8-sig') as f:
        for line in f:
            if not line.strip(): continue
            row=json.loads(line)
            if row.get('video_appended') and row.get('utc_ns') is not None:
                return int(row['utc_ns'])
    raise RuntimeError('no appended video UTC in frames.jsonl')


def probe_duration(path: pathlib.Path) -> float | None:
    if not path or not path.exists(): return None
    try:
        return float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=nw=1:nk=1',str(path)],text=True).strip())
    except Exception:
        return None


def iso(ns: int) -> str:
    return datetime.fromtimestamp(ns/1e9,tz=timezone.utc).isoformat(timespec='microseconds')


def main():
    ap=argparse.ArgumentParser(description='Create an exact UTC alignment report for a Depth Recorder take and OBS recording')
    ap.add_argument('package',type=pathlib.Path)
    ap.add_argument('--obs-recording',type=pathlib.Path,default=None)
    ap.add_argument('--obs-sync',type=pathlib.Path,default=None)
    ap.add_argument('--output',type=pathlib.Path,default=None)
    args=ap.parse_args()
    package=args.package.resolve()
    sync_path=args.obs_sync or (package/'obs_sync.json')
    sync=json.loads(sync_path.read_text('utf-8-sig')) if sync_path.exists() else {}
    phone_first=first_video_utc(package)
    events=sync.get('obs_events',{})
    obs_started=(events.get('started') or {}).get('utc_ns')
    obs_starting=(events.get('starting') or {}).get('utc_ns')
    obs_anchor=int(obs_started or obs_starting) if (obs_started or obs_starting) is not None else None
    obs_recording=args.obs_recording or (pathlib.Path(sync['obs_recording']) if sync.get('obs_recording') else None)
    result={
        'schema':'depthrecorder-alignment-v1',
        'phone_package':str(package),
        'phone_first_frame_utc_ns':phone_first,
        'phone_first_frame_utc_iso':iso(phone_first),
        'obs_recording':str(obs_recording) if obs_recording else None,
        'obs_anchor':'recording_started' if obs_started else ('recording_starting' if obs_starting else None),
        'obs_anchor_utc_ns':obs_anchor,
        'obs_anchor_utc_iso':iso(obs_anchor) if obs_anchor else None,
        'phone_duration_seconds':probe_duration(package/'master.mov'),
        'obs_duration_seconds':probe_duration(obs_recording) if obs_recording else None,
    }
    if obs_anchor is not None:
        offset=phone_first-obs_anchor
        result['phone_minus_obs_ns']=offset
        result['phone_minus_obs_seconds']=offset/1e9
        result['timeline_instruction']='place_phone_at_seconds_from_obs_start'
        result['timeline_phone_start_seconds']=offset/1e9
    output=args.output or (package/'alignment.json')
    output.write_text(json.dumps(result,indent=2),'utf-8')
    print(json.dumps(result,indent=2))
    print(f'wrote {output}')
if __name__=='__main__': main()
