# Three malformed texture members in the game container

A complete record of an anomaly found in the `.nup` game files used to build this game: what it is,
how it was found, what caused it, what it does to the game, what can and cannot be done about it, and
how to re-check any of it. Written so that every claim below can be reproduced by the commands in
§9 — and so that a later reader can tell exactly what is *measured* and what is *inference*.

**Short version:** three of 186,587 romfs files, all of them texture archives, have lost the first 8 or
12 KiB — exactly 2 or 3 pages — of their contents. They are otherwise intact compressed data. The
container's own SHA-256 for those three files matches the broken bytes, which proves the damage existed
**before the container was built**, so it is not damage to this PC, not damage in transit, and not a
Hookshot reader bug. Nothing in the compiled game depends on them. The missing bytes cannot be
reconstructed locally: they are the head of a compressed stream, not a header that can be rewritten.

---

## 1. The files involved

| | |
|---|---|
| Game files | one `.nup` container, referred to below as `~/Downloads/<your-dump>.nup` |
| Size | 25,020,741,061 bytes |
| Container | `NUP\x01`; title `0400486024dec000`, version 131072; exefs 5 modules; romfs 186,587 files |
| Support check | `@@check ok This is the version Hookshot supports (build e0f3ccfa).` |
| How it was obtained | a third-party dump of the title, not a read from a card on this machine. The source's own release name, and the paths it sat on, are deliberately **not** recorded: they identify a distribution and someone's disk, and no conclusion here depends on them |

Two omissions are deliberate. The container's whole-file SHA-256 is not published, because it fingerprints
one specific distribution of copyrighted game files — and the copy-fidelity proof in §5 is a byte
comparison, not a published hash. Every number below is read from inside the container, so it holds for
any copy of the same build. And whatever a copy of this file happens to be named, the header inside it says
`0400486024dec000`, which is the title Hookshot supports.

The extracted copy the game actually reads is `~/Games/Hookshot/romfs/` (186,587 files, 25 GB).

## 2. How the container is laid out (needed to follow the rest)

`nx2/nup.py` is Hookshot's own reader for this format, and it is what the numbers below come from.
Its table of contents holds a directory table, a file table (80 bytes per file), a child table and a
string table (`nup.py:80-104`). A file record gives:

| field | meaning |
|---|---|
| `size` | the member's own length, i.e. the length of the file as the game sees it |
| `off` | where its bytes begin in the `.nup` |
| `stored` | how many bytes are actually stored there |
| `codec` | **0** = stored as-is (`stored` must equal `size`) · **1** = additionally compressed by the container itself |
| 32-byte hash at record offset +32 | **the expected SHA-256 of the member**, recorded by whoever packed the `.nup` (`nup.py:94-99`) |
| flags byte at +65, 14 reserved bytes at +66 | all zero here (`nup.py:330-333` rejects anything else as an unsupported codec/flag) |

Two consequences matter for this investigation. First, the container carries a hash **per file**, and
`--verify` compares it (`nup.py:351`). Second, a member can be compressed twice: by the game (the `.zs`
suffix means the *game* stores it zstd-compressed) and by the container (codec 1).

## 3. How the defect was found

`nx2/nup.py --verify` (run as `scripts/cachyos/rebuild.sh rom-check --full`) does two **independent**
passes over every member of every title:

1. **Fidelity** — read the member, recompute its SHA-256, compare with the hash recorded in the
   container. Plus bounds checks on `off`/`stored`/`size`, and decoding each compressed extent and
   checking it yields exactly `size` with no trailing bytes (`nup.py:334-351`).
2. **Shape** — a member whose name ends in `.zs` must decode to bytes beginning with the zstd frame
   signature `28 b5 2f fd`, and its frame parameters must parse (`nup.py:355-357`).

```
verified 186592 records, 159542 unique extents: 3 bad
BAD title 0 0400486024dec000 v131072 /romfs/Tex/CmnTex_Map_Soil_FairyFountain_Floor_D_Nrm.bntx.zs: .zs member lacks the expected game Zstd header
BAD title 0 0400486024dec000 v131072 /romfs/Tex/RBake_Scene_GanonStage_G_2_1_d0_t0.bntx.zs: .zs member lacks the expected game Zstd header
BAD title 0 0400486024dec000 v131072 /romfs/Tex/Rock_WaterTemple_Gate_M_01_Nrm.bntx.zs: .zs member lacks the expected game Zstd header
```

