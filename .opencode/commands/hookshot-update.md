---
description: Pull upstream Hookshot into this fork, then rebuild and verify with the CachyOS pinned-toolchain contract intact
agent: hookshot-maintainer
---

Bring this fork up to date with upstream Hookshot and rebuild the game so the local CachyOS build
contract (pinned inputs, `-march=native`, release PGO + hot lists, resource caps, no auto-updater)
survives the move. Target: **$ARGUMENTS** (empty means: newest upstream stable tag).

Work through the steps in order. Stop and report instead of continuing whenever a STOP condition is
written. Never skip a verification step because a previous run passed: after a pull, everything
downstream of the source change is new.

## 0. Where things stand

!`git remote -v; echo; git rev-parse --abbrev-ref HEAD; git rev-parse --short HEAD; echo "dirty files: $(git status --porcelain | wc -l)"; echo; tail -12 ~/.cache/hookshot-local/manifest.txt 2>/dev/null`

Save the old `commit=` and `game_sha256=` values from that manifest: the report at the end compares
them against the new ones.

## 1. Remote reality check

- Upstream is `https://github.com/NotRexed/Hookshot`. If it is reachable as `origin` and there is no
  fork remote, this clone has no fork yet: say so, do the fetch under `origin`, and do **not** push.
- If both exist, fetch both: `git fetch --tags --prune upstream && git fetch --prune origin`.
- If the working tree is dirty, show `git status --short` and ask before stashing: the user may have
  work in progress.

## 2. Decide what to move to, and show what is coming

- With no argument, prefer the **newest stable tag** (`git tag -l 'v*' --sort=-v:refname | head -5`)
  over moving-tip `main`: tags are what upstream ships and tests.
- Show the change set before merging anything: `git log --oneline HEAD..<ref> | head -40`, the count
  `git rev-list --count HEAD..<ref>`, and the changelog delta `git diff HEAD..<ref> -- changelog.txt`.
- Call out anything that touches the local contract, by diffing these paths specifically:
  `nx2/build.py nx2/make_game.py nx2/lift*.py scripts/release_parts.py scripts/linux/ host/mods.c
  host/hos_update.c tests/run_all.py`. New `RX_*`/`A64_*`/`OOT_*` environment variables, changed
  compile flags, or a changed profile format all mean the local kit needs a matching update.
- **STOP and ask** if the fork has commits that touch upstream files (not `scripts/cachyos/` or
  `.opencode/`): those need a rebase decision from the user, not a merge by you.

## 3. Merge

- `git merge --ff-only <ref>` when `main` is strictly behind (normal case for this fork).
- Otherwise `git merge <ref>` and resolve, keeping `scripts/cachyos/` and `.opencode/` intact.
- Do not push yet. Pushing happens in step 9, on the user's word.

## 4. Refresh the pinned inputs for the new tree

```sh
scripts/cachyos/rebuild.sh fetch cpm        # Vulkan/SPIRV/VMA headers, SHA-256 checked
scripts/cachyos/rebuild.sh fetch profile    # the release's play profile + hot lists into work/
```

`fetch profile` must run after the merge: `work/hookshot_pieces.prof` belongs to a release, and you
want it to match the tree being compiled rather than lag behind it. Note in the report which release
tag the parts list came from.

## 5. Upstream's own gate

```sh
scripts/cachyos/rebuild.sh selftest --strict
```

`test_make_game_cache.py` reports a false failure while a play profile sits in `work/`, and the command
already moves that one file aside; if it still fails, read the actual test output rather than assuming
the known cause. **STOP on any other failure**: report the failing test, its message, and whether it
looks related to the update. Do not build on top of a failing suite unless the user accepts it.

## 6. Is the game data still supported

```sh
scripts/cachyos/rebuild.sh rom-check --nup <the .nup path from the manifest or from the user>
```

Expect `@@check ok This is the version Hookshot supports (build …)`. **STOP if it fails**: newer
Hookshot can require a newer game version, and the fix is the user's own game files, not anything you
can download. The known `3 bad` texture members in `--full` are documented in
`scripts/cachyos/DUMP-DEFECT.md` — same three hashes means no regression, and it is not worth
re-investigating.

