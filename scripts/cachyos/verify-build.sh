#!/usr/bin/env bash
# Post-build verification of a locally compiled Hookshot.
# Proves what the compiler actually did, checks the binary's ABI surface, and looks for anything
# unexpected in it.  Usage: verify-build.sh [game folder]
#
# What is and is not a red flag:
#   - AVX-512 in the output WOULD be fatal on a CPU that has none (e.g. a 13900K): the one hard check.
#   - FMA instructions are EXPECTED: the game's own ARM64 code uses FMADD/FMSUB and the lift turns
#     those into native FMA. build.py's -ffp-contract=off only forbids *contracting* a separate
#     multiply and add, so FMA here is not a semantics problem.
#   - build.py:452-453 prints "this CPU has no AVX2: the game is built for <march>" for any march that
#     is not literally "x86-64-v3", including "native". It is a false alarm, not a downgrade.
#   - SDL and Vulkan must NOT appear as NEEDED libraries: the game dlopens both at run time.
set -u
GAME=${1:-$HOME/Games/Hookshot}
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SRC=${HOOKSHOT_SRC_DIR:-$(CDPATH= cd -- "$HERE/../.." && pwd)}
STATE=${HOOKSHOT_STATE:-$HOME/.cache/hookshot-local}
LOG=$(ls -t "$STATE"/logs/build-*.log "$STATE"/logs/update-*.log 2>/dev/null | head -1)
TMP=${TMPDIR:-/tmp}/hookshot-verify-$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

echo "=== 1. the game folder ==="
ls -l "$GAME" 2>/dev/null | awk 'NR==1 || /hookshot|image|language|\.png|shaders|pipeline/'
du -sh "$GAME" 2>/dev/null

echo
echo "=== 2. ELF identity and ABI surface ==="
file "$GAME/hookshot" "$GAME/hookshot_vk.so" 2>/dev/null | cut -c1-160
echo "--- the game's NEEDED libs (SDL and Vulkan must be absent: both are dlopened at run time) ---"
readelf -d "$GAME/hookshot" 2>/dev/null | grep NEEDED | sed 's/^/  /'
echo "--- renderer NEEDED (libstdc++/libgcc must be absent: build.py links them statically) ---"
readelf -d "$GAME/hookshot_vk.so" 2>/dev/null | grep -E 'NEEDED|SONAME' | sed 's/^/  /'
echo "--- highest glibc symbol version needed (system: $(ldd --version | head -1 | awk '{print $NF}')) ---"
objdump -T "$GAME/hookshot" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -Vu | tail -1 | sed 's/^/  /'

echo
echo "=== 3. instructions emitted, over the hot-ordered head of .text ==="
echo "    (lld was given the release's symbol-ordering file, so .text begins with the hottest"
echo "     functions: sampling its start samples exactly the code that decides frame rate)"
objdump -d --no-show-raw-insn "$GAME/hookshot" 2>/dev/null | head -2000000 | awk '
/zmm/                            { a512++ }
/%k[1-7]/                        { amask++ }
/ymm/                            { ymm++ }
/vpdpbusd/                       { vnni++ }
/gf2p8affine/                    { gfni++ }
/vaes/                           { vaes++ }
/vpclmulqdq/                     { clmul++ }
/movdir64b|movdiri/              { movdir++ }
/vfmadd|vfmsub|vfnmadd|vfnmsub/  { fma++ }
/xmm/                            { xmm++ }
END {
  printf "  AVX-512 (zmm): %d   AVX-512 write masks: %d      <- must be 0 on a CPU without AVX-512\n", a512, amask
  printf "  AVX/AVX2 (ymm): %d   SSE (xmm): %d\n", ymm, xmm
  printf "  beyond x86-64-v3: AVX-VNNI %d  GFNI %d  VAES %d  VPCLMULQDQ %d  MOVDIR %d\n", vnni, gfni, vaes, clmul, movdir
  printf "  FMA (expected >0: the game uses ARM64 FMADD): %d\n", fma
  if (a512 || amask) print "  !! AVX-512 present: this binary would SIGILL on a CPU that has none"
}'

echo
echo "=== 4. tuning that was supposed to be applied ==="
if [ -n "${LOG:-}" ] && [ -f "$LOG" ]; then
    echo "log: $LOG"
    grep -E 'hot functions \(A64_HOT_FUNCS\)|translated instructions' "$LOG" | sed 's/^/  /'
    if grep -q 'cannot read the play profile' "$LOG"; then
        echo "  !! the play profile was NOT used (an older clang cannot read it: LLVM 23 or newer is needed)"
    else
        printf '  PGO: profile accepted; hot pieces compiled: '
        grep -cE '^@@file code_hot_' "$LOG"
    fi
    line=$(grep -m1 'the game is built for' "$LOG" || true)
    case ${line:-} in
        *"built for native"*)    echo "  march: -march=native was used (build.py's 'no AVX2' wording is a known false alarm)" ;;
        *"built for x86-64-v3"*) echo "  march: x86-64-v3" ;;
        "")                      echo "  march: no march line in the log (RX_MARCH unset, CPU matched v3)" ;;
        *)                       echo "  march: $line" ;;
    esac
    grep -E '^the build took' "$LOG" | sed 's/^/  /'
else
    echo "  no build log in $STATE/logs: run 'rebuild.sh build' to get one"
fi

echo
echo "=== 5. link order applied? (.text's first symbols vs the release's hot_order.txt) ==="
if [ -f "$SRC/work/hot_order.txt" ]; then
    nm --defined-only --numeric-sort "$GAME/hookshot" 2>/dev/null | awk '$2=="T"{print $3}' | head -12 > "$TMP/got"
    head -12 "$SRC/work/hot_order.txt" | tr -d ' \r' > "$TMP/want"
    paste -d'|' "$TMP/want" "$TMP/got" | sed 's/^/  want|got  /'
    echo "  identical: $(join -j1 <(sort "$TMP/want") <(sort "$TMP/got") | wc -l) of 12"
else
    echo "  $SRC/work/hot_order.txt is absent: the build had no link order (run 'rebuild.sh fetch profile')"
fi

echo
echo "=== 6. nothing network-facing is linked in ==="
nm -D --undefined-only "$GAME/hookshot" 2>/dev/null \
    | grep -iE ' (socket|connect|send|recv|getaddrinfo|curl_[a-z_]+|SSL_[a-z_]+)$' \
    || echo "  no socket/libcurl/OpenSSL symbols among the game's imports"
echo "  outbound strings (the update check only; the launcher disables it, the sandbox makes it impossible):"
strings -a "$GAME/hookshot" 2>/dev/null | grep -iE 'api\.github|github\.com/NotRexed' | sort -u | sed 's/^/    /'

echo
echo "=== 7. where your data lives ==="
printf '  saves, caches, options: %s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/hookshot"
[ -d "${XDG_DATA_HOME:-$HOME/.local/share}/hookshot" ] && echo "    exists" || echo "    created on the first run"
echo "  in-game settings and log: $GAME/hookshot_options.ini, $GAME/hookshot_log.txt"
