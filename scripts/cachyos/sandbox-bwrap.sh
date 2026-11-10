#!/usr/bin/env bash
# OPTIONAL stronger isolation for playing: run the game inside a bubblewrap sandbox.
#
#   bash sandbox-bwrap.sh --dry-run     print the exact command, run nothing
#   bash sandbox-bwrap.sh               play inside the sandbox (further args go to the game)
#
# What the sandbox does:
#   - the whole host filesystem, your home directory included, is READ-ONLY;
#   - writable: the game folder (log, options, shader caches), the save folder
#     ($XDG_DATA_HOME/hookshot) and $XDG_RUNTIME_DIR (Wayland / PipeWire / X11 sockets);
#   - no network namespace: the game cannot reach the network at all (it needs none), which makes
#     the update check impossible rather than merely disabled;
#   - fresh user / pid / ipc namespaces.
#
# Honest limits:
#   - /dev stays bound as it is, because the NVIDIA driver needs /dev/nvidia* and /dev/dri and
#     controllers need /dev/input and /run/udev. Device access is therefore not restricted; what this
#     buys is filesystem and network isolation.
#   - the isolation itself is verified (a stub program inside shows: DNS blocked, TCP blocked, only
#     loopback, / and $HOME and /etc read-only, game folder and save folder writable, LD_PRELOAD
#     dropped). What is NOT verified is this game running inside it: if a sandboxed run shows a black
#     window, no sound or no controller, use hookshot-launch instead. The sandbox is optional.
set -euo pipefail

CONF=${HOOKSHOT_LOCAL_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/hookshot/local-build.conf}
GAME=${HOOKSHOT_GAME_DIR:-}
if [ -z "$GAME" ] && [ -f "$CONF" ]; then GAME=$(awk -F= '/^GAME=/{print $2}' "$CONF" | head -1); fi
GAME=${GAME:-$HOME/Games/Hookshot}
GAME=${GAME/#\~/$HOME}
SAVE="${XDG_DATA_HOME:-$HOME/.local/share}/hookshot"
RUN=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

dry=0
if [[ "${1:-}" == "--dry-run" ]]; then dry=1; shift; fi

[[ -x "$GAME/hookshot" ]] || { echo "sandbox-bwrap.sh: no built game in $GAME" >&2; exit 1; }
command -v bwrap >/dev/null || { echo "sandbox-bwrap.sh: bwrap is not installed (bubblewrap package)" >&2; exit 1; }

args=(
    --ro-bind / /                       # everything read-only, home included
    --dev-bind /dev /dev                # /dev/dri and /dev/nvidia* for the GPU, /dev/input for pads
    --proc /proc
    --tmpfs /tmp                        # a private /tmp, so nothing the game writes there is shared
)
mkdir -p "$SAVE"
# The binds come after --tmpfs /tmp on purpose: bwrap applies the arguments in order, so a game folder
# (or a save folder) that lives under /tmp is still visible instead of hidden by that tmpfs.
args+=(--bind "$GAME" "$GAME")          # hookshot_log.txt, hookshot_options.ini, shader caches
args+=(--bind "$SAVE" "$SAVE")          # saves, caches, mouse_sens.txt (host/hos_main.c)
args+=(--bind "$RUN" "$RUN")            # Wayland / PipeWire sockets
# Host sockets that would still be reachable through the read-only bind above (a read-only mount does
# not block connect() to a unix socket): systemd-resolved, which would answer DNS queries for the
# sandboxed process, and the system D-Bus. /run/udev and /run/user stay: controllers and the display
# and audio sockets need them.
args+=(--tmpfs /run/systemd/resolve --tmpfs /run/dbus)
[[ -d /tmp/.X11-unix ]] && args+=(--ro-bind /tmp/.X11-unix /tmp/.X11-unix)
[[ -n ${XAUTHORITY:-} && -f ${XAUTHORITY:-} ]] && args+=(--ro-bind "$XAUTHORITY" "$XAUTHORITY")

args+=(
    --unshare-user --unshare-ipc --unshare-pid --unshare-net
    --unsetenv LD_PRELOAD --unsetenv LD_LIBRARY_PATH    # the launcher does this too; bwrap would inherit them
    --setenv HOOKSHOT_NO_UPDATE_CHECK 1
    --setenv PULSE_SERVER "unix:$RUN/pulse"
    --chdir "$GAME"
    -- ./hookshot "$@"
)

if (( dry )); then
    printf 'bwrap\n'; printf '  %q\n' "${args[@]}"
    exit 0
fi
exec bwrap "${args[@]}"
