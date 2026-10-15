# Recording binary format v1

All integer fields in `depth.bin` are little-endian. Depth payload values are IEEE 754 binary16 (`Float16`) values in meters.

## File header (16 bytes)

| Field | Type | Value |
|---|---:|---|
| magic | char[8] | `DRDEPTH1` |
| version | uint32 | `1` |
| endian marker | uint32 | `0x01020304` |

## Per-frame header (68 bytes)

| Field | Type | Meaning |
|---|---:|---|
| magic | char[4] | `DPT1` |
| headerSize | uint32 | `68` |
| captureIndex | uint64 | monotonically increasing synchronized callback index |
| videoPTSValue | int64 | Core Media video PTS value |
| videoPTSTimescale | int32 | Core Media video PTS timescale |
| depthPTSValue | int64 | synchronized depth timestamp value |
| depthPTSTimescale | int32 | synchronized depth timestamp timescale |
| utcNanoseconds | int64 | Unix UTC nanoseconds mapped from capture clock |
| width | uint32 | depth-map width |
| height | uint32 | depth-map height |
| bytesPerRow | uint32 | packed row bytes (`width * 2` in v1) |
| pixelFormat | uint32 | Core Video pixel-format FourCC numeric value |
| payloadBytes | uint32 | payload size immediately following this header |

The payload is `width * height` Float16 metric depth samples with no row padding.

## `frames.jsonl`

One JSON record is written for every synchronized RGB callback, including callbacks where depth was dropped. Important fields include:

- `capture_index`
- `video_index`
- video and depth PTS value/timescale pairs
- exact `utc_ns`
- `video_appended`, `video_dropped`, `depth_dropped`
- byte offset/size and dimensions of the corresponding depth record

This file makes rare missing depth samples explicit; the desktop renderer fills them by interpolation between neighboring valid LiDAR frames.

## Focus metadata

At recording start the selected tap-to-focus point is copied into `manifest.json`:

- `focus_point_x`
- `focus_point_y`
- `focus_point_space = "AVCaptureDevice normalized point of interest"`

v1 intentionally freezes the computational focus target for a take. Mid-recording focus changes are disabled until timed rack-focus events are implemented.

## Orientation metadata

The raw RGB sample buffers and `depth.bin` remain in native sensor coordinates. `manifest.json` records:

- `capture_interface_orientation` (`portrait`, `portraitUpsideDown`, `landscapeLeft`, or `landscapeRight`)
- `raw_sensor_orientation = "landscapeRight"`

`master.mov` receives the corresponding AVAssetWriter display transform for normal playback. Offline depth renderers use `-noautorotate` so RGB and LiDAR stay registered, then rotate the completed render at the end.

## UTC and SMPTE timecode

`utcNanoseconds` is the authoritative absolute timestamp. SMPTE/QuickTime timecode is a compatibility representation derived from first-frame UTC and frame rate, not a replacement for nanosecond UTC.

`tools/stamp_timecode.py` can create a stream-copied MOV with a standard QuickTime `tmcd` track. `tools/render_natural_dof.py` stamps the same UTC-derived timecode into the current natural cinematic renders automatically.

## Camera-control metadata

Build 6 snapshots the live camera state into `manifest.json` at recording start. Fields include:

- `control_iso`, `control_iso_min`, `control_iso_max`
- `control_shutter_seconds`, `control_shutter_min_seconds`, `control_shutter_max_seconds`
- `control_exposure_bias` and its min/max range
- `control_exposure_manual`
- `control_focus_position`, `control_focus_manual`
- `control_ae_af_wb_locked` - true when the take starts after the press-and-hold composite lock has settled
- `control_white_balance_temperature`, `control_white_balance_tint`, `control_white_balance_locked`
- `control_zoom`, `control_zoom_max`
- `control_torch_available`, `control_torch_level`
- `record_audio_enabled`

These are take-start values. If timed rack-focus or exposure automation is added later, those changes should be recorded as a separate timestamped event stream rather than silently changing this snapshot.

## OBS synchronization sidecars

OBS-controlled local copies can additionally contain `obs_sync.json`. It is not required for decoding the RGB-D package. It records the OBS STARTING/STARTED/STOPPING/STOPPED UTC anchors, the OBS output path, the phone first-frame UTC, and the exact phone-minus-OBS start offset.

`tools/sync_report.py` turns those anchors into `alignment.json` for editor/post scripts.
