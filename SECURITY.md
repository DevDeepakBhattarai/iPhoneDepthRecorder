# Security

## Do not publish credentials

Depth Recorder does not require Apple credentials in source code. Apple ID passwords, 2FA codes, provisioning profiles, certificates, private keys, Sideloadly state, GitHub tokens, or other credentials must never be committed or attached to issues.

## Before sharing logs

Review logs and sidecars before uploading them publicly. They may contain:

- local filesystem paths;
- device/bundle identifiers;
- precise UTC timestamps;
- OBS output filenames;
- camera metadata;
- recording names.

Never upload `.depthrec` packages unless you intentionally want to share the recorded video/audio.

## USB control model

The OBS helper communicates with the iPhone through usbmux and a small control protocol. Full-resolution video is recorded locally on the iPhone and transferred only after recording ends. The transfer helper intentionally provides no phone-side delete operation.

## Reporting a security issue

Do not open a public issue containing a secret. Reproduce the problem with credentials removed and include only the minimum diagnostic information necessary.
