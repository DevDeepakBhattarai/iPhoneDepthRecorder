from __future__ import annotations

import argparse
import asyncio
import json
import os
import pathlib
import subprocess
import sys
import time
from datetime import datetime, timezone

from phone_control import connect_with_optional_launch, wait_for_idle, utc_ns

TOOLS = pathlib.Path(__file__).resolve().parent
PROJECT = TOOLS.parent
DATA_ROOT = pathlib.Path(os.environ.get('DEPTHRECORDER_DATA_ROOT', pathlib.Path.home() / 'Videos' / 'DepthRecorder'))
SYNC_ROOT = DATA_ROOT / 'obs-sync'
CURRENT = SYNC_ROOT / 'current.json'
HISTORY = SYNC_ROOT / 'sessions'
CAPTURES = DATA_ROOT / 'device-captures'
SYSTEM_PY = pathlib.Path(os.environ.get('DEPTHRECORDER_RENDER_PYTHON', sys.executable))


def iso(ns: int) -> str:
    return datetime.fromtimestamp(ns / 1e9, tz=timezone.utc).isoformat(timespec='microseconds')


def map_obs_monotonic_to_utc(obs_ns: int) -> dict:
    best = None
    for _ in range(8):
        p0 = time.perf_counter_ns()
        wall = time.time_ns()
        p1 = time.perf_counter_ns()
        width = p1 - p0
        item = (width, p0, wall, p1)
        if best is None or width < best[0]:
            best = item
    assert best is not None
    width, p0, wall, p1 = best
    mid = (p0 + p1) // 2
    event_utc = wall + (obs_ns - mid)
    return {
        'obs_monotonic_ns': obs_ns,
        'utc_ns': event_utc,
        'utc_iso': iso(event_utc),
        'mapping_uncertainty_ns': width // 2,
        'helper_perf_mid_ns': mid,
        'helper_wall_ns': wall,
    }


def read_json(path: pathlib.Path, default=None):
    try:
        return json.loads(path.read_text('utf-8-sig'))
    except Exception:
        return {} if default is None else default


def atomic_write(path: pathlib.Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f'.{os.getpid()}.tmp')
    tmp.write_text(json.dumps(data, indent=2), 'utf-8')
    os.replace(tmp, path)


def session_path(session_id: str) -> pathlib.Path:
    return HISTORY / f'{session_id}.json'


def load_current() -> dict:
    state = read_json(CURRENT, {})
    if not state:
        return {}
    path = pathlib.Path(state.get('session_file', ''))
    return read_json(path, {}) if path.exists() else state


def save_session(state: dict) -> None:
    path = session_path(state['session_id'])
    atomic_write(path, state)
    atomic_write(CURRENT, {'session_id': state['session_id'], 'session_file': str(path)})


def make_session_id(utc_event_ns: int) -> str:
    dt = datetime.fromtimestamp(utc_event_ns / 1e9, tz=timezone.utc)
    return dt.strftime('%Y%m%d_%H%M%S_') + f'{utc_event_ns % 1_000_000_000:09d}Z'


async def phone_start(state: dict) -> None:
    try:
        response = await connect_with_optional_launch('start_record', True, 18.0)
        state['phone_start_response'] = response
    except Exception as exc:
        state['phone_start_response'] = {'ok': False, 'error': str(exc), 'host_utc_ns': utc_ns()}


async def phone_stop(state: dict) -> None:
    try:
        response = await connect_with_optional_launch('stop_record', False, 0.0)
        state['phone_stop_response'] = response
    except Exception as exc:
        state['phone_stop_response'] = {'ok': False, 'error': str(exc), 'host_utc_ns': utc_ns()}


def run_pull() -> dict:
    script = TOOLS / 'pull_latest_recording.py'
    proc = subprocess.run([sys.executable, str(script), '--destination', str(CAPTURES), '--quiet'], capture_output=True, text=True, timeout=240)
    pulled = None
    for line in proc.stdout.splitlines():
        if line.startswith('Pulled: '):
            pulled = line[len('Pulled: '):].strip()
    return {'returncode': proc.returncode, 'stdout': proc.stdout, 'stderr': proc.stderr, 'package': pulled}


def first_phone_utc(package: pathlib.Path) -> int | None:
    frames = package / 'frames.jsonl'
    if not frames.exists():
        return None
    with frames.open('r', encoding='utf-8-sig') as f:
        for line in f:
            if line.strip():
                row = json.loads(line)
                if row.get('video_appended') and row.get('utc_ns') is not None:
                    return int(row['utc_ns'])
    return None


def write_sync_sidecars(state: dict, package: pathlib.Path) -> None:
    phone_first = first_phone_utc(package)
    state['phone_package'] = str(package)
    state['phone_first_frame_utc_ns'] = phone_first
    if phone_first is not None:
        state['phone_first_frame_utc_iso'] = iso(phone_first)
    obs_started = ((state.get('events') or {}).get('started') or {}).get('utc_ns')
    obs_starting = ((state.get('events') or {}).get('starting') or {}).get('utc_ns')
    anchor = obs_started or obs_starting
    if phone_first is not None and anchor is not None:
        offset = phone_first - int(anchor)
        state['phone_minus_obs_start_ns'] = offset
        state['phone_minus_obs_start_seconds'] = offset / 1e9
        state['alignment_instruction'] = (
            'Place phone clip this many seconds after OBS time zero' if offset >= 0
            else 'Trim this many seconds from the beginning of the phone clip'
        )
    sync = {
        'schema': 'depthrecorder-obs-sync-v1',
        'session_id': state.get('session_id'),
        'obs_recording': state.get('obs_recording'),
        'obs_events': state.get('events', {}),
        'phone_first_frame_utc_ns': state.get('phone_first_frame_utc_ns'),
        'phone_first_frame_utc_iso': state.get('phone_first_frame_utc_iso'),
        'phone_minus_obs_start_ns': state.get('phone_minus_obs_start_ns'),
        'phone_minus_obs_start_seconds': state.get('phone_minus_obs_start_seconds'),
    }
    atomic_write(package / 'obs_sync.json', sync)
    obs_path = state.get('obs_recording')
    if obs_path:
        try:
            atomic_write(pathlib.Path(obs_path + '.depthrec-sync.json'), sync)
        except Exception as exc:
            state['obs_sidecar_error'] = str(exc)


