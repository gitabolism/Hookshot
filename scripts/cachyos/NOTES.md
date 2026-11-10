# Hookshot — local build report

Built on this machine on 2026-11-09 and played on 2026-11-10: title screen through Kokiri Forest,
smooth, Xbox controller working. Everything here is local: the game binary was compiled from GPL
source on this PC, from your own dump. Nothing game-derived leaves this machine.

- Game: `~/Games/Hookshot` — start it with `~/Projects/Hookshot/scripts/cachyos/hookshot-launch`,
  or the "Hookshot (local build)" entry in your applications menu.
- Tooling in this folder: `rebuild.sh` (reproduces every step of this build on a fresh install),
  `verify-build.sh`, `hookshot-launch`, `sandbox-bwrap.sh`, and this report.
- Working state (venv, pinned headers, download cache, logs): `~/.cache/hookshot-local/`.
- Objects and lifted C for incremental updates: `~/.cache/hookshot-builder/`.

To do all of this again from scratch on a fresh CachyOS install (from your own fork, so this folder
is there):

```sh
git clone https://github.com/<you>/Hookshot.git && cd Hookshot
scripts/cachyos/rebuild.sh all --nup ~/Downloads/your-game.nup
```

---

## 1. Verdict on "can I just use the AppImage?"

No — rebuilding from source is the better choice for your two stated reasons, but the AppImage is
not *malicious*: GitHub publishes its SHA-256 (`5863f9dcea4f8d8e63fedd31f371706da13891e86990207e34077948e3346e01`,
215,476,728 bytes for v2.0.11), so the "Trojan" reports in the README are the usual unsigned-binary noise.

| | AppImage | This build |
|---|---|---|
| Code you execute | 215 MB prebuilt blob, unauditable | compiled here from source you can read |
| Toolchain | bundled LLVM/CPython/FFmpeg/SDL/Tk, fetched by `deps.sh` **without SHA-256 pinning** | your repo-signed clang/lld 23.1.4 + pacman libs; the only downloads were release parts checked against Hookshot's own manifest hashes |
| Updates | launcher phones `api.github.com`, can pull new binaries | none; you update with `git pull` + a rebuild |
| ISA tuning | renderer prebuilt at generic `x86-64-v3` | `-march=native` (Raptor Lake tuning) + the release's PGO profile + hot-function split + link order |

## 2. Provenance of the source you compiled

| Check | Result |
|---|---|
| Remote | `https://github.com/NotRexed/Hookshot.git` (origin only) |
| Commit built | `bbdc370` on `main` = `v2.0.11` + 156 commits (includes the post-release perf/GPU fixes) |
| Working tree before build | clean, no local edits, no stash |
| Commit signatures | GitHub's verified-commit signature (RSA `B5690EEEBB952194`) on merge commits. Caveat: GitHub's public GPG key list was removed from `api.github.com/meta`, so I could not cryptographically chain that key to a key you already trust — provenance here rests on the TLS-authenticated GitHub repo plus a reviewable GPL history. Tags are not signed. |
| Upstream's own CI gate, run on your machine | `python -I -B tests/run_all.py` → **179 passed, 5 skipped, 1 "failed"** |

The single "failure" is my doing, not upstream's: `tests/test_make_game_cache.py` blocks every
subprocess launch and trips when `work/` contains a play profile, because `make_game.py:1049`
then probes clang for profile readability. With `work/` removed the same file reports `OK`.
Upstream's CI never has `work/` in that job.

## 3. Your dump (verified, never modified)

| | |
|---|---|
| File | `~/Downloads/<your-dump>.nup` — the whole-file hash is deliberately not recorded |
| Size | 25,020,741,061 bytes |
| Container | `NUP\x01`, header size field matches the file exactly |
| `make_game.py --check` | `@@check ok This is the version Hookshot supports (build e0f3ccfa).` |
| Title | `0400486024dec000` v131072 — exefs 5 modules, romfs 186,587 files, 26.24 GB |
| `nx2/nup.py --verify` | `verified 186592 records, 159542 unique extents: 3 bad` — **no SHA-256 mismatch anywhere**; the 3 are the texture anomaly below |

