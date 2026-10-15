from __future__ import annotations

import argparse
import asyncio
import json
import pathlib
from datetime import datetime, timezone
from typing import Any

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService
from pymobiledevice3.services.installation_proxy import InstallationProxyService

BASE_BUNDLE_ID = "com.deepak.depthrecorder"
DISPLAY_NAME = "Depth Recorder"
DEFAULT_DATA_ROOT = pathlib.Path(__import__('os').environ.get('DEPTHRECORDER_DATA_ROOT', pathlib.Path.home() / 'Videos' / 'DepthRecorder'))
DEFAULT_DESTINATION = DEFAULT_DATA_ROOT / 'device-captures'
REQUIRED_RECORDING_FILES = ("master.mov", "frames.jsonl")


def safe_child_name(name: str) -> str:
    if not name or name in {".", ".."} or "/" in name or "\\" in name:
        raise RuntimeError(f"unsafe device filename: {name!r}")
    return name


def unique_destination(root: pathlib.Path, recording_name: str) -> pathlib.Path:
    root.mkdir(parents=True, exist_ok=True)
    candidate = root / recording_name
    if not candidate.exists():
        return candidate

    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S_%fZ")
    index = 1
    while True:
        suffix = f"__copy_{stamp}" if index == 1 else f"__copy_{stamp}_{index}"
        candidate = root / f"{recording_name}{suffix}"
        if not candidate.exists():
            return candidate
        index += 1


def is_depth_recorder_app(bundle_id: str, info: dict[str, Any]) -> bool:
    actual = str(info.get("CFBundleIdentifier") or bundle_id or "")
    alternate = str(info.get("ALTBundleIdentifier") or "")
    display = str(info.get("CFBundleDisplayName") or info.get("CFBundleName") or "")
    return (
        actual == BASE_BUNDLE_ID
        or actual.startswith(BASE_BUNDLE_ID + ".")
        or alternate == BASE_BUNDLE_ID
        or display == DISPLAY_NAME
    )


async def discover_bundle_ids(lockdown) -> list[str]:
    proxy = InstallationProxyService(lockdown)
    try:
        apps = await proxy.get_apps(application_type="User")
    finally:
        await proxy.close()

    found: list[str] = []
    for key, info in apps.items():
        if is_depth_recorder_app(key, info):
            actual = str(info.get("CFBundleIdentifier") or key)
            if actual and actual not in found:
                found.append(actual)
    return found


async def recordings_for_bundle(lockdown, bundle_id: str) -> list[dict[str, Any]]:
    service = await HouseArrestService.create(lockdown, bundle_id, documents_only=False)
    try:
        try:
            names = await service.listdir("/Documents/Recordings")
        except Exception:
            return []

        items: list[dict[str, Any]] = []
        for name in names:
            if name in {".", ".."} or not name.endswith(".depthrec"):
                continue
            safe_child_name(name)
            remote = f"/Documents/Recordings/{name}"
            try:
                if not await service.isdir(remote):
                    continue
                stat = await service.stat(remote)
                mtime = stat.get("st_mtime")
                mtime_ts = mtime.timestamp() if hasattr(mtime, "timestamp") else 0.0
            except Exception:
                mtime_ts = 0.0
            items.append({
                "bundle_id": bundle_id,
                "name": name,
                "remote": remote,
                "mtime": mtime_ts,
            })
        return items
    finally:
        await service.close()


async def discover_recordings(lockdown) -> list[dict[str, Any]]:
    bundle_ids = await discover_bundle_ids(lockdown)
    if not bundle_ids:
        raise RuntimeError(
            "Depth Recorder is not installed on the connected iPhone. "
            "Sideload the IPA first, then reconnect the unlocked phone."
        )

    all_recordings: list[dict[str, Any]] = []
    for bundle_id in bundle_ids:
        try:
            all_recordings.extend(await recordings_for_bundle(lockdown, bundle_id))
        except Exception as exc:
            print(f"warning: could not inspect {bundle_id}: {exc}")

    # Recording names begin with sortable UTC timestamps. mtime is a tie-breaker.
    all_recordings.sort(key=lambda item: (item["name"], item["mtime"]), reverse=True)
    return all_recordings