The decisive detail is which check each file failed: **only the second one.** Every one of the 186,592
hash comparisons matched, and the container's TOC and hash tree (`_verify_toc`, `_verify_tree`) verify
clean. So the bytes on this PC are exactly the bytes the packager hashed — and what they hashed was
already malformed. Full log: `~/.cache/hookshot-local/logs/nup-verify.log`.

Scale, so the anomaly is not blown out of proportion:

| population | count | of which malformed |
|---|---|---|
| records verified (all titles) | 186,592 | 3 |
| romfs members | 186,587 | 3 |
| romfs members stored with container codec 1 | 40,588 (codec 0: 145,999) | 3 |
| `.zs` members in the romfs | 102,185 (101,102 codec 0, 1,083 codec 1) | 3 |
| `romfs/Tex/*.zs` | 20,667 | 3 |

## 4. The three members, precisely

| romfs member | `size` | `stored` | codec | zero prefix | SHA-256 of the member as stored in this `.nup` |
|---|---|---|---|---|---|
| `Tex/CmnTex_Map_Soil_FairyFountain_Floor_D_Nrm.bntx.zs` | 216,015 | 203,753 | 1 | **12,288** = 3 pages | `6ed2d797e94a26c970a3b866ecdbd393d2085fccbad2d32bd0655ac369e88aac` |
| `Tex/RBake_Scene_GanonStage_G_2_1_d0_t0.bntx.zs` | 1,901,341 | 1,889,157 | 1 | **12,288** = 3 pages | `c01c128a8e01e2e466bd36d6514ad54a4269c608e245f648e43c238deb245e48` |
| `Tex/Rock_WaterTemple_Gate_M_01_Nrm.bntx.zs` | 452,972 | 444,818 | 1 | **8,192** = 2 pages | `7791f6ddaf12b4dd4766d097d8416e52cd57f996ef67818c9e300645c48f7484` |

**They are not empty and not mostly zeros.** They are high-entropy data with a hole at the front:

| member | non-zero bytes | run structure (maximal runs of equal-ness) |
|---|---|---|
| `..._Soil_FairyFountain_Floor_D_Nrm` | 202,821 of 216,015 = **93.89%** | 1,774 runs; longest data run 1,520 B, data runs interleaved with single zero bytes |
| `Rock_WaterTemple_Gate_M_01_Nrm` | 442,594 of 452,972 = **97.71%** | 4,318 runs; longest data run 2,402 B |
| `RBake_Scene_GanonStage_G_2_1_d0_t0` | 1,878,911 of 1,901,341 = **98.82%** | 19,816 runs; longest data run 2,446 B |

A healthy member of the same family, for contrast — note it is codec 0, i.e. the game's own zstd file
stored without further compression:

```
Tex/CmnTex_Map_Rock_FairyFountain_Floor_A_Nrm.bntx.zs   size 476,087  stored 476,087  codec 0
  first 16 bytes: 28 b5 2f fd a0 70 60 08 00 5c 81 0e 3e e4 98 bb      <- zstd frame, as it must be
  container hash 351973c56645b3f371d440550d677e87…  == recomputed hash
```

And the same view of the three broken ones. The bytes **as they sit in the container** are a perfectly
valid zstd frame; what that frame decodes *to* is the broken file:

```
CmnTex_..._D_Nrm          on card: 28 b5 2f fd a0 cf 4b 03 00 5c 80 0e 2c 00 1d 00 00 96 31 6a 42 …   decodes to: 00 00 00 00 00 00 …
RBake_..._d0_t0           on card: 28 b5 2f fd a0 1d 03 1d 00 5c 80 0e 2c 00 1d 00 00 95 86 03 8e …   decodes to: 00 00 00 00 00 00 …
Rock_WaterTemple_..._Nrm  on card: 28 b5 2f fd a0 6c e9 06 00 5c 00 0f 2c 00 1e 00 00 10 0b d0 14 …   decodes to: 00 00 00 00 00 00 …
```

Two more measurements that pin the structure down:

