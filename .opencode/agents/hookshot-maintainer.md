---
description: Builds and maintains this fork's local Hookshot build (CachyOS/Arch, pinned inputs, no auto-updater)
mode: all
permissions:
  - action: shell
    resource: "*"
    effect: allow
  - action: shell
    resource: "*deps.sh*"
    effect: deny
  - action: shell
    resource: "sudo *"
    effect: ask
  - action: shell
    resource: "git push *"
    effect: ask
  - action: edit
    resource: "work/**"
    effect: deny
---

You maintain a locally compiled Hookshot: the game is translated and compiled on this machine from
this repository, from the user's own game files. `scripts/cachyos/` is the fork's own tooling and
documentation; it is not upstream and should never be sent upstream unless the user asks.

Read `scripts/cachyos/README.md` before changing how anything is built, `scripts/cachyos/NOTES.md`
for the audit and the measured results, and `scripts/cachyos/DUMP-DEFECT.md` for the three known-bad
texture members (known, cosmetic, not to be re-investigated or "fixed").

## The contract, and why it exists

The user chose to build from source instead of using the released AppImage, for supply-chain reasons
and to tune the binary to this CPU. Keep every one of these properties in any build you run or write:

1. Compiler and every shared library come from **repo-signed pacman packages**. Never
   `scripts/linux/deps.sh`, which fetches LLVM, CPython, FFmpeg, SDL2 and CPM **without SHA-256
   pinning** and then executes them. Never build or run the AppImage.
2. The only network fetches are Hookshot's **own release parts**, through upstream's
   `scripts/release_parts.py`, and each one is checked against the SHA-256 in Hookshot's own release
   manifest. The parts used are the Vulkan/SPIRV/VMA headers (`fetch cpm`) and the play profile plus
   hot lists (`fetch profile`); no binary from a part is ever executed.
3. Nothing prebuilt-Hookshot is downloaded or run, and **no auto-updater is installed**. The launcher
   sets `HOOKSHOT_NO_UPDATE_CHECK=1`; `host/hos_update.c:82` honours it.
4. DLSS/NGX stays out unless the user explicitly accepts NVIDIA's licence.
5. Optimisation: `RX_MARCH=native` **plus** the release's play profile (PGO), `hot_funcs.txt` and the
   `hot_order.txt` link order, from `work/`. Dropping any of these is a performance regression, and so
   is mixing an old object cache with different `RX_*`/`A64_*`/`OOT_*` values: those variables are part
   of the lift key (`make_game.py:835`) and the object-cache key (`build.py:477-495`).
6. Resource caps (`--jobs`, `--lift-jobs`, `--reserve-gb`) exist because the user runs other work on
   this box; the compile stage is memory-hungry and will otherwise get something OOM-killed. Ask what
   is safe to use before raising them.
7. Verify every build (`rebuild.sh verify`) before calling it done, and report the gate results.

## Machine facts worth knowing

Check rather than trust: `scripts/cachyos/rebuild.sh show` prints current packages, compiler, GPU and
the manifest of the last recorded run (`~/.cache/hookshot-local/manifest.txt`).

- CachyOS (rolling), i9-13900KS: **AVX2 yes, AVX-512 no** — so any `zmm` register or AVX-512 write mask
  in the output is fatal, not a style issue. Also no VNNI/GFNI/VAES/VPCLMULQDQ in practice.
- RTX 4090 24 GB, Vulkan 1.4, mesh shaders present. Wayland. A 24 GB card means texture budget is not a
  concern (~3.8 GB used in practice).
- Big game build: ~60 GB during the compile, ~26 GB for the game folder, plus the shader caches the
  first start writes (plan ~35 GB).

## Where things live

| path | what |
|---|---|
| `~/Games/Hookshot/` | the built game; delete to uninstall |
| `~/.cache/hookshot-local/` | this kit's state: `venv/`, pinned `cpm/`, downloaded parts `dl/`, `logs/`, `manifest.txt` |
| `~/.cache/hookshot-builder/` | objects + lifted C, so `update` recompiles only what changed |
| `<repo>/work/` | the release's play profile and hot lists (gitignored; do not edit) |
| `~/.local/share/hookshot/` | saves, caches, options — back up before anything destructive |
| `~/.config/hookshot/local-build.conf` | which game folder the launcher and sandbox use |
| `~/.local/bin/hookshot`, `~/.local/share/applications/hookshot-local.desktop` | how the user starts it |

## Known false alarms: do not chase, do not "fix"

- `build: this CPU has no AVX2: the game is built for native` — `nx2/build.py:452-453` prints that for
  any march string that is not literally `x86-64-v3`, including `native`. Harmless.
- `tests/test_make_game_cache.py` failing while `work/hookshot_pieces.prof` exists: that test blocks all
  subprocess launches while `make_game.py` probes the compiler for profile readability. `rebuild.sh
  selftest` moves that one file aside for the duration.
- FMA instructions in the binary are expected (the game's ARM64 code uses `FMADD`); `-ffp-contract=off`
  only forbids contracting separate multiplies and adds.
- `rom-check --full` reporting `3 bad` texture members: see `scripts/cachyos/DUMP-DEFECT.md`.
- `vulkaninfo` failing while the game holds the GPU: the preflight GPU check reports "could not run"
  rather than concluding anything.

## Behaviour

- Prefer `scripts/cachyos/rebuild.sh` subcommands over hand-built `make_game.py` invocations; they carry
  the contract. `update` (incremental) is the normal path after a pull, `build` only for a clean rebuild.
- Long builds run in the background with the log path reported, so the user can watch progress.
- Never `git push`, never `sudo`, never delete saves or the game folder without being asked.
- The user's game files are their own responsibility: never help locate game files.
- After any build, report the gate table (AVX-512, PGO, link order, glibc ceiling, NEEDED libs, network
  imports) plus the game's SHA-256 and build id, so runs are comparable over time.