def render_package(state: dict, package: pathlib.Path) -> None:
    if not SYSTEM_PY.exists():
        state['render'] = {'ok': False, 'error': f'missing render Python: {SYSTEM_PY}'}
        return
    output = package / 'cinematic_natural.mov'
    log = package / 'cinematic_natural.render.log'
    err = package / 'cinematic_natural.render.err.log'
    cmd = [str(SYSTEM_PY), str(TOOLS / 'render_natural_dof.py'), str(package), str(output)]
    started = utc_ns()
    with log.open('w', encoding='utf-8') as out, err.open('w', encoding='utf-8') as e:
        proc = subprocess.run(cmd, stdout=out, stderr=e)
    state['render'] = {
        'ok': proc.returncode == 0,
        'returncode': proc.returncode,
        'output': str(output),
        'stdout_log': str(log),
        'stderr_log': str(err),
        'started_utc_ns': started,
        'finished_utc_ns': utc_ns(),
    }


async def handle(args: argparse.Namespace) -> int:
    SYNC_ROOT.mkdir(parents=True, exist_ok=True)
    HISTORY.mkdir(parents=True, exist_ok=True)
    mapped = map_obs_monotonic_to_utc(args.obs_monotonic_ns)

    if args.event == 'preflight':
        result = {}
        try:
            result = await connect_with_optional_launch('status', True, 18.0)
        except Exception as exc:
            result = {'ok': False, 'error': str(exc), 'utc_ns': utc_ns()}
        atomic_write(SYNC_ROOT / 'preflight.json', {'checked_utc_ns': utc_ns(), 'checked_utc_iso': iso(utc_ns()), 'phone': result})
        return 0

    if args.event == 'starting':
        state = {
            'schema': 'depthrecorder-obs-session-v1',
            'session_id': make_session_id(mapped['utc_ns']),
            'created_utc_ns': utc_ns(),
            'events': {'starting': mapped},
            'auto_render': args.auto_render,
        }
        save_session(state)
        await phone_start(state)
        latest = load_current()
        if latest.get('session_id') == state['session_id']:
            latest['phone_start_response'] = state.get('phone_start_response')
            save_session(latest)
        else:
            save_session(state)
        return 0

    state = load_current()
    if not state:
        state = {
            'schema': 'depthrecorder-obs-session-v1',
            'session_id': make_session_id(mapped['utc_ns']),
            'created_utc_ns': utc_ns(),
            'events': {},
            'warning': 'OBS event arrived without a prior starting event',
            'auto_render': args.auto_render,
        }
    state.setdefault('events', {})[args.event] = mapped
    if args.obs_path:
        state['obs_recording'] = args.obs_path
    save_session(state)

    if args.event == 'started':
        return 0
    if args.event == 'stopping':
        await phone_stop(state)
        latest = load_current()
        if latest.get('session_id') == state['session_id']:
            latest['phone_stop_response'] = state.get('phone_stop_response')
            latest.setdefault('events', {})['stopping'] = mapped
            save_session(latest)
        else:
            save_session(state)
        return 0

    # stopped: never associate an old phone take with a new OBS recording if Start failed.
    start_response = state.get('phone_start_response') or {}
    if not start_response.get('ok'):
        state['pull'] = {
            'skipped': True,
            'reason': 'phone_start_was_not_confirmed',
            'phone_start_response': start_response,
        }
        state['completed_utc_ns'] = utc_ns()
        state['completed_utc_iso'] = iso(state['completed_utc_ns'])
        save_session(state)
        return 0

    # Start was confirmed: wait for the phone writer to become idle, then safely pull the finished package.
    try:
        state['phone_finalize'] = await wait_for_idle(60.0)
    except Exception as exc:
        state['phone_finalize'] = {'idle': False, 'error': str(exc)}
    save_session(state)

    pull = await asyncio.to_thread(run_pull)
    state['pull'] = pull
    save_session(state)
    package_text = pull.get('package')
    if package_text:
        package = pathlib.Path(package_text)
        write_sync_sidecars(state, package)
        save_session(state)
        if args.auto_render:
            await asyncio.to_thread(render_package, state, package)
            save_session(state)
    state['completed_utc_ns'] = utc_ns()
    state['completed_utc_iso'] = iso(state['completed_utc_ns'])
    save_session(state)
    return 0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('event', choices=('preflight', 'starting', 'started', 'stopping', 'stopped'))
    ap.add_argument('--obs-monotonic-ns', required=True, type=int)
    ap.add_argument('--obs-path', default='')
    ap.add_argument('--auto-render', action='store_true')
    args = ap.parse_args()
    try:
        raise SystemExit(asyncio.run(handle(args)))
    except Exception as exc:
        SYNC_ROOT.mkdir(parents=True, exist_ok=True)
        with (SYNC_ROOT / 'errors.log').open('a', encoding='utf-8') as f:
            f.write(f'{iso(utc_ns())} {args.event}: {exc!r}\n')
        raise


if __name__ == '__main__':
    main()
