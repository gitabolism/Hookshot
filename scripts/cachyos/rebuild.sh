#!/usr/bin/env bash
# Hookshot on CachyOS/Arch: rebuild the game from source, with the downloads pinned and verified.
#
#   This is the "Linux, without the AppImage" route from readme.md, automated and hardened:
#     - the compiler and every shared library come from repo-signed pacman packages, never fetched;
#     - the only downloads are Hookshot's own release parts, verified against the SHA-256 in
#       Hookshot's own release manifest (through upstream's scripts/release_parts.py);
#     - upstream's game-free test suite runs before the build;
#     - the game is built with -march tuning for this CPU, plus the release's play profile (PGO),
#       its hot-function list and its hot link order;
#     - the result is verified afterwards: ABI surface, instructions actually emitted, and proof
#       that PGO and the link order landed.
#   Nothing here downloads or runs a prebuilt Hookshot binary, and no auto-updater is installed.
#
#   ./rebuild.sh all --nup ~/Downloads/your-game.nup      # everything, top to bottom
#   ./rebuild.sh show                                     # what it knows about this machine
#   ./rebuild.sh                                          # this help
#
# Subcommands (each is idempotent and can be re-run):
#   preflight   check CPU / GPU / RAM / disk / glibc, and report missing packages
#   deps        install the missing packages (needs sudo; prints the command when sudo is unavailable)
#   fetch cpm     pinned Vulkan/SPIRV/VMA headers, from Hookshot's own release part
#   fetch profile the release's play profile + hot lists, into work/ (gitignored)
#   fetch all     both of the above
#   selftest    upstream's game-free suite: python -I -B tests/run_all.py
#   rom-check   is this dump the supported version?   --full also hashes the whole .nup
#   build       translate + compile the game (CPU only: needs no GPU and no VRAM)
#   update      rebuild a folder built before: keeps saves/settings, compiles only what changed
#               (this replaces upstream's own "Update" button, without any downloader)
#   verify      check the finished binary (verify-build.sh)
#   install     launcher in ~/.local/bin + an applications-menu entry
#   show        preflight plus the manifest of the last recorded run
#   all         preflight deps fetch-cpm selftest fetch-profile rom-check build verify install
#
# Options (before or after the subcommand):
#   --nup FILE            your .nup (needed by rom-check/build/all)
#   --out DIR             game folder        (default ~/Games/Hookshot)
#   --work-dir DIR        objects + lifted C (default ~/.cache/hookshot-builder, as upstream does)
#   --state DIR           this script's own files (default ~/.cache/hookshot-local)
#   --language CODE       game language (default: taken from $LANG)
#   --march X             RX_MARCH: native (default), x86-64-v3, x86-64-v2, x86-64
#   --jobs N              clang processes at once (default: cores, capped at 24)
#   --reserve-gb N        free memory the build leaves alone (default 8; raise it if other work runs)
#   --lift-jobs N         lift workers (default: half the jobs, at most 8)
#   --full                with rom-check: hash every member of the .nup (reads all of it once)
#   --strict              selftest stops the run on a failing check (CI's strict mode)
#   --no-pgo              build without the release's play profile (a little slower in play)
#   --dry-run             print what would run; run nothing that costs time or touches the network
#
# Accepted, known deviation: some dumps hold a few romfs/Tex/*.bntx.zs members that are not zstd
# frames (this dump has 3: their first 2-3 pages are zeros; documented with the measurements in
# scripts/cachyos/DUMP-DEFECT.md). It is the dump's own content, it hashes to what the container says,
# and it changes nothing about the compiled game.
#
# Local tooling for a GPL project; not part of upstream.
set -euo pipefail

# ------------------------------------------------------------------- where things are
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
STATE=${HOOKSHOT_STATE:-$HOME/.cache/hookshot-local}
OUT=${HOOKSHOT_GAME:-$HOME/Games/Hookshot}
WORKDIR=${HOOKSHOT_WORK:-$HOME/.cache/hookshot-builder}     # (upstream's own default)
NUP=${HOOKSHOT_NUP:-}
LANGUAGE=auto
MARCH=native
JOBS=auto RESERVE_GB=8 LIFT_JOBS=auto
FULL=0 STRICT=0 PGO=1 DRY=0