## 7. Rebuild, with the local optimisation preserved verbatim

```sh
scripts/cachyos/rebuild.sh update      # incremental: nx2/make_game.py --update
```

Use `build` instead of `update` only if the user wants a from-scratch compile. Notes for this step:

- `update` keeps saves, `hookshot_options.ini`, `hookshot_env.txt` and `mods`, and recompiles only what
  changed; the object cache in `~/.cache/hookshot-builder` is what makes it fast.
- If `RX_CPM` headers, clang, `RX_MARCH` or any lift-affecting variable changed, the lift key changes
  and the whole thing recompiles: 10-45 minutes depending on the tree and the CPU. Say so before it
  starts, and keep `--reserve-gb` at whatever the user's other work needs.
- The kit exports the whole contract (`RX_CPM`, `RX_MARCH=native`, `HOOKSHOT_JOBS`, `HOOKSHOT_LIFT_JOBS`,
  `HOOKSHOT_MEM_RESERVE_GB`, `HOOKSHOT_KEEP_BUILD_FILES=1`, `HOOKSHOT_NO_UPDATE_CHECK=1`). Never build by
  calling `nx2/make_game.py` directly without them, and never mix an old object cache with new flags.

## 8. Verify before it counts as done

```sh
scripts/cachyos/rebuild.sh verify
```

The gates, and what each means:

| gate | must be |
|---|---|
| AVX-512 (`zmm`, write masks) in `.text` | **0** on this CPU (i9-13900KS has none): anything else is a fatal regression |
| instructions beyond x86-64-v3 (VNNI, GFNI, VAES, VPCLMULQDQ, MOVDIR) | 0 |
| ymm vs xmm counts | non-zero ymm, and ymm should be near zero only if `--march x86-64` was chosen deliberately |
| FMA (`vfmadd` etc.) | present and expected: the game's ARM64 `FMADD` becomes native FMA, that is not a bug |
| play profile | accepted: no "cannot read the play profile" in the log; `code_hot_` pieces compiled |
| link order | `.text`'s first 12 symbols match `work/hot_order.txt` |
| NEEDED libs of `hookshot` | no SDL, no Vulkan (both are dlopened at run time) |
| imported symbols | no socket/getaddrinfo/curl/OpenSSL |
| glibc ceiling | at or below the system's, which is what `readelf -n` and the manifest record |

Also re-check that the install points are still valid: `~/.local/bin/hookshot` symlink,
`~/.config/hookshot/local-build.conf`, `~/.local/share/applications/hookshot-local.desktop`.

## 9. Report, then ask about pushing

Report as a short diff of before and after:

```
source:   <old commit> (<tag>)  ->  <new commit> (<tag>)
clang:    <unchanged or new>     cpm headers: <part name + sha>
profile:  <release the profile came from>
game:     <old sha256>  ->  <new sha256>      build id: <readelf -n>
build:    <wall time, compile time>          selftest: <N passed, N failed>
gates:    AVX-512 0 · PGO yes · link order 12/12 · glibc ceiling <ver> · no net imports
kept:     saves, options, shader caches, mods (list anything that was invalidated and must be rebuilt)
```

Mention explicitly when the shader caches were invalidated (`hookshot_programs.bin`,
`mkw_vk_pipelines.bin`), because the next start is slow and that surprises people. Ask before
`git push`, and never push a merge the user has not seen the change set for.

## Things this fork does not do

- never `scripts/linux/deps.sh` and never the AppImage: they fetch LLVM/CPython/FFmpeg/SDL2/CPM without
  hashes; compiler and libraries come from repo-signed pacman packages only
- never run a downloaded Hookshot binary, and never install an auto-updater
- never fetch DLSS/NGX blobs: proprietary, needs the user's explicit acceptance
- never commit game files, `work/`, or anything under `~/Games/Hookshot`
- do not "fix" the `3 bad` texture members: see `scripts/cachyos/DUMP-DEFECT.md`