### The 3 flagged files — documented in [DUMP-DEFECT.md](DUMP-DEFECT.md)

```
romfs/Tex/CmnTex_Map_Soil_FairyFountain_Floor_D_Nrm.bntx.zs   216,015 B   3 zero pages, then compressed data
romfs/Tex/RBake_Scene_GanonStage_G_2_1_d0_t0.bntx.zs        1,901,341 B   3 zero pages, same shape
romfs/Tex/Rock_WaterTemple_Gate_M_01_Nrm.bntx.zs              452,972 B   2 zero pages, same shape
```

Summary of the finding; the full analysis, the measurements and the commands to re-check any of it are
in [DUMP-DEFECT.md](DUMP-DEFECT.md):

- 3 of 186,587 romfs files. They are **94-99% intact compressed data with the head missing** — exactly 2
  or 3 pages of 4 KiB of zeros where a `.zs` member must begin with a zstd frame.
- **Not** damage to this PC: the file as downloaded is byte-identical to the working copy (`cmp`, 0 differing bytes
  over 25 GB), the container's TOC and hash tree verify clean, and all 186,592 per-member SHA-256s match.
- **Not** a Hookshot reader bug: their stored extents are valid zstd frames decoding to exactly the
  recorded length, and 1,080 of the 1,083 `.zs` members using the same container codec are fine.
- The damage is **baked into the `.nup`**: the container's own hash for each of the three matches the
  malformed bytes, so the packager hashed them as they are. Page-aligned zero blocks point at the dump.
- Nothing compiled depends on them (`Tex/` is never read by the lift or the shader census). Two of the
  three are **normal maps**, and both of those families kept their albedo and roughness members; the
  third is 1 baked-light tile out of 8 for that scene. So at worst: flat bump detail on one Fairy
  Fountain soil tile and one Water Temple gate mesh, and one wrong baked-light tile in Ganon's Castle.
- **Not repairable here**: the missing bytes are the start of a compressed stream. Only a good copy from
  a source you trust helps, and then `mods/fix/romfs/Tex/` swaps it in at run time with no rebuild
  (`host/mods.c:104` and `:168`: any folder containing `romfs/` is a mod, matched case-insensitively,
  confirmed in the log as `mods: Tex/<file> <- <path>`).

## 4. Inputs used, with their hashes

Nothing was fetched blindly. Versions match upstream's `scripts/linux/deps.sh` exactly.