- **The damaged bytes exist nowhere else in the container.** Each of the three extents is referenced by
  exactly one file record, no member name appears twice anywhere in the romfs, and the container holds a
  single title — so there is no second, healthy copy of these texture archives to fall back on. The raw
  extents, for anyone who wants to hexdump the `.nup` directly without any tooling:

  | member | offset in the `.nup` | stored | on-card bytes there begin with |
  |---|---|---|---|
  | `..._Soil_FairyFountain_Floor_D_Nrm` | 16,000,312,736 | 203,753 | `28 b5 2f fd a0 cf 4b 03 …` |
  | `RBake_Scene_GanonStage_G_2_1_d0_t0` | 21,118,789,424 | 1,889,157 | `28 b5 2f fd a0 1d 03 1d …` |
  | `Rock_WaterTemple_Gate_M_01_Nrm` | 23,659,345,056 | 444,818 | `28 b5 2f fd a0 6c e9 06 …` |

- **No compressed-stream header exists anywhere inside the three members.** Searched all of every file
  for zstd (`28 b5 2f fd`), zstd skippable (`18 4d 2a 5x`), `BTEX` (the BNTX texture-archive magic),
  lz4 frame (`04 22 4d 18`) and legacy (`18 4c 21 02`), xz (`fd 37 7a 58 5a 00`), `BTX1`, `TEXL`: no
  hits. Short two-byte sequences that look like gzip (`1f 8b`) or zlib (`78 01/9c/da`) do occur, at
  exactly the rate random data predicts (11 found vs 9.9 expected, 16 vs 20.7, 99 vs 87), and none of
  them inflates more than 256 bytes once a candidate is tried as an actual stream (zlib header, gzip
  header, or raw deflate) — so those two-byte hits are chance, not headers.
- **The non-zero remainder is incompressible.** The container's own zstd saved only 12,262 / 12,184 /
  8,154 bytes, and the zero pages account for 12,288 / 12,288 / 8,192 — i.e. `stored` equals
  `size − zeros` plus 26 / 104 / 38 bytes of overhead. All of the gain came from collapsing the zeros;
  everything after them is already compressed, which is what the tail of a zstd stream looks like.

## 5. What this is *not*

| hypothesis | verdict | evidence |
|---|---|---|
| the copy and rename on this PC damaged it | **no** | `cmp -l` between the file as it arrived and the working copy: **0 differing bytes** over 25,020,741,061 (7.9 s); the original's own TOC + hash tree verify clean and its three members hash identically |
| the transfer to this PC was incomplete or corrupt | **no** | the transfer tool's own end-to-end piece hashes all verified; independently, the container's TOC, hash tree and all 186,592 per-member SHA-256s verify on this PC |
| Hookshot's reader is mis-parsing these three | **no** | their stored extents are valid zstd frames that decode to exactly the recorded length with no trailing data (`copy_to`, `nup.py:250-278`); `1,080` of the `1,083` `.zs` members stored with the same codec decode to proper `.zs` |
| the container format is being misunderstood | **no** | TOC/tree/bounds/flags checks pass; flags byte and 14 reserved bytes are zero, so no encryption or odd codec is involved |
| the compiled game is affected | **no** | the lift reads only exefs code; the build's shader census walks `Shader/ Layout2Shader/ Lib/ Movie/ Effect/` and never `Tex/`; nothing in `image.bin`, `hookshot_vk.so` or the shader archives comes from these three files |
| the damage happened after packaging | **no** | the container's recorded SHA-256 **matches** the malformed content (`nup.py:351`), so the packager hashed it as it is |

## 6. What caused it, and what cannot be excluded

The chain, with what each link proves:

```
someone dumped the game ──┐  the only place a defect can enter that nothing here can see
                          ▼
        packed into this .nup  ── the packager hashed the malformed bytes → the defect predates this step
                          ▼
     transferred to this PC ── end-to-end piece hashes verified by the transfer tool
                          ▼
        your disk, then renamed/copied ── byte-identical to the original, container hashes verify
```

So the defect entered before packaging, at the dumper's end. The shape of it — **exactly 2 or 3
complete 4 KiB pages of zeros at the front of each member, with the remainder intact** — is the
signature of a read that returned zero-filled buffers instead of failing (a card read error, a
decompaction-cache miss, or a fuse/ISO layer substituting zeros). That is inference, but it is the only
shape that fits: no filesystem, copy or transfer mechanism produces page-aligned zero substitutions
while leaving per-file hashes of the result self-consistent.

