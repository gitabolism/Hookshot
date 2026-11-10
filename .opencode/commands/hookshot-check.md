---
description: Read-only health check of the local Hookshot build - hardware, pinned inputs, binary gates, install points
agent: hookshot-maintainer
---

Check the local Hookshot build without changing anything. Do not build, do not fetch, do not install,
do not push. Focus: $ARGUMENTS (empty means all of it).

Run, in this order, and report what each one shows:

```sh
scripts/cachyos/rebuild.sh show      # preflight + the manifest of the last recorded run + game folder
scripts/cachyos/rebuild.sh verify    # the built binary: gates below
~/.local/bin/hookshot --log         # the newest game log, if the game has run
```

Then report a short table of the gates, and below it anything that looks off:

| gate | expected on this machine |
|---|---|
| AVX-512 (`zmm`, AVX-512 write masks) | 0, or the binary will SIGILL here |
| beyond x86-64-v3 (VNNI, GFNI, VAES, VPCLMULQDQ, MOVDIR) | 0 |
| FMA present | yes, expected, not a bug |
| play profile accepted, `code_hot_` pieces compiled | yes |
| link order: first 12 `.text` symbols vs `work/hot_order.txt` | 12/12 |
| NEEDED of `hookshot` | no SDL, no Vulkan (both dlopened) |
| imported symbols | no socket/getaddrinfo/curl/OpenSSL |
| glibc ceiling vs the system's | at or below |
| install points | `~/.local/bin/hookshot` symlink, `~/.config/hookshot/local-build.conf`, the `.desktop` entry all present and pointing at the right game folder |

Finish with one line comparing `manifest.txt` (the source commit, clang, game SHA-256, build id) with
what is on disk now, so drift since the last recorded build is visible. If the newest game log exists,
also report the last few `vk: … presents, … fps` stat lines and confirm `0 failed` shader programs; the
`(N failed)` counter inside that line is a counter field, not an error.

Known, not to be re-litigated: `3 bad` texture members in a full container verify
(`scripts/cachyos/DUMP-DEFECT.md`), `build.py`'s "this CPU has no AVX2" wording when `-march=native`,
and FMA instructions in the binary.
