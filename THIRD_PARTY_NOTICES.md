# Third-Party Notices

This project is licensed under **GPL-2.0-or-later**. The following projects materially informed or support the implementation.

## LensLink

- Repository: https://github.com/MyNamesEMurray/LensLink
- Reference commit used during development: `2cab099d56f7c23a7a9e618498af6e229a6e4192`
- License: GNU GPL v2 or later

LensLink informed the live-camera interaction model and the USB/OBS architecture. Depth Recorder uses its own capture-first RGB-D workflow and does not use LensLink's high-bandwidth master streaming path.

## U2Net human segmentation / rembg model distribution

- rembg: https://github.com/danielgatis/rembg
- U-2-Net: https://github.com/xuebinqin/U-2-Net
- Model used by the renderer: `u2net_human_seg.onnx`
- Expected SHA-256: `01EB6A29A5C4D8EDB30B56ADAD9BB3A2A0535338E480724A213E0ACFD2D1C73C`

The model weights are **not redistributed in this repository**. `tools/download-model.ps1` downloads the model from the rembg GitHub release and verifies the checksum. Review the model's upstream licensing/provenance before redistribution.

## ONNX Runtime

The renderer uses the locally installed `onnxruntime` Python package for subject-matte inference. This repository does not redistribute ONNX Runtime binaries.

## FFmpeg / Vulkan / NVIDIA NVENC

The finishing workflow invokes the user's locally installed FFmpeg. The current production renderer uses Vulkan filters and NVIDIA NVENC for HEVC output. This repository does not redistribute FFmpeg or NVIDIA binaries.