# The compiler and every library the game links or dlopens, from the distro.
# (Arch's ffmpeg ships its headers; ffmpeg 9.0.2 + dav1d 1.5.4 are the same versions upstream's
#  scripts/linux/deps.sh builds; the game dlopens libSDL3.so.0 at run time.)
PKGS=(git curl unzip tar xz zstd bzip2 python python-pip clang lld pkg-config ffmpeg dav1d sdl3
      vulkan-icd-loader vulkan-tools coreutils which)
# The lift's Python modules: pacman's are repo-signed, so they are preferred over pip.
PYPKGS=(python-lz4 python-numpy python-capstone python-unicorn python-zstandard)
# Exactly the versions upstream pins in scripts/linux/deps.sh; used only if pacman's are missing.
PYPI=(lz4==4.4.5 numpy==2.5.4 capstone==5.0.9 unicorn==2.1.4 zstandard==0.25.0)

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1m!!\033[0m %s\n' "$*" >&2; }
note() { printf '   %s\n' "$*"; }
die()  { warn "$*"; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '   [dry] %s\n' "$*"; else "$@"; fi; }
usage() { awk 'NR==1{next} /^set -euo/{exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; }

# ------------------------------------------------------------------- options
CMD=""; SUB=""; OPTS=()
while [ $# -gt 0 ]; do
    case $1 in
        --nup)        NUP=${2:?--nup needs a file}; shift 2 ;;
        --out)        OUT=${2:?}; shift 2 ;;
        --work-dir)   WORKDIR=${2:?}; shift 2 ;;
        --state)      STATE=${2:?}; shift 2 ;;
        --language)   LANGUAGE=${2:?}; shift 2 ;;
        --march)      MARCH=${2:?}; shift 2 ;;
        --jobs)       JOBS=${2:?}; shift 2 ;;
        --reserve-gb) RESERVE_GB=${2:?}; shift 2 ;;
        --lift-jobs)  LIFT_JOBS=${2:?}; shift 2 ;;
        --full)       FULL=1; shift ;;
        --strict)     STRICT=1; shift ;;
        --no-pgo)     PGO=0; shift ;;
        --dry-run)    DRY=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            if [ -z "$CMD" ]; then CMD=$1; else SUB=$1; fi; shift ;;
    esac
done
OUT=${OUT/#\~/$HOME}; NUP=${NUP/#\~/$HOME}; STATE=${STATE/#\~/$HOME}; WORKDIR=${WORKDIR/#\~/$HOME}

# ------------------------------------------------------------------- helpers
pick_language() {
    if [ "$LANGUAGE" != auto ]; then printf '%s\n' "$LANGUAGE"; return; fi
    local l=${LC_ALL:-${LC_MESSAGES:-${LANG:-en_US.UTF-8}}}
    local base=${l%%.*}          # en_CA.UTF-8 -> en_CA
    local country=${base#*_}    # en_CA        -> CA
    country=${country^^}
    case ${base%%_*} in
        en) if [ "$country" = GB ]; then printf 'en-GB\n'; else printf 'en-US\n'; fi ;;
        pt) printf 'pt-BR\n' ;;
        es) if [ "$country" = ES ]; then printf 'es-ES\n'; else printf 'es-419\n'; fi ;;
        fr) printf 'fr\n' ;;
        de) printf 'de\n' ;;
        it) printf 'it\n' ;;
        nl) printf 'nl\n' ;;
        pl) printf 'pl\n' ;;
        ru) printf 'ru\n' ;;
        ja) printf 'ja\n' ;;
        ko) printf 'ko\n' ;;
        *)  printf 'en-US\n' ;;
    esac
}

python_bin() {   # pacman's python when it already has the five modules, otherwise our venv
    if python3 -c 'import lz4.frame, numpy, capstone, unicorn, zstandard' 2>/dev/null; then
        printf '%s\n' "$(command -v python3)"
    elif [ -x "$STATE/venv/bin/python" ]; then
        printf '%s\n' "$STATE/venv/bin/python"
    else
        printf '%s\n' ""
    fi
}