| Input | Source | Verification |
|---|---|---|
| clang, lld 23.1.4 | CachyOS repo packages (`cachyos-v3`) | pacman repo signature |
| libavcodec/swscale/swresample/avutil 9.0.2 + dav1d 1.5.4 | CachyOS packages (same versions `deps.sh` builds) | pacman repo signature; linked dynamically |
| SDL3 3.4.18 (+sdl2-compat) | CachyOS packages | not linked; the game dlopens `libSDL3.so.0` at run time |
| Vulkan/SPIRV headers + VMA | `HookshotBuilder-cpm-c30c77e4cf00.zip` from the `builder-parts` release | SHA-256 `c30c77e4cf000ebf11ec82e79ace4bef3206d3698c61146f7477baa428ea7ef0` (from Hookshot's own release manifest), verified with `sha256sum -c`. Contents: `vulkanheaders/v1.4.345`, `spirv-headers/vulkan-sdk-1.4.341.0`, `vulkanmemoryallocator/v3.3.0` |
| Play-profile parts (`hot_funcs.txt`, `hot_order.txt`, `hookshot_pieces.prof`, `image/chunks.txt`) | `HookshotBuilder-app-235fea38ec3c.zip` | fetched by upstream's own `scripts/release_parts.py`, which checks size + SHA-256 `235fea38ec3ce18e091d6eec5a8265cea89a480485ca2f830ff7796e072acee3`; only these 4 data files were extracted, none of the binaries in that part were ever run |
| Python modules | PyPI, in `~/.cache/hookshot-local/venv` | `lz4==4.4.5 numpy==2.5.4 capstone==5.0.9 unicorn==2.1.4 zstandard==0.25.0` (exact versions `deps.sh` pins). Note: pip checked TLS + the index's published hashes; I did **not** use `--require-hashes`, so a compromised PyPI mirror/cache is still a trust boundary |
| NVIDIA DLSS SDK | **not fetched** — proprietary blob, needs your acceptance of NVIDIA's license | to add later: `python -I scripts/ngx_sdk.py --platform linux <dir> --accept-nvidia-license` (that script pins per-file SHA-256), then rebuild with `HOOKSHOT_NGX_SDK=<dir>` |

## 5. Supply-chain audit of the source (what I read, with file:line)

Genuinely good: no telemetry; no obfuscation or encoded blobs; **zero prebuilt binaries committed**
(`git ls-files` for `.exe/.dll/.so/.a/.o/.bin/.lib/.pyc` is empty, no git-lfs); all GitHub Actions pinned
to full commit SHAs; the DLSS fetcher pins per-file SHA-256 (`scripts/ngx_sdk.py:37-73`, `:137`);
the Linux updater verifies size + SHA-256 per part (`builder/linux/linux_update.py:337`) and blocks zip
traversal (`:293`); the Windows setup streams a SHA-256 over each download (`builder/setup/setup.c:561-585`)
and pins llvm-mingw in-repo (`scripts/make_setup_parts.py:28-30`); no `sudo`, no system paths, no
persistence; the update check is opt-out (`host/hos_update.c:82`).

Real weaknesses (why building locally is the right call):

1. `builder/HookshotBuilder/Updater.cs` — the Windows in-place updater downloads `HookshotBuilder.exe`
   and starts it with only a byte-count check (`:321`, then `:100-102`); no hash anywhere in that file.
   Windows-only, and this build has no updater at all.
2. `scripts/linux/deps.sh` — most fetches are **unhashed**: LLVM (`:65`), CPython (`:85`), dav1d (`:121`),
   FFmpeg (`:125`), SDL2 (`:139`), CPM headers (`:157`), and it *executes* the downloaded clang
   (`:78`) and `appimagetool` (`:184`, `appimage.sh:118`). Only Tcl/Tk (`:29-30`) and the AppImage runtime
   (`:39`) are SHA-256 checked. I used none of these fetches.
3. `deps.sh:88-89` pip-installs without `--require-hashes`.
4. Every updater's root of trust is a manifest fetched over TLS (TOFU): parts are hash-checked against it,
   but a tampered release asset would be trusted. Building from git + reviewing beats that.
5. One `shell=True` in the whole repo: `nx2/make_game.py:326`, running a locally discovered
   `vcvars64.bat` on Windows. Not reachable from network input; not used on Linux.

## 6. What the build actually did

```
RX_MARCH=native   --jobs 20   HOOKSHOT_MEM_RESERVE_GB=25   HOOKSHOT_LIFT_JOBS=8
HOOKSHOT_KEEP_BUILD_FILES=1   --language en-US            (en_CA locale; no en-CA in the game)
```

| Stage | Result |
|---|---|
| read | 25 GB container extracted, `check_modules` + `check_supported_build` passed |
| lift | `translated instructions: 100.0000% of 17,646,456`; 73 code files written in 84 s |
| hot split | `hot functions (A64_HOT_FUNCS): 849 of 849 listed found, in code_hot.c` → `split_hot` made 8 pieces, compiled at `-O2` **with the release's PGO profile** (`-fprofile-instr-use=`), accepted by clang 23.1.4 |
| compile | 440 files, 6m47s wall, up to 20 clangs |
| finish | `hookshot_shaders.bin` 515 MB written (all shader programs, for the first start) |
| total | **8m35s** |

The build was memory-capped on purpose (`--reserve-gb`): it left tens of gigabytes of RAM free the whole
time, so whatever else runs on the machine is never at risk of an OOM kill. Raise that reserve if you
compile alongside something large.

## 7. Post-build verification

| Check | Result |
|---|---|
| Folder | 26 GB: `hookshot` 451 MB, `hookshot_vk.so` 7.7 MB, `hookshot_shaders.bin` 515 MB, `image.bin` 101 MB, `romfs/` 25 GB, `language.txt` (en-US), `hookshot.png` |
| ELF | PIE x86-64, not stripped (debug symbols are local; strip them if you want smaller) |
| Links | `libavcodec/swscale/swresample/avutil` (distro, v3-optimized), `libm`, `libgcc_s`, `libc`. **No SDL, no Vulkan** — both dlopened at run time, as upstream intends |
| Renderer `.so` | needs only `libm`, `libc`, `ld-linux` → `-static-libstdc++`/`-static-libgcc` applied |
| glibc needed | max `GLIBC_2.43` (system has 2.44) |
| Link order | **12 of 12**: the first twelve `.text` symbols are exactly `work/hot_order.txt`'s first twelve → the release's ordering file was applied by lld |
| PGO | applied (the 8 `code_hot_*` pieces; no "cannot read the play profile" line in the log) |
| march | `-march=native` used. The log line `this CPU has no AVX2: the game is built for native` is a **false alarm in build.py:452-453**, which compares the string to `x86-64-v3` and complains for any other value — including `native` |

### Instruction census (2,000,000 instructions from the head of `.text`)

Because lld was given the release's symbol-ordering file, `.text` *starts* with the hottest
functions, so this sample is the code that decides frame rate:

```
AVX-512 (zmm) 0        AVX-512 write masks 0        <- the one hard requirement: 0 is correct
AVX/AVX2 (ymm) 1,189   SSE (xmm) 611,324            <- the lifted code is mostly scalar
beyond x86-64-v3: AVX-VNNI 0  GFNI 0  VAES 0  VPCLMULQDQ 0  MOVDIR 0
FMA 41                                             <- correct, see below
```

Honest reading of this, since you asked about hardware optimization:

- **No AVX-512**, which matters: a 13900KS has none, so `-march=native` could not have produced an
  unrunnable binary. Confirmed safe.
- **No beyond-`x86-64-v3` instruction was actually emitted.** So in this build the *instruction set*
  ends up the same level the AppImage's renderer is built at; what `-march=native` adds is Raptor Lake
  scheduling/`-mtune` decisions. The measurable wins in this build are PGO, the hot-function split,
  the link order and post-v2.0.11 code — not new ISA instructions. If you prefer byte-level parity
  with upstream, `RX_MARCH=x86-64-v3` and rebuild; you lose tuning, nothing else.
- **FMA instructions are expected and correct.** `-ffp-contract=off` only forbids *contracting* a
  separate multiply and add; the game's own ARM64 code uses `FMADD`/`FMSUB`, and the lift translates
  those to native FMA. My first pass flagged the 41 FMAs as a violation — that check was wrong, and
  `verify.sh` now says so explicitly.
| Network imports | no `socket`/`connect`/`getaddrinfo`/curl symbols imported; the only net-facing code is the update check, which shells out to `curl` (`host/hos_update.c:218-220`) — disabled by the launcher and impossible inside the sandbox |
| Build files kept | `~/.cache/hookshot-builder` 2.7 GB → updates recompile only what changed |

## 8. Running it

```sh
~/Projects/Hookshot/scripts/cachyos/hookshot-launch             # play
~/Projects/Hookshot/scripts/cachyos/hookshot-launch --prepare   # only pre-translate shaders (needs free VRAM)
bash ~/Projects/Hookshot/scripts/cachyos/sandbox-bwrap.sh       # optional: read-only FS + no network at all
```

- First start translates every shader (`hookshot_shaders.bin`) — expect a pause, then faster starts.
- Settings: `~/Games/Hookshot/hookshot_options.ini`; log: `~/Games/Hookshot/hookshot_log.txt`;
  saves: `~/.local/share/hookshot`.
- The sandbox's isolation **was** verified on this machine (2026-11-10) by running a stub program inside
  it: only `lo` up, `api.github.com` does not resolve, TCP to 443/53 blocked, `/etc` and `$HOME`
  read-only, game and save folders writable, inherited `LD_PRELOAD` dropped. What was **not** verified
  is this game running inside it (that needs your GPU and session). Two bugs came out of that test and
  are fixed: `--tmpfs /tmp` was ordered so it hid a game folder under `/tmp`, and the host's
  systemd-resolved and system-D-Bus sockets were reachable through the read-only bind (a read-only mount
  does not stop `connect()` to a unix socket), so DNS still worked. `/dev` and `/run/udev` stay bound
  because the NVIDIA driver and the controller need them. If a sandboxed run gives a black window or no
  sound, use the plain launcher.

### Suggested settings for your hardware (in-game menu, Insert/F1)

24 GB VRAM, 2560x1440 primary monitor (`DP-1`), plus a 3440x1440 (`DP-3`) and a portrait 1440x2560:

- Quality preset **Ultra (16GB+)**, then set back to Custom if you change rows.
- **Output resolution 2560x1440** → the window scaling filter then reports "Not needed (window = output)",
  which is the sharpest path (`HOS_OUTPUT_RES=1` for one run).
- **Robust buffers: Off** after a restart — upstream notes it can be faster on some NVIDIA cards.
- **NVIDIA Reflex: On + Boost** — your driver exposes `VK_NV_low_latency2`.
- **Frame generation**: try 2x only if you can't hold 60 fps; it adds input latency.
- Stutter on first visit to an area is expected (shader translation) and disappears on revisit.
- If you see blocky/dark artifacts (an AMD workaround, sometimes useful elsewhere):
  `RX_VK_ASTC_RGBA8=1` in `hookshot_env.txt`, at a big VRAM cost.

### Optional experiments I did **not** apply (unmeasured, so not defaults)

The build uses upstream's own tuning. Two knobs are worth A/B-ing **when the GPU is free**, with
MangoHud (`mangohud ~/Projects/Hookshot/scripts/cachyos/hookshot-launch`) and the menu's FPS counter,
because I could not measure anything here:

1. **Bulk optimization level.** Upstream compiles the ~430 non-hot game files at `-O1` (compile-time
   driven) and only the hot pieces at `-O2`+PGO. `-O2` for the bulk may help or hurt; there is no env
   hook for it, so it means calling the compiler stage directly in the same work folder
   (`python -I nx2/build.py --standalone --jobs 20 --opt O2`) and then re-running
   `make_game.py --update ~/Games/Hookshot` to re-stage the folder.
2. **Hot-piece level:** `RX_HOT_OPT=O3` (still with the profile) instead of the default `O2`.

Any `RX_*` change re-keys both the lift and the object cache (`make_game.py:835`, `build.py:477-495`),
so a changed setting means a full ~9-minute rebuild — never a stale mix of objects.


## 9. The first run (by hand on 2026-11-10, once the GPU was free)

Played from the title screen through Kokiri Forest. From `hookshot_log.txt`:

```
[hos host] hookshot v2.0.11-156-gbbdc370 (source 78baa41a)
vk: NVIDIA GeForce RTX 4090, Vulkan 1.4, ...; mesh shaders yes, host memory import yes, pipeline libraries yes
vk: 45240 presents, 60.0 fps; a frame: 284 draws (0 skipped), 139 passes, 77 barriers, 6 submits,
    GPU-bound wait 0.0 ms; 1149 pipelines, 76 programs (0 failed), 1719 textures (3820 MB)
```

- **60.0 fps steady** (45,240 frames, about 12.5 minutes), 0 draws skipped, **0 failed shader
  programs**, 0.0 ms GPU-bound wait, 3.8 GB of textures on a 24 GB card.
- No errors, no asserts, no device lost. The log's 377 "failed" hits are all the `(N failed)` counter
  field of that stats line, which reads `0 failed`.
- Xbox controller worked. (HD rumble is the Switch-pad path: it needs a Switch Pro/Joy-Con plus SDL3
  and hidraw permission, so an Xbox pad gets the plain two-motor rumble.)
- The three malformed `Tex/*.zs` members were never asked for: nothing in Kokiri Forest touches them.
- The first start translated every shader and left caches in the game folder, which is why it is now
  33 GB rather than 26: `hookshot_programs.bin` 6.9 GB, `mkw_vk_pipelines.bin` 553 MB. Those caches
  are why later starts are quick; deleting them is safe (they are rebuilt, slowly).

Still not done on purpose: DLSS is not enabled (proprietary blob, needs your acceptance of NVIDIA's
license), and `--prepare-shaders` was never run separately - the first start did it.

### Upstream has moved on

This build is `bbdc370` = `v2.0.11` + 156 commits. While it was building, upstream shipped further
stable releases - `v2.0.14` on 2026-11-10 - and `main` moved hundreds of commits. To move with it:

```sh
cd ~/Projects/Hookshot && git pull            # or: git checkout v2.0.14 for upstream's tested release
scripts/cachyos/rebuild.sh update             # incremental: keeps saves, settings and caches
```

`work/` currently holds the **v2.0.14** play profile while the installed binary was built against
`bbdc370`. That is harmless (clang ignores profile entries it cannot match, and upstream's own CI feeds
the previous release's profile into a newer tree), but running `fetch profile` + `update` makes source
and profile agree again.

## 10. Updating safely (no auto-updater)

The boring version of all of this is one OpenCode command, and it is the one to use after every pull so
the optimisation below is never lost: `/hookshot-update` (procedure in
`.opencode/commands/hookshot-update.md`, contract in `.opencode/agents/hookshot-maintainer.md`).
By hand, it is:

```sh
cd ~/Projects/Hookshot
git pull                                  # review it first if you like: git log --oneline <old>..HEAD
scripts/cachyos/rebuild.sh fetch cpm      # pinned headers for the new tree
scripts/cachyos/rebuild.sh fetch profile  # play profile matching the new tree
scripts/cachyos/rebuild.sh selftest --strict
scripts/cachyos/rebuild.sh update         # incremental: compiles only what changed, keeps your saves
scripts/cachyos/rebuild.sh verify
```

`update` is `nx2/make_game.py --update`, run with the same pinned headers, the same `-march` and the
same resource caps as the build, so an update can never mix objects compiled with different flags
(every `RX_*`/`OOT_*`/`A64_*` variable is part of the lift key and of the object-cache key:
`make_game.py:835`, `build.py:477-495`). An update keeps saves, `hookshot_options.ini`,
`hookshot_env.txt` and `mods`. Back saves up first anyway: `cp -a ~/.local/share/hookshot <somewhere>`.

To pin the release instead of `main`: `git checkout v2.0.11`, then `rebuild.sh build` (your dump's
build id `e0f3ccfa` is supported by both; that is what upstream ships in its releases).

## 11. Files

| Path | What |
|---|---|
| `~/Games/Hookshot/` | the game (26 GB). Delete to uninstall |
| `~/Projects/Hookshot/scripts/cachyos/` | `rebuild.sh`, `verify-build.sh`, `hookshot-launch`, `sandbox-bwrap.sh`, `README.md`, `NOTES.md`, `DUMP-DEFECT.md` |
| `~/Projects/Hookshot/.opencode/` | `/hookshot-update` and `/hookshot-check` commands, and the `hookshot-maintainer` agent that carries the build contract |
| `~/.cache/hookshot-local/` | this tooling's state: `venv/`, pinned `cpm/`, downloaded parts in `dl/`, build logs, `manifest.txt` |
| `~/.cache/hookshot-builder/` | objects + lifted C (2.7 GB) for incremental updates; delete any time (a rebuild then does everything again) |
| `~/.local/share/hookshot/` | saves, caches, options |
| `~/.config/hookshot/local-build.conf` | which game folder the launcher and the sandbox use |
| `~/.local/bin/hookshot` | symlink to the launcher |
| `~/.local/share/applications/hookshot-local.desktop` | menu entry |
| `<repo>/work/` | the release's play profile and hot lists (upstream's `.gitignore` keeps it out of git) |

To remove everything: the game folder, this `scripts/cachyos/` folder, the two cache folders, the saves,
the config file, the `~/.local/bin/hookshot` symlink and the `.desktop` file.
