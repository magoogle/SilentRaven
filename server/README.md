# SilentRaven server-side bits

This folder is the source-of-truth for SilentRaven's hooks into the
`looter-d4share` FastAPI service. The looter-d4share project itself is
**not currently under source control on the docker host**, so without
this folder the SilentRaven additions only exist on a single host's
disk + inside its built docker image. Stash here = reproducible deploy
from a clone of this repo.

## What's here

| File | Purpose |
|---|---|
| `silentraven_export.py` | Drop-in module for `looter-d4share/app/`. Reads `BountyMetaCache` + `Whisper Cache` rows from the catalog DB, classifies each by slot (helms, rings, gold, …) and legendary flag, writes `/data/silentraven/caches.lua` atomically. |
| `apply_patches.py` | Idempotent patcher. Adds (a) `from silentraven_export import generate_silentraven_caches` near the top of `pipeline.py`, (b) `generate_silentraven_caches(log_fn)` immediately after the existing `generate_alfred_unique_items(log_fn)` call, (c) `GET /d4/silentraven/{filename}` route appended to `api.py`. Re-runnable: detects "already patched" and no-ops. |
| `deploy.sh` | Operator one-shot wrapper: `cp` the module, `apply_patches.py`, `docker compose up -d --build`, wait for `/health`, run the generator standalone, smoke-test. Idempotent end-to-end. |
| `patches/` | Reserved for hand-rolled `*.diff` snapshots if anyone wants to inspect or apply via `patch -p0`. Empty by default — `apply_patches.py` does the same job more reliably. |

## Schema produced (`/data/silentraven/caches.lua`)

```lua
return {
    [1087411] = { slot='helms', legendary=false, name='Collection of Helms',
                  item_type='BountyMetaCache', magic_type=0 },
    [1092131] = { slot='helms', legendary=true,  name='Greater Collection of Helms',
                  item_type='BountyMetaCache', magic_type=0 },
    [2102725] = { slot='gold',  legendary=true,  name='Material Collection of Gold',
                  item_type='Whisper Cache',    magic_type=3 },
    -- ...
}
```

`item_type` and `magic_type` are passthroughs from the LooteerV3 catalog
schema, kept for client-side diagnostics. SilentRaven's `core/rewards.lua`
only consumes `slot` + `legendary` + `name`.

## Deploy

On the docker host, as a user with docker permissions:

```bash
git clone https://github.com/magoogle/SilentRaven.git
cd SilentRaven/server
./deploy.sh
```

That's it. Defaults assume the canonical d4data host layout:
```
PROJECT_DIR=/opt/looter-d4share
CONTAINER=looter-d4share
API_BASE=http://127.0.0.1:8002
```
Override via env vars if your layout differs:
```bash
PROJECT_DIR=/srv/looter ./deploy.sh
```

## Re-running

The whole pipeline is idempotent. Use cases:
- **Server code changed, redeploy**: `./deploy.sh`. Rebuild picks up the change, generator re-runs, endpoint serves the new file.
- **Catalog DB updated, force a fresh emit without rebuilding**: `docker exec -e PYTHONPATH=/app looter-d4share python -c 'from silentraven_export import generate_silentraven_caches; generate_silentraven_caches()'`
- **Verify nothing has drifted**: SHA-compare. The committed `silentraven_export.py` should match `/opt/looter-d4share/app/silentraven_export.py` byte-for-byte after a deploy.

## What this does NOT cover

- **looter-d4share project itself is not source-controlled.** This folder versions the SilentRaven additions only. If `/opt/looter-d4share` is wiped, you still need to recover the upstream looter project from wherever you originally got it. Convert the project to a git repo and push to a private GitHub for a complete fix — that's a separate task tracked in this repo's roadmap.
- **Secrets** (`.env`, `LOOTER_API_KEY`, `LOOTER_GITHUB_TOKEN`). Those live in `/opt/looter-d4share/.env` on the host and are not duplicated here. Keep them out of any future looter-d4share repo via `.gitignore`.

## Verifying after deploy

Public URL should serve the file:
```
curl -fsS https://looter.d4data.live/d4/silentraven/caches.lua | head -10
```

You should see the autogen header + 70+ entries. The next nightly
pipeline run at 02:00 UTC will refresh it, but `deploy.sh` step 5
already triggers an immediate generation so users don't wait.