ensure_python() {
    [ -n "$(python_bin)" ] && return 0
    log "python modules missing: making a pinned venv with pip"
    mkdir -p "$STATE"
    run python3 -m venv "$STATE/venv"
    run "$STATE/venv/bin/python" -m pip install --disable-pip-version-check --no-cache-dir \
        --only-binary :all: "${PYPI[@]}"
    if [ "$DRY" != 1 ]; then
        "$STATE/venv/bin/python" - <<'PY'
import importlib.metadata as m
for p in ("lz4", "numpy", "capstone", "unicorn", "zstandard"):
    print("   venv", p, m.version(p))
PY
    fi
    note "pip verifies TLS and the index's own hashes, not --require-hashes: pacman's packages are the stronger route"
}

need_nup() { [ -n "$NUP" ] && [ -f "$NUP" ] || die "--nup <file> is needed for this step"; }

part_field() {   # part_field <name substring> <column>; empty when there is no manifest yet
    [ -f "$STATE/setup.txt" ] || return 0
    awk -v n="$1" -v c="$2" 'index($0, n){print $c; exit}' "$STATE/setup.txt" 2>/dev/null || true
}

effective_jobs()  { local j=$JOBS; [ "$j" = auto ] && j=$(nproc); [ "$j" -gt 24 ] && j=24; [ "$j" -lt 1 ] && j=1; printf '%s\n' "$j"; }
effective_lift()  { local j=$LIFT_JOBS n; n=$(effective_jobs); [ "$j" = auto ] && j=$(( n / 2 )); [ "$j" -lt 1 ] && j=1; [ "$j" -gt 8 ] && j=8; printf '%s\n' "$j"; }

manifest() {   # record what this run used, so a later rebuild can be compared byte for byte
    mkdir -p "$STATE"
    {
        printf '# hookshot local rebuild manifest\n'
        printf 'date=%s\n' "$(date -Is)"
        printf 'repo=%s\n' "$REPO"
        printf 'commit=%s\n' "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
        printf 'clang=%s\n' "$(clang --version 2>/dev/null | head -1)"
        printf 'lld=%s\n' "$(ld.lld --version 2>/dev/null | head -1)"
        printf 'python=%s\n' "$PY"
        printf 'march=%s jobs=%s lift=%s reserve=%sGB pgo=%s language=%s\n' \
            "$MARCH" "$(effective_jobs)" "$(effective_lift)" "$RESERVE_GB" "$PGO" "$(pick_language)"
        printf 'out=%s work=%s\n' "$OUT" "$WORKDIR"
        if [ -f "$STATE/setup.txt" ]; then
            printf 'release_manifest_sha256=%s\n' "$(sha256sum "$STATE/setup.txt" | cut -d' ' -f1)"
            printf 'release_tag=%s\n' "$(awk '/^tag /{print $2}' "$STATE/setup.txt")"
        fi
        [ -f "$STATE/parts.sha256" ] && sed 's/^/part=/' "$STATE/parts.sha256"
        if [ -f "$OUT/hookshot" ]; then
            printf 'game_sha256=%s\n' "$(sha256sum "$OUT/hookshot" | cut -d' ' -f1)"
            printf 'game_buildid=%s\n' "$(readelf -n "$OUT/hookshot" 2>/dev/null | awk '/Build ID/{print $3}')"
        fi
        if command -v pacman >/dev/null; then
            pacman -Q clang lld ffmpeg dav1d sdl3 glibc 2>/dev/null | sed 's/^/pkg=/'
        fi
    } > "$STATE/manifest.txt"
    note "manifest: $STATE/manifest.txt"
}

