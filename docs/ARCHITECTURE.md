# Architecture

Depth Recorder is a capture-first RGB-D workflow designed around reliable local recording and deterministic post synchronization.

## Components

### iPhone application

The native Objective-C/UIKit application uses AVFoundation to manage capture devices, manual camera controls, optional audio, and a local recording package. On the main 26 mm rear mode, video and LiDAR depth are synchronized with `AVCaptureDataOutputSynchronizer`. On the physical 13 mm ultra-wide and 65 mm telephoto modes, the session switches to a video-only callback and marks depth as unavailable.

The app exposes a small command server used by the Windows helper through Apple's usbmux transport. Commands are control-plane only: start, stop, and status.

### Recording package

`master.mov` remains a clean source. LiDAR data is stored independently as Float16 metric depth with frame metadata and camera calibration. UTC is mapped from the capture synchronization clock, preserving monotonic frame timing while providing an absolute timeline.

### OBS integration

OBS frontend callbacks provide monotonic nanosecond timestamps at Recording Starting/Started/Stopping/Stopped. A detached helper maps those values to UTC, controls the phone, and records a session sidecar. The OBS UI thread is not used for media transfer or rendering.

### USB transfer

After the phone writer reports idle, `pymobiledevice3` discovers the installed application (including alternate bundle IDs produced by sideloaders) and uses House Arrest to copy the recording package. The transfer is non-destructive and collision-safe.

### Post renderer

The natural renderer keeps RGB and depth in raw sensor coordinates during processing. It combines:

- temporally filtered metric LiDAR depth;
- U2Net human segmentation;
- optical-flow temporal stabilization;
- RGB-guided edge refinement;
- bidirectional foreground/background depth-of-field layers.

The matte protects the subject boundary; it does not replace LiDAR as the geometry source. Final display orientation is applied only after RGB/depth compositing.

## Timing model

Phone frame timing and OBS event timing each use a monotonic clock mapped to Unix UTC using narrow clock/wall-clock brackets. The post workflow aligns first phone-frame UTC against the OBS recording anchor. Control-message latency therefore does not need to be frame-perfect.

## Why the master is not streamed through OBS

The project deliberately separates **recording quality** from **monitoring/control latency**. The phone can record its best local master without 4K USB/network transport buffering, while OBS only needs lightweight control messages. The finished take is transferred after stop and aligned deterministically by UTC.