What cannot be excluded, and should not be glossed over: the container's hashes prove **self-consistency,
not authenticity**. Whoever packed this `.nup` chose the contents and their hashes, so nothing in this
file can prove the content equals what Nintendo shipped. What was checked on the tooling side is
documented in [NOTES.md](NOTES.md) (source built from GitHub, no prebuilt blobs committed, no network
imports in the compiled game, upstream's own test suite passing); nothing here can audit the *dump*
against an authoritative copy. If the game files were dumped from a copy you own, that ownership is what
makes them authoritative — and Hookshot's own readme requires supplying your own legally obtained files.

## 7. What the game does with them

These three are **texture archives only**. What is measured: the copies in the extracted romfs are still
compressed (healthy ones begin with `28 b5 2f fd`), so they are inflated at run time and not at build
time; and nothing on the host side inflates them — no `ZSTD_*` anywhere in `host/`, and no zstd symbol in
`hookshot`'s dynamic imports. The inference from those two facts is that the inflate happens inside the
recompiled game code itself (the local build tree keeps objects rather than lifted C, so the decoder
cannot be pointed at by name here). Either way, a member whose stream has no header cannot be inflated,
so the worst case is a texture the game cannot load.

Reading the names, and cross-checking which members of each family survived:

| broken member | what the name says (inference from the naming scheme) | its family in this romfs, and what was checked on the others |
|---|---|---|
| `CmnTex_Map_Soil_FairyFountain_Floor_D_Nrm` | common map texture: **soil** ground of the Fairy Fountain floor, tile variant `D`, **normal** map | 3 members (`_D_Alb`, `_D_Nrm`, `_D_Rgh`): the other 2 begin with a valid zstd frame |
| `Rock_WaterTemple_Gate_M_01_Nrm` | rock texture of the Water Temple gate, mesh `M_01`, **normal** map | 20 members (variants `A C D E M_01 P_01` × `Alb/Nrm/Rgh/Mtl`): the other 19 begin with a valid zstd frame |
| `RBake_Scene_GanonStage_G_2_1_d0_t0` | **baked lighting** for scene `GanonStage G_2_1`, tile `d0 t0` | 8 members for `GanonStage_G_2_*`: the other 7 begin with a valid zstd frame |

(All three families were swept: every member of each was checked for its first four bytes, and exactly
one per family is the zero-prefixed one.)

Two of the three are **normal maps**, and in both of those families the albedo and roughness members
survived (table above), so colour and shading are intact and only bump detail can look flat. The third
is one tile of baked lighting out of a set of eight for that scene. Expected symptoms, at worst:
slightly flat-looking bump detail on one soil tile of the Fairy Fountain floor and on one mesh of the
Water Temple gate, and one patch of baked lighting wrong in Ganon's Castle. Not a crash, and not a
missing surface.

Observed in practice: the first play session (title screen through Kokiri Forest, 60.0 fps steady)
never requested these three members; nothing matching their names appears in `hookshot_log.txt`, and
there were 0 failed shader programs and no device-lost or assert lines.

To check after visiting those places:

```sh
L=$(~/.local/bin/hookshot --log)
grep -iE 'Soil_FairyFountain_Floor_D|WaterTemple_Gate_M_01|GanonStage_G_2_1' "$L"
```

plus your own eyes: compare the Fairy Fountain floor's bump detail, the Water Temple gate, and the
Ganon's Castle exterior against how they look elsewhere.

## 8. Fixing it: what works and what does not

**Cannot be repaired on this PC.** The missing 8 or 12 KiB are not a header that can be written back:
they are the beginning of a compressed stream, and a zstd stream needs the bytes that were there to
seed its window. The rest of the member is unusable without that head, and no copy of the data exists
anywhere else in the container: measured in §4 — exactly one member per name across the 25 GB romfs, and
each of the three extents referenced by exactly one file record. Deleting them is not an option either:
the game expects those paths to exist.

Two things are worth doing, in order:

1. **Nothing, if those three spots look fine.** This is 3 files of 186,587. Fixing it is only worth
   effort if you can actually see the defect.
2. **Get the three files from a source you trust** — which in practice means dumping the game yourself
   from a copy you own (card or eShop download). The three hashes in §4 are the test: a healthy copy
   gives a **different** hash and starts with `28 b5 2f fd`. A second copy from the same anonymous
   source is not a fix in any trustworthy sense: it is another unattributed dump. Locating copies of
   game files is not something this tooling exists to help with.

Putting good copies to use needs no rebuild, because romfs mods override game files at run time:

```sh
mkdir -p ~/Games/Hookshot/mods/fix/romfs/Tex
cp .../CmnTex_Map_Soil_FairyFountain_Floor_D_Nrm.bntx.zs ~/Games/Hookshot/mods/fix/romfs/Tex/
```

Verified in code, not assumed: `host/mods.c:104` treats **any** folder containing a `romfs/` subfolder as
a mod, so `fix` is just a name; `mods.c:146` puts the default root at `<game folder>/mods` and
`mods.c:140` lets `HOS_MODS` relocate it; `mods.c:123` disables any mod whose name starts with `-` or
`_`; up to 4 levels of nesting are scanned; `mods.c:168` (`hos_mods_romfs`) matches the romfs path
case-insensitively, and the game confirms each takeover in the log:

```
mods: fix: 3 RomFS files
mods: Tex/CmnTex_Map_Soil_FairyFountain_Floor_D_Nrm.bntx.zs <- ~/Games/Hookshot/mods/fix/romfs/Tex/CmnTex_Map_Soil_FairyFountain_Floor_D_Nrm.bntx.zs
```

`exefs/` overrides inside a mod are **not** applied (`mods.c:160-161`: that code is compiled ahead of
time), so this route is for romfs data such as textures — which is exactly the case here.

If you get a newer or different `.nup`, this pulls just those three members out of it — the same call
path used to produce the measurements above, and tested end to end:

```sh
cd ~/Projects/Hookshot
~/.cache/hookshot-local/venv/bin/python -I - <<'PY'
import sys, os, hashlib
sys.path.insert(0, "nx2"); import nup as N
SRC = "/path/to/another/dump.nup"                      # <- change this
WANT = {"cmntex_map_soil_fairyfountain_floor_d_nrm.bntx.zs",
        "rbake_scene_ganonstage_g_2_1_d0_t0.bntx.zs",
        "rock_watertemple_gate_m_01_nrm.bntx.zs"}
OUT  = os.path.expanduser("~/Games/Hookshot/mods/fix/romfs/Tex")
n = N.Nup(SRC); n._verify_toc(); n._verify_tree(); print("container verifies clean")
for name, rec in n.verify_walk(n.titles[0]["romfs"]):
    base = name.lstrip("/").split("/")[-1]
    if base.lower() not in WANT: continue
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, base), "wb") as g: n.copy_to(rec, g, name)
    head = open(os.path.join(OUT, base), "rb").read(4)
    print("%-52s %s  %s" % (base, head.hex(), "GOOD, zstd frame" if head == b"\x28\xb5\x2f\xfd" else "STILL BROKEN"))
PY
```

Against the current dump that prints `STILL BROKEN` three times, which is the expected outcome; on a
clean dump it lands the files and prints `GOOD, zstd frame`, and the game picks them up on the next
start with no rebuild.

## 9. Re-running any of this

```sh
cd ~/Projects/Hookshot

# both checks over the whole container (reads all 25 GB, several minutes), prints the BAD lines
python -I nx2/nup.py ~/Downloads/<your-dump>.nup --verify
# or through the kit, same thing:
scripts/cachyos/rebuild.sh rom-check --full --nup ~/Downloads/<your-dump>.nup

# is the working copy identical to the file as it arrived? (needs that original still present)
cmp -l "<the path the file arrived on>" ~/Downloads/<your-dump>.nup; echo $?   # 0 = identical

# how many Tex/*.zs begin with a zstd frame
cd ~/Games/Hookshot/romfs/Tex && python3 - <<'PY'
import os, collections
c = collections.Counter()
for e in os.scandir("."):
    if e.name.endswith(".zs"):
        with open(e, "rb", buffering=0) as f: h = f.read(4)
        c["zstd@0" if h == b"\x28\xb5\x2f\xfd" else ("zeros@0" if h == b"\0"*4 else "other")] += 1
print(dict(c))                                    # {'zstd@0': 20664, 'zeros@0': 3}
PY
```

Where the numbers in §2-§4 come from: `nx2/nup.py` (`file_details` and record layout at lines 94-99,
the per-member hash comparison at 351, the `.zs` header expectation at 355-357, extent decoding at
250-278, the whole verify pass at 306); everything else is `od`/`grep`/`python3` over the extracted
files in `~/Games/Hookshot/romfs/Tex/`.

## 10. Status

Open, low severity, cosmetic at worst, no action taken. Kept here so that:

- a future `rom-check --full` showing the same `3 bad` is understood as known and not a regression;
- a future dump of the same title can be checked against the three hashes in §4;
- nobody re-derives this, or "fixes" it by deleting files the game expects to exist.
