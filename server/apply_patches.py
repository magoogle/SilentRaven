#!/usr/bin/env python3
"""
apply_patches.py — Idempotent patcher for the looter-d4share server.

Adds the SilentRaven hooks to an upstream looter-d4share project:
  * pipeline.py: import silentraven_export + call its generator after
                 the alfred unique-item generator on every pipeline run
  * api.py    : new GET /d4/silentraven/{filename} route mirroring
                 the alfred handler

Idempotent by design: each edit is gated on whether the addition is
already present, so re-running this on an already-patched checkout is
a no-op.  Safe to run from `deploy.sh` on every container rebuild.

Usage:
    python3 apply_patches.py [/path/to/looter-d4share/app]

When called with no args, defaults to /opt/looter-d4share/app -- the
canonical location on the d4data host.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


# ---- patch fragments ------------------------------------------------------

PIPELINE_IMPORT = "from silentraven_export import generate_silentraven_caches"
PIPELINE_CALL_ANCHOR    = "generate_alfred_unique_items(log_fn)"
PIPELINE_CALL_ADDITION  = "generate_silentraven_caches(log_fn)"

API_ROUTE_MARKER = '/d4/silentraven/'
API_ROUTE_BLOCK = '''

# -- SilentRaven data files --------------------------------------------------

@router.get("/d4/silentraven/{filename}")
def get_silentraven_file(filename: str):
    """Serve SilentRaven cache catalog (caches.lua).

    Mirrors the alfred handler. Lua source -> text/plain."""
    if "/" in filename or "\\\\" in filename or ".." in filename:
        raise HTTPException(status_code=400, detail="Invalid filename")
    path = os.path.join(DATA_DIR, "silentraven", filename)
    if not os.path.exists(path):
        raise HTTPException(
            status_code=404,
            detail=f"SilentRaven file not found: {filename}",
        )
    return FileResponse(
        path,
        media_type="text/plain; charset=utf-8",
        filename=filename,
    )
'''


def patch_pipeline(path: Path) -> str:
    """Returns 'added' / 'already present' / raises on missing anchor."""
    src = path.read_text()
    changed = False

    if PIPELINE_IMPORT not in src:
        # Insert the import right before the `logger = logging.getLogger`
        # line at the top of pipeline.py.  Stable anchor across versions.
        new_src, n = re.subn(
            r"(\nlogger = logging\.getLogger)",
            f"\n{PIPELINE_IMPORT}\\1",
            src,
            count=1,
        )
        if n == 0:
            raise RuntimeError(
                f"Couldn't find `logger = logging.getLogger` anchor in {path}"
            )
        src = new_src
        changed = True

    if PIPELINE_CALL_ADDITION not in src:
        if PIPELINE_CALL_ANCHOR not in src:
            raise RuntimeError(
                f"Couldn't find `{PIPELINE_CALL_ANCHOR}` anchor in {path}"
            )
        # Add the new call on the line right after the alfred call,
        # matching the alfred call's indentation (12 spaces in the
        # current upstream).
        src = src.replace(
            PIPELINE_CALL_ANCHOR,
            PIPELINE_CALL_ANCHOR + "\n            " + PIPELINE_CALL_ADDITION,
            1,
        )
        changed = True

    if changed:
        path.write_text(src)
        return "added"
    return "already present"


def patch_api(path: Path) -> str:
    """Returns 'added' or 'already present'."""
    src = path.read_text()
    if API_ROUTE_MARKER in src:
        return "already present"
    if not src.endswith("\n"):
        src += "\n"
    path.write_text(src + API_ROUTE_BLOCK)
    return "added"


def main() -> int:
    app_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/opt/looter-d4share/app")
    if not app_dir.is_dir():
        print(f"ERROR: {app_dir} is not a directory", file=sys.stderr)
        return 1

    pipeline_py = app_dir / "pipeline.py"
    api_py      = app_dir / "api.py"
    export_py   = app_dir / "silentraven_export.py"

    for required in (pipeline_py, api_py):
        if not required.exists():
            print(f"ERROR: required file missing: {required}", file=sys.stderr)
            return 1

    if not export_py.exists():
        print(
            f"NOTE: {export_py} not found.  Copy "
            "server/silentraven_export.py into place before patching, OR "
            "let deploy.sh handle the copy + patch + rebuild together.",
            file=sys.stderr,
        )

    pipe_status = patch_pipeline(pipeline_py)
    api_status  = patch_api(api_py)

    print(f"pipeline.py: {pipe_status}")
    print(f"api.py     : {api_status}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
