from __future__ import annotations

import argparse
import asyncio
import json
import pathlib
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import Any

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.installation_proxy import InstallationProxyService
from pymobiledevice3.usbmux import select_device

BASE_BUNDLE_ID = "com.deepak.depthrecorder"
CLIENT_ID = "depthrecorder-obs-v1"
PORT = 9989
PMD_EXE = pathlib.Path(sys.executable).with_name("pymobiledevice3.exe")


def utc_ns() -> int:
    return time.time_ns()


def utc_iso(ns: int | None = None) -> str:
    ns = ns if ns is not None else utc_ns()
    return datetime.fromtimestamp(ns / 1e9, tz=timezone.utc).isoformat(timespec="microseconds")


async def discover_bundle_id() -> str:
    lockdown = await create_using_usbmux()
    proxy = InstallationProxyService(lockdown)
    try:
        apps = await proxy.get_apps(application_type="User")
        for key, info in apps.items():
            actual = str(info.get("CFBundleIdentifier") or key)
            alt = str(info.get("ALTBundleIdentifier") or "")
            display = str(info.get("CFBundleDisplayName") or info.get("CFBundleName") or "")
            if actual == BASE_BUNDLE_ID or actual.startswith(BASE_BUNDLE_ID + ".") or alt == BASE_BUNDLE_ID or display == "Depth Recorder":
                return actual
    finally:
        await proxy.close()
        await lockdown.close()
    raise RuntimeError("Depth Recorder is not installed on the connected iPhone")


async def send_once(command: str, timeout: float = 3.0) -> dict[str, Any]:
    dev = await select_device(connection_type="USB")
    if dev is None:
        raise RuntimeError("No USB iPhone found")
    sock = await dev.connect(PORT)
    try:
        sock.settimeout(timeout)
        request = {
            "client": CLIENT_ID,
            "cmd": command,
            "host_send_utc_ns": utc_ns(),
        }
        sock.sendall(json.dumps(request, separators=(",", ":")).encode("utf-8") + b"\n")
        chunks: list[bytes] = []
        total = 0
        while total < 65536:
            chunk = sock.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if b"\n" in chunk:
                break
        raw = b"".join(chunks).split(b"\n", 1)[0]
        if not raw:
            raise RuntimeError("Phone returned an empty control response")
        response = json.loads(raw.decode("utf-8"))
        response["host_receive_utc_ns"] = utc_ns()
        response["command"] = command
        return response
    finally:
        sock.close()


def try_launch_app(bundle_id: str, timeout: float = 25.0) -> dict[str, Any]:
    if not PMD_EXE.exists():
        return {"launched": False, "error": f"missing {PMD_EXE}"}

    attempts = [
        [
            str(PMD_EXE), "developer", "core-device", "launch-application",
            "--userspace", "--no-kill-existing", bundle_id,
        ],
        [
            str(PMD_EXE), "developer", "dvt", "launch",
            "--userspace", "--no-kill-existing", bundle_id,
        ],
    ]
    started = utc_ns()
    results: list[dict[str, Any]] = []
    for cmd in attempts:
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
            item = {
                "method": "core-device" if "core-device" in cmd else "dvt",
                "returncode": proc.returncode,
                "stdout": proc.stdout.strip(),
                "stderr": proc.stderr.strip(),
            }
            results.append(item)
            if proc.returncode == 0:
                return {
                    "launched": True,
                    "method": item["method"],
                    "attempts": results,
                    "started_utc_ns": started,
                    "finished_utc_ns": utc_ns(),
                }
        except Exception as exc:
            results.append({
                "method": "core-device" if "core-device" in cmd else "dvt",
                "error": str(exc),
            })
    return {
        "launched": False,
        "attempts": results,
        "started_utc_ns": started,
        "finished_utc_ns": utc_ns(),
    }


async def connect_with_optional_launch(command: str, launch_if_needed: bool, startup_timeout: float) -> dict[str, Any]:
    first_error: Exception | None = None
    try:
        first = await send_once(command)
        if first.get("ok") or command != "start_record" or first.get("error") not in {"not_ready", "finalizing"}:
            return first
        first_error = RuntimeError(first.get("error") or "phone_not_ready")
    except Exception as exc:
        first_error = exc
    if not launch_if_needed:
        raise first_error

    bundle = await discover_bundle_id()
    launch = await asyncio.to_thread(try_launch_app, bundle)
    deadline = time.monotonic() + startup_timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        await asyncio.sleep(0.5)
        try:
            response = await send_once(command)
            if command == "start_record" and not response.get("ok") and response.get("error") in {"not_ready", "finalizing"}:
                last_error = RuntimeError(response.get("error") or "phone_not_ready")
                continue
            response["app_launch"] = launch
            response["bundle_id"] = bundle
            return response
        except Exception as exc:
            last_error = exc
    raise RuntimeError(f"Depth Recorder control port did not become ready after launch: {last_error or first_error}")


async def wait_for_idle(timeout: float = 45.0) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last: dict[str, Any] = {}
    while time.monotonic() < deadline:
        try:
            last = await send_once("status")
            if last.get("ok") and not last.get("recording") and not last.get("finalizing"):
                last["idle"] = True
                return last
        except Exception as exc:
            last = {"ok": False, "error": str(exc)}
        await asyncio.sleep(0.4)
    last["idle"] = False
    last["error"] = last.get("error") or "timeout_waiting_for_idle"
    return last


async def main_async(args: argparse.Namespace) -> int:
    if args.command == "discover":
        print(json.dumps({"ok": True, "bundle_id": await discover_bundle_id()}, separators=(",", ":")))
        return 0
    if args.command == "wait-idle":
        result = await wait_for_idle(args.timeout)
        print(json.dumps(result, separators=(",", ":")))
        return 0 if result.get("idle") else 2

    mapping = {"start": "start_record", "stop": "stop_record", "status": "status"}
    cmd = mapping[args.command]
    result = await connect_with_optional_launch(cmd, args.launch_if_needed, args.startup_timeout)
    if args.command == "stop" and args.wait_finalize and result.get("ok"):
        result["finalize"] = await wait_for_idle(args.timeout)
    print(json.dumps(result, separators=(",", ":")))
    return 0 if result.get("ok") else 2


def main() -> None:
    ap = argparse.ArgumentParser(description="Control Depth Recorder over the iPhone USB mux. No media is streamed through this channel.")
    ap.add_argument("command", choices=("start", "stop", "status", "wait-idle", "discover"))
    ap.add_argument("--launch-if-needed", action="store_true", help="Try a pymobiledevice3 DVT launch if the app control port is not available")
    ap.add_argument("--startup-timeout", type=float, default=15.0)
    ap.add_argument("--wait-finalize", action="store_true")
    ap.add_argument("--timeout", type=float, default=45.0)
    args = ap.parse_args()
    try:
        raise SystemExit(asyncio.run(main_async(args)))
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc), "utc_ns": utc_ns(), "utc_iso": utc_iso()}, separators=(",", ":")))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