# ------------------------------------------------------------------- subcommands
cmd_preflight() {
    local cpu; cpu=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)
    log "preflight: $(uname -sr) / ${cpu:-unknown CPU}"

    grep -qw avx2 /proc/cpuinfo \
        && note "CPU: AVX2 (x86-64-v3) present, which is what Hookshot wants" \
        || warn "CPU: no AVX2. Hookshot still builds, but upstream says it then runs slower"
    grep -qw avx512f /proc/cpuinfo && note "CPU: AVX-512 present (Hookshot does not use it)"

    local cores gb avail freeg
    cores=$(nproc); gb=$(awk '/^MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
    avail=$(awk '/^MemAvailable/{printf "%d", $2/1048576}' /proc/meminfo)
    note "CPU: $cores threads.  RAM: ${gb} GB total, ${avail} GB available right now"
    [ "$avail" -ge 16 ] || warn "only ${avail} GB available: the build wants ~16 GB free. Raise --reserve-gb if you run other work"
    df -h "$HOME" | awk 'NR==2{printf "   disk: %s free on %s\n", $4, $6}'
    freeg=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc 0-9)
    [ "$freeg" -ge 90 ] || warn "only ${freeg} GB free: expect ~60 GB during a build plus ~26 GB for the game folder"
    note "glibc: $(ldd --version | head -1 | awk '{print $NF}') (upstream needs 2.35 or newer)"

    if ! command -v vulkaninfo >/dev/null 2>&1; then
        warn "vulkaninfo not installed (package vulkan-tools): cannot check the GPU"
    else
        local vi
        if ! vi=$(vulkaninfo 2>&1); then
            warn "GPU: vulkaninfo could not run (another program may be holding the device, or the driver"
            warn "   needs a reload after an update). Nothing concluded: re-run preflight when the GPU is idle"
        else
            # matched in bash, not with 'grep -q': grep -q closes the pipe, the writer then dies of SIGPIPE,
            # and with 'set -o pipefail' that failure would report the extension as missing
            case $vi in
                *VK_EXT_mesh_shader*)
                    note "GPU: mesh shaders available: $(printf '%s\n' "$vi" | awk -F' = ' '/deviceName/{print $2; exit}')"
                    case $vi in *VK_NV_low_latency2*) note "GPU: VK_NV_low_latency2 present (the menu's NVIDIA Reflex row)" ;; esac ;;
                *) warn "GPU: VK_EXT_mesh_shader is not reported. Hookshot needs it (readme: cards without mesh shaders are unsupported)" ;;
            esac
        fi
    fi

    local missing=() missingpy=() p
    for p in "${PKGS[@]}";   do pacman -Qq "$p" >/dev/null 2>&1 || missing+=("$p"); done
    for p in "${PYPKGS[@]}"; do pacman -Qq "$p" >/dev/null 2>&1 || missingpy+=("$p"); done
    [ ${#missing[@]}   -eq 0 ] && note "packages: all present" || note "packages missing: ${missing[*]}"
    [ ${#missingpy[@]} -eq 0 ] && note "python modules: from pacman" \
        || note "python modules missing from pacman: ${missingpy[*]} (pip fallback in 'deps')"
    note "source: $(git -C "$REPO" rev-parse --short HEAD) on $(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    note "state: $STATE   game: $OUT   objects: $WORKDIR"
}

cmd_deps() {
    local missing=() p
    for p in "${PKGS[@]}" "${PYPKGS[@]}"; do pacman -Qq "$p" >/dev/null 2>&1 || missing+=("$p"); done
    if [ ${#missing[@]} -eq 0 ]; then log "deps: nothing to install"; return; fi
    log "deps: ${#missing[@]} package(s) needed"
    note "sudo pacman -S --needed --noconfirm ${missing[*]}"
    if ! sudo -n true 2>/dev/null; then
        warn "no passwordless sudo: run that command yourself, then re-run this step"
        return 0
    fi
    run sudo pacman -S --needed --noconfirm "${missing[@]}"
}

cmd_fetch() {
    local what=${1:-all}
    mkdir -p "$STATE/dl"
    if [ ! -f "$STATE/setup.txt" ]; then
        log "fetch: reading the part list of Hookshot's newest stable release"
        ensure_python; PY=$(python_bin)
        run "$PY" -I scripts/release_parts.py previous "$STATE/setup.txt" --repo NotRexed/Hookshot
        if [ -f "$STATE/setup.txt" ]; then
            note "parts named by SHA-256 in that manifest:"
            sed 's/^/     /' "$STATE/setup.txt"
        fi
    fi

    if [ "$what" = all ] || [ "$what" = cpm ]; then
        log "fetch cpm: Vulkan/SPIRV headers + VMA, checked against the manifest's SHA-256"
        local sha size url name
        if [ "$DRY" = 1 ]; then
            note "[dry] would fetch the cpm part named in $STATE/setup.txt, check its SHA-256 and unpack"
            note "[dry] vulkanheaders, spirv-headers and vulkanmemoryallocator into $STATE/cpm"
            note "[dry] (why: nx2/build.py silently leaves out the Vulkan renderer without these headers)"
        else
        sha=$(part_field HookshotBuilder-cpm- 2); size=$(part_field HookshotBuilder-cpm- 3)
        url=$(part_field HookshotBuilder-cpm- 7); name=${url##*/}
        if [ -z "$sha" ]; then
            die "no cpm part in $STATE/setup.txt: re-run 'fetch' once the release list is reachable"
        fi
        note "expect ${size} bytes, sha256 ${sha}"
        if [ ! -f "$STATE/dl/$name" ]; then
            run curl -fL --proto '=https' --retry 5 --retry-delay 5 -o "$STATE/dl/$name.part" "$url"
            run mv -f "$STATE/dl/$name.part" "$STATE/dl/$name"
        fi
        if [ "$DRY" != 1 ]; then
            printf '%s  %s\n' "$sha" "$STATE/dl/$name" | sha256sum -c -
            printf '%s  %s\n' "$sha" "$name" >> "$STATE/parts.sha256"
        fi
        run rm -rf "$STATE/cpm" "$STATE/dl/cpm-x"
        run mkdir -p "$STATE/cpm" "$STATE/dl/cpm-x"
        run unzip -q "$STATE/dl/$name" -d "$STATE/dl/cpm-x" \
            'HookshotBuilder/tools/cpm/vulkanheaders/*' 'HookshotBuilder/tools/cpm/spirv-headers/*' \
            'HookshotBuilder/tools/cpm/vulkanmemoryallocator/*'
        run cp -a "$STATE/dl/cpm-x/HookshotBuilder/tools/cpm/." "$STATE/cpm/"
        run rm -rf "$STATE/dl/cpm-x"
        for p in "$STATE"/cpm/*/; do if [ -d "$p" ]; then note "$(basename "$p") -> $(ls "$p" 2>/dev/null | tr '\n' ' ')"; fi; done
        note "why: nx2/build.py silently leaves out the Vulkan renderer when RX_CPM has no headers"
        fi
    fi

    if [ "$what" = all ] || [ "$what" = profile ]; then
        if [ "$PGO" = 0 ]; then log "fetch profile: skipped (--no-pgo); the game builds, a little slower in play"; return 0; fi
        log "fetch profile: the release's play profile, hot-function list and hot link order"
        note "only those data files are taken out of the part; no binary in it is ever run"
        ensure_python; PY=$(python_bin)
        run "$PY" -I scripts/release_parts.py profile "$STATE/setup.txt" "$REPO/work"
        run ls -l "$REPO/work"
        note "work/ is in upstream's .gitignore, so git status stays clean"
    fi
}

cmd_selftest() {
    log "selftest: upstream's game-free suite (the same checks CI runs on every push)"
    note "tests/test_make_game_cache.py blocks every subprocess launch, so it reports a false failure"
    note "while the release's play profile sits in work/ (make_game.py then probes the compiler for"
    note "profile readability). Upstream's CI has no work/ in that job, so it is stashed first."
    ensure_python; PY=$(python_bin)
    mkdir -p "$STATE/logs"
    if [ "$DRY" = 1 ]; then note "[dry] $PY -I -B tests/run_all.py${STRICT:+ --strict}"; return 0; fi
    local -a opts=(); [ "$STRICT" = 1 ] && opts+=(--strict)
    # Only work/hookshot_pieces.prof triggers the probe (make_game.py:1049), so just that one file moves
    # aside. Moving the whole directory would race: the suite itself writes into work/.
    local held="$STATE/hookshot_pieces.prof-held" moved=0
    if [ -f "$REPO/work/hookshot_pieces.prof" ]; then
        mv "$REPO/work/hookshot_pieces.prof" "$held"; moved=1
    fi
    export RX_CPM="$STATE/cpm"
    local rc=0
    "$PY" -I -B tests/run_all.py ${opts[@]+"${opts[@]}"} || rc=$?
    if [ "$moved" = 1 ]; then mv "$held" "$REPO/work/hookshot_pieces.prof"; fi
    rm -rf "$REPO"/work/capture-copy-runs-*     # litter the suite leaves behind (work/ is gitignored anyway)
    if [ $rc -ne 0 ]; then
        if [ "$STRICT" = 1 ]; then die "a check failed (--strict): not building on top of it"; fi
        warn "some checks failed: read the table above. Continuing, as CI's non-strict mode would"
    fi
}

cmd_rom_check() {
    need_nup
    ensure_python; PY=$(python_bin)
    log "rom-check: is this the dump Hookshot supports?"
    note "file: $NUP ($(stat -c%s "$NUP") bytes)"
    note "sha256: $(sha256sum "$NUP" | cut -d' ' -f1)"
    run "$PY" -I nx2/make_game.py --check --nup "$NUP"
    if [ "$FULL" = 1 ]; then
        log "rom-check --full: hashing every member of the container (reads the whole file once)"
        run "$PY" -I nx2/nup.py "$NUP" --verify
        note "a few romfs/Tex/*.bntx.zs members may be flagged: scripts/cachyos/DUMP-DEFECT.md explains"
        note "them. A member whose SHA-256 mismatched would be a real problem: the copy is then incomplete"
        note "or altered."
    fi
}

cmd_build() {
    need_nup
    ensure_python; PY=$(python_bin)
    local jobs lift logf
    jobs=$(effective_jobs); lift=$(effective_lift)
    [ -d "$STATE/cpm" ] || die "no CPM headers: run 'fetch cpm' first, or the Vulkan renderer is silently left out"
    if [ "$PGO" = 1 ] && [ ! -f "$REPO/work/hookshot_pieces.prof" ]; then
        warn "work/hookshot_pieces.prof is missing: building without the release's play profile"
    fi
    log "build: -march=$MARCH, $jobs clangs, $lift lift workers, ${RESERVE_GB} GB of memory left alone"
    note "CPU only: this needs no GPU and no VRAM. Expect roughly 10-45 minutes, less on a big CPU"
    mkdir -p "$OUT" "$STATE/logs"
    logf="$STATE/logs/build-$(date +%Y%m%d-%H%M%S).log"
    export RX_CPM="$STATE/cpm" RX_MARCH="$MARCH" HOOKSHOT_JOBS="$jobs" HOOKSHOT_LIFT_JOBS="$lift"
    export HOOKSHOT_MEM_RESERVE_GB="$RESERVE_GB" HOOKSHOT_KEEP_BUILD_FILES=1 HOOKSHOT_NO_UPDATE_CHECK=1
    run "$PY" -I nx2/make_game.py --nup "$NUP" --out "$OUT" --work "$WORKDIR" --jobs "$jobs" \
        --language "$(pick_language)" --log "$logf"
    note "log: $logf"
    [ "$DRY" = 1 ] || manifest
}

cmd_update() {   # the game's own "Update" path, without any downloader
    [ -d "$OUT" ] || die "no game folder at $OUT (nothing to update)"
    ensure_python; PY=$(python_bin)
    [ -d "$STATE/cpm" ] || die "no CPM headers: run 'fetch cpm' first, or the Vulkan renderer is silently left out"
    local jobs lift logf
    jobs=$(effective_jobs); lift=$(effective_lift)
    log "update: building $OUT again with these tools; only what changed is compiled"
    note "saves, hookshot_options.ini, hookshot_env.txt and mods are kept by make_game.py"
    mkdir -p "$STATE/logs"
    logf="$STATE/logs/update-$(date +%Y%m%d-%H%M%S).log"
    export RX_CPM="$STATE/cpm" RX_MARCH="$MARCH" HOOKSHOT_JOBS="$jobs" HOOKSHOT_LIFT_JOBS="$lift"
    export HOOKSHOT_MEM_RESERVE_GB="$RESERVE_GB" HOOKSHOT_KEEP_BUILD_FILES=1 HOOKSHOT_NO_UPDATE_CHECK=1
    run "$PY" -I nx2/make_game.py --update "$OUT" --work "$WORKDIR" --jobs "$jobs" --log "$logf"
    note "log: $logf"
    [ "$DRY" = 1 ] || manifest
}

cmd_verify() { run bash "$HERE/verify-build.sh" "$OUT"; [ "$DRY" = 1 ] || manifest; }

cmd_install() {
    log "install: launcher + applications-menu entry (no updater installed, on purpose)"
    if [ "$DRY" = 1 ]; then
        note "[dry] would write ${XDG_CONFIG_HOME:-$HOME/.config}/hookshot/local-build.conf,"
        note "[dry] ~/.local/bin/hookshot -> $HERE/hookshot-launch, and hookshot-local.desktop"
        return 0
    fi
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "${XDG_CONFIG_HOME:-$HOME/.config}/hookshot"
    printf '# what scripts/cachyos/hookshot-launch and sandbox-bwrap.sh use. Written by rebuild.sh install.\nGAME=%s\nSTATE=%s\nSRC=%s\n' \
        "$OUT" "$STATE" "$REPO" > "${XDG_CONFIG_HOME:-$HOME/.config}/hookshot/local-build.conf"
    note "config: ${XDG_CONFIG_HOME:-$HOME/.config}/hookshot/local-build.conf"
    ln -sf "$HERE/hookshot-launch" "$HOME/.local/bin/hookshot"
    note "hookshot -> $HERE/hookshot-launch"
    [ -d "$HOME/.local/bin" ] && case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *)
        warn "$HOME/.local/bin is not in PATH: start the game from the menu entry, or add it to PATH" ;; esac
    local icon="$OUT/hookshot.png"
    [ -f "$icon" ] || icon=/usr/share/icons/hicolor/48x48/apps/system-software-update.png
    cat > "$HOME/.local/share/applications/hookshot-local.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Hookshot (local build)
GenericName=Game
Comment=The Legend of Zelda: Ocarina of Time (Switch 2), recompiled on this PC - no emulator
Exec=$HERE/hookshot-launch
Path=$OUT
Icon=$icon
Terminal=false
Categories=Game;Emulator;
Keywords=zelda;ocarina;time;recomp;hookshot;
StartupWMClass=hookshot
EOF
    if command -v desktop-file-validate >/dev/null 2>&1; then
        desktop-file-validate "$HOME/.local/share/applications/hookshot-local.desktop" && note "menu entry validates"
    fi
    note "optional stronger isolation while playing: bash $HERE/sandbox-bwrap.sh"
    note "suggested settings for a big GPU card: see NOTES.md (output resolution, Reflex, robust buffers)"
}

cmd_show() {
    cmd_preflight
    echo
    if [ -f "$STATE/manifest.txt" ]; then log "last recorded run"; sed 's/^/   /' "$STATE/manifest.txt";
    else note "no manifest yet (build writes one)"; fi
    if [ -f "$OUT/hookshot" ]; then
        echo; log "game folder: $OUT"
        ls -l "$OUT" | awk 'NR>1 && $9!="." {printf "   %11s  %s\n", $5, $9}'
    fi
}

# ------------------------------------------------------------------- dispatch
case ${CMD:-} in
    preflight) cmd_preflight ;;
    deps)      cmd_deps ;;
    fetch)     cmd_fetch "${SUB:-all}" ;;
    selftest)  cmd_selftest ;;
    rom-check) cmd_rom_check ;;
    build)     cmd_build ;;
    update)    cmd_update ;;
    verify)    cmd_verify ;;
    install)   cmd_install ;;
    show)      cmd_show ;;
    all)       cmd_preflight; cmd_deps; cmd_fetch cpm; cmd_selftest; cmd_fetch profile
               cmd_rom_check; cmd_build; cmd_verify; cmd_install ;;
    "")        usage ;;
    *)         warn "unknown subcommand: $CMD"; echo; usage; exit 2 ;;
esac
# Written as an if, not as '[ "$DRY" = 1 ] && warn ...': as the script's last statement that list would
# set the exit status to 1 on every normal run, so 'rebuild.sh build && something' would always look like
# a failure.
if [ "$DRY" = 1 ]; then warn "dry run: nothing that costs time or touches the network was executed"; fi