async def copy_tree_read_only(service: HouseArrestService, remote: str, local: pathlib.Path,
                              records: list[dict[str, Any]], quiet: bool) -> None:
    if await service.isdir(remote):
        local.mkdir(parents=True, exist_ok=False)
        for raw_name in await service.listdir(remote):
            if raw_name in {".", ".."}:
                continue
            name = safe_child_name(raw_name)
            await copy_tree_read_only(
                service,
                f"{remote.rstrip('/')}/{name}",
                local / name,
                records,
                quiet,
            )
        return

    stat = await service.stat(remote)
    expected_size = int(stat.get("st_size") or 0)
    local.parent.mkdir(parents=True, exist_ok=True)
    await service.pull(remote, str(local), progress_bar=not quiet)
    actual_size = local.stat().st_size
    if actual_size != expected_size:
        raise RuntimeError(
            f"size mismatch after transfer for {remote}: device={expected_size}, local={actual_size}"
        )
    records.append({
        "remote": remote,
        "local": str(local),
        "bytes": actual_size,
    })


async def pull_recording(lockdown, item: dict[str, Any], destination_root: pathlib.Path,
                         quiet: bool) -> pathlib.Path:
    destination = unique_destination(destination_root, item["name"])
    service = await HouseArrestService.create(lockdown, item["bundle_id"], documents_only=False)
    copied: list[dict[str, Any]] = []
    try:
        await copy_tree_read_only(service, item["remote"], destination, copied, quiet)
    except Exception:
        # Intentionally do NOT remove a partial local transfer: preserving data is safer,
        # and the partial directory is visibly distinct from the phone source.
        raise
    finally:
        await service.close()

    missing = [name for name in REQUIRED_RECORDING_FILES if not (destination / name).is_file()]
    manifest_data = {}
    manifest_path = destination / "manifest.json"
    if manifest_path.is_file():
        try:
            manifest_data = json.loads(manifest_path.read_text("utf-8-sig"))
        except Exception:
            manifest_data = {}
    if manifest_data.get("depth_available", True):
        for name in ("depth.bin", "calibration.json"):
            if not (destination / name).is_file():
                missing.append(name)
    transfer_info = {
        "transfer_version": 1,
        "mode": "read-only phone container pull",
        "source_bundle_id": item["bundle_id"],
        "source_recording": item["name"],
        "pulled_at_utc": datetime.now(timezone.utc).isoformat(),
        "files": copied,
        "required_files_missing": missing,
        "manifest_present": (destination / "manifest.json").is_file(),
    }
    (destination / "transfer.json").write_text(
        json.dumps(transfer_info, indent=2), encoding="utf-8"
    )

    if missing:
        print("warning: transfer completed, but required recording files are missing: " + ", ".join(missing))
    if not (destination / "manifest.json").exists():
        print("warning: manifest.json is absent (older/incompletely finalized build). Core RGB-D files may still be valid.")
    return destination


async def async_main(args: argparse.Namespace) -> int:
    lockdown = await create_using_usbmux()
    try:
        recordings = await discover_recordings(lockdown)
        if not recordings:
            raise RuntimeError("Depth Recorder is installed, but no .depthrec recordings were found.")

        if args.list:
            for idx, item in enumerate(recordings, start=1):
                print(f"{idx:2d}. {item['name']}  [{item['bundle_id']}]")
            return 0

        if args.name:
            matches = [item for item in recordings if item["name"] == args.name]
            if not matches:
                available = ", ".join(item["name"] for item in recordings[:8])
                raise RuntimeError(f"recording not found: {args.name}. Recent recordings: {available}")
            selected = matches[0]
        else:
            selected = recordings[0]

        print(f"Phone source: {selected['bundle_id']}:{selected['remote']}")
        print(f"Mode: read-only copy (nothing is removed from the iPhone)")
        destination = await pull_recording(lockdown, selected, args.destination.resolve(), args.quiet)
        print(f"Pulled: {destination}")
        return 0
    finally:
        await lockdown.close()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Safely copy Depth Recorder takes from a connected iPhone. This tool has no delete operation."
    )
    parser.add_argument(
        "--destination",
        type=pathlib.Path,
        default=DEFAULT_DESTINATION,
        help=f"Windows destination root (default: {DEFAULT_DESTINATION})",
    )
    parser.add_argument("--name", help="pull a specific .depthrec directory instead of the newest")
    parser.add_argument("--list", action="store_true", help="list recordings only; copy nothing")
    parser.add_argument("--quiet", action="store_true", help="hide per-file transfer progress bars")
    args = parser.parse_args()

    try:
        raise SystemExit(asyncio.run(async_main(args)))
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as exc:
        print(f"error: {exc}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
