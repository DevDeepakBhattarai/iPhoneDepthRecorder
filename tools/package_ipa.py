from __future__ import annotations
import os
import pathlib
import sys
import zipfile

if len(sys.argv) != 3:
    raise SystemExit("usage: package_ipa.py <App.app> <output.ipa>")
app = pathlib.Path(sys.argv[1]).resolve()
out = pathlib.Path(sys.argv[2]).resolve()
if not app.is_dir() or app.suffix != ".app":
    raise SystemExit(f"not an .app directory: {app}")
out.unlink(missing_ok=True)
with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    for path in sorted(app.rglob("*")):
        if path.is_dir():
            continue
        rel = path.relative_to(app)
        arcname = pathlib.PurePosixPath("Payload") / app.name / pathlib.PurePosixPath(*rel.parts)
        zf.write(path, arcname.as_posix())
print(out)
with zipfile.ZipFile(out, "r") as zf:
    bad = [n for n in zf.namelist() if "\\" in n]
    if bad:
        raise SystemExit(f"invalid IPA path separators: {bad[:3]}")
    expected = f"Payload/{app.name}/Info.plist"
    if expected not in zf.namelist():
        raise SystemExit(f"missing {expected}")
