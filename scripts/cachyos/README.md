# Building Hookshot from source on CachyOS / Arch, the pinned way

`rebuild.sh` automates the "Linux, without the AppImage" route from the project's
[readme](../../readme.md#build-from-source), with the parts that matter for trust and speed done for you:

- the compiler, FFmpeg/dav1d and SDL come from **repo-signed pacman packages**, never downloaded
  (`scripts/linux/deps.sh` fetches LLVM, CPython, FFmpeg, SDL2 and the header packages **without
  SHA-256 pinning** — so nothing here uses it);
- the only downloads are Hookshot's **own release parts**, checked against the SHA-256 in Hookshot's
  own release manifest, through upstream's own `scripts/release_parts.py`;
- upstream's **game-free test suite** runs before anything is compiled;
- the build uses the release's **play profile (PGO), hot-function list and hot link order**, plus
  `-march` tuning for this CPU;
- the finished binary is **verified** (what instructions it contains, what it links, that PGO and the
  link order landed, that nothing network-facing is imported);
- **no auto-updater is installed**, and the launcher sets `HOOKSHOT_NO_UPDATE_CHECK=1`.

Why not the AppImage? It is not malware — GitHub publishes its SHA-256 — but you cannot read what is
inside 215 MB of prebuilt LLVM/Python/FFmpeg/SDL, its builder can download and run updated binaries,
and its renderer is prebuilt for generic `x86-64-v3`. Details, measurements and the audit with
file:line references are in [NOTES.md](NOTES.md).

## Fresh install

This folder is local tooling, not part of upstream, so get it from **your fork** first:

```sh
git clone https://github.com/<you>/Hookshot.git && cd Hookshot      # your fork, which has this folder
scripts/cachyos/rebuild.sh all --nup ~/Downloads/your-game.nup
```

If you would rather keep a plain upstream clone, add the remote of your fork and merge, or copy this
folder in and run the same command. To track upstream while keeping your fork's tooling:
`git remote add upstream https://github.com/NotRexed/Hookshot.git && git fetch upstream && git merge upstream/main`.

`all` checks your hardware and packages, installs what is missing (needs sudo), fetches and verifies the
pinned inputs, runs the tests, checks the dump, builds, verifies the binary and installs a launcher plus
an applications-menu entry. Expect about 10 GB of tooling state, ~60 GB during the build and ~26 GB for
the game folder (plus the shader caches the first start writes, so plan ~35 GB).

Then: `hookshot` (if `~/.local/bin` is in your PATH), the menu entry, or
`scripts/cachyos/hookshot-launch`.

## Subcommands

| Command | What it does |
|---|---|
| `preflight` | CPU (AVX2), GPU (mesh shaders, Reflex), RAM, disk, glibc, missing packages |
| `deps` | `sudo pacman -S` for what is missing; prints the command if sudo needs a password |
| `fetch cpm` | Vulkan/SPIRV headers + VMA from Hookshot's release part, SHA-256 checked |
| `fetch profile` | the release's play profile, hot-function list and hot link order into `work/` |
| `selftest` | `python -I -B tests/run_all.py` (CI's own game-free checks) |
| `rom-check [--full]` | is this the supported dump? `--full` hashes every member of the `.nup` |
| `build [--march X --jobs N --reserve-gb N]` | translate + compile (CPU only, no GPU needed) |
| `update` | rebuild the game folder with the current source: incremental, keeps saves and settings |
| `verify` | inspect the built binary (see `verify-build.sh`) |
| `install` | `~/.local/bin/hookshot`, a `.desktop` entry, and the launcher's config file |
| `show` | preflight plus the manifest of the last recorded run |

State lives in `~/.cache/hookshot-local/` (venv, pinned headers, downloads, logs, `manifest.txt`) and
`~/.cache/hookshot-builder/` (objects and lifted C, so `update` recompiles only what changed).

## Useful options

- `--reserve-gb N` — memory the build leaves free. Default 8. Raise it (e.g. 25) if you build while
  something big is running: the compile stage is memory-hungry and the kernel will otherwise OOM
  whatever is spare.
- `--jobs N` / `--lift-jobs N` — fewer parallel compilers on a busy or small machine.
- `--march x86-64-v3` — byte-level parity with what upstream ships, instead of `-march=native`.
- `--no-pgo` — skip the play profile (the game still builds, a little slower in play).
- `--strict` — stop if any of upstream's checks fails.
- `--dry-run` — print the plan, run nothing expensive.

## Three things that look wrong but are not

1. `build: this CPU has no AVX2: the game is built for native` — `build.py:452-453` prints that for
   **any** march that is not literally `x86-64-v3`, including `native`. Harmless.
2. `tests/test_make_game_cache.py` fails when a play profile is in `work/` (it blocks every subprocess
   launch, and the profile makes `make_game.py` probe the compiler). `selftest` stashes `work/` first.
3. FMA instructions in the binary are expected: the game's ARM64 code uses `FMADD`, and
   `-ffp-contract=off` only forbids contracting separate multiplies and adds. The one hard check is
   **zero AVX-512** on a CPU that has none.

Some dumps also contain a few `romfs/Tex/*.bntx.zs` members that are not zstd frames; `rom-check
--full` flags them. This dump has exactly 3, and [DUMP-DEFECT.md](DUMP-DEFECT.md) documents them
exhaustively: what the bytes are, why the damage predates the container, why nothing compiled depends
on them, and why they cannot be repaired locally. Don't re-investigate or delete them.

## Keeping the fork up to date

`.opencode/commands/hookshot-update.md` and `.opencode/agents/hookshot-maintainer.md` in the repo root
are the standing procedure, so an OpenCode session does the whole thing the same way every time:

```text
/hookshot-update            # newest stable tag
/hookshot-update v2.0.14    # a specific tag
/hookshot-check             # read-only health check, builds nothing
```

`/hookshot-update` pulls upstream, shows you the change set before merging, refreshes the pinned
headers and play profile for the new tree, runs upstream's test suite, re-checks that your game files
are still the supported version, rebuilds incrementally with the identical flags, then re-runs the
verification gates and reports before/after SHA-256 and build id. It stops and asks rather than
guessing, and it never pushes without being told to. The `hookshot-maintainer` agent holds the contract
it enforces — distro packages only, no `deps.sh`, no auto-updater, no DLSS without your say-so.

The command file is plain markdown with no magic: its body is a normal prompt, so you can paste it into
any other agent, or run the steps by hand from the list in [NOTES.md](NOTES.md) §10.

## Playing more safely (optional)

```sh
scripts/cachyos/sandbox-bwrap.sh --dry-run     # see the command
scripts/cachyos/sandbox-bwrap.sh               # read-only filesystem, no network namespace at all
```

Writable inside: the game folder, `$XDG_DATA_HOME/hookshot` (saves) and `$XDG_RUNTIME_DIR`
(Wayland/PipeWire). `/dev` and `/run/udev` stay bound, because the GPU driver needs `/dev/nvidia*` and
`/dev/dri` and pads need them; the host's resolver and system-D-Bus sockets are masked.

What that was checked to do (a stub program run inside the sandbox, on 2026-11-10):

| inside the sandbox | result |
|---|---|
| network interfaces | only `lo`, down |
| `gethostbyname("api.github.com")` | blocked (`gaierror`) |
| TCP to `140.82.114.5:443`, `8.8.8.8:53` | blocked |
| write `/etc`, `$HOME` | refused |
| write game folder, save folder | allowed |
| `LD_PRELOAD` from the calling shell | dropped |

So the update check is impossible there, not merely disabled. **Not** verified: this game running
inside it. If a sandboxed run gives you a black window, no sound or no controller, use
`hookshot-launch` — the sandbox is optional, and device access (`/dev`, `/run/udev`) is deliberately
not restricted because the pad and the GPU need it.
