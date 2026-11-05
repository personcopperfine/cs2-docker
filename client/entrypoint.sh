#!/bin/bash
# =============================================================================
# CS2 container entrypoint (runs as user "steam")
#
#   1. Installs/updates the game files via steamcmd when needed, or uses a
#      mounted library. CS2 is free-to-play, so with no credentials set the
#      download runs under an anonymous Steam login; STEAM_USERNAME /
#      STEAM_PASSWORD can be exported to use a real account instead.
#   2. Sets up the Goldberg Emulator Steam client replacement (setup_gbe.sh).
#   3. Launches CS2:            ./cs2.sh -steam [extra args...]
#      Smoke test:              entrypoint.sh smoke-test
# =============================================================================
set -euo pipefail

# Exported so setup_gbe.sh (which reads $INSTALL_DIR for the bundled
# libsteam_api.so) sees the discovered location, not its own default.
export INSTALL_DIR="${INSTALL_DIR:-/usr/local/games}"
export CS2_SH="$INSTALL_DIR/game/cs2.sh"
export APP_ID=730

# Valve renamed the install dir from "Counter-Strike Global Offensive" to
# "Counter-Strike"; if the expected path is missing, fall back to a child of
# $INSTALL_DIR (the build installs into it and Valve creates its canonical
# subdirectory inside) or a sibling under steamapps/common (covers mounted
# Steam libraries).
if [ ! -f "$CS2_SH" ]; then
    for cand in "$HOME"/games/game/cs2.sh "$INSTALL_DIR"/*/game/cs2.sh "${INSTALL_DIR%/*}"/*/game/cs2.sh; do
        if [ -f "$cand" ]; then
            INSTALL_DIR=$(dirname "$(dirname "$cand")")
            CS2_SH="$INSTALL_DIR/game/cs2.sh"
            break
        fi
    done
fi

log() { echo "[cs2-docker] $*" >&2; }

# --- 1. game files ----------------------------------------------------------

# Validate at most once a week: record the last successful validate in a
# dotfile inside the install dir and skip steamcmd while it's fresh.
DATE_FILE="$INSTALL_DIR/.cs2-docker-date"
MAX_AGE_SECS="${MAX_AGE_SECS:-$((7 * 24 * 3600))}"

need_validate() {
    [ ! -f "$DATE_FILE" ] && return 0
    local age
    age=$(( $(date +%s) - $(stat -c %Y "$DATE_FILE") ))
    [ "$age" -gt "$MAX_AGE_SECS" ]
}

run_steamcmd() {
    # $1: extra app_update args (e.g. "validate"); empty = plain update/install.
    local extra="${1:-}"
    # CS2 is free-to-play, so an anonymous login can download it. Use real
    # credentials when provided (e.g. for a library already tied to an account).
    if [ -n "${STEAM_USERNAME:-}" ] && [ -n "${STEAM_PASSWORD:-}" ]; then
        local login_args=(+login "$STEAM_USERNAME" "$STEAM_PASSWORD")
        log "Installing/updating CS2 (app $APP_ID) via steamcmd to '${INSTALL_DIR}' as '$STEAM_USERNAME'..."
    else
        local login_args=(+login anonymous)
        log "Installing/updating CS2 (app $APP_ID) via steamcmd to '${INSTALL_DIR}' (anonymous, F2P)..."
    fi
    cd "$HOME"
    # one retry for transient Steam-side stalls at startup.
    local attempt
    for attempt in 1 2; do
        steamcmd \
            +force_install_dir "$INSTALL_DIR" \
            +@sSteamCmdForcePlatformType linux \
            "${login_args[@]}" \
            +@bClientTryRequestManifestWithoutCode 1 \
            +app_update "${APP_ID}" ${extra} +quit </dev/null && return 0
        log "steamcmd attempt $attempt failed, retrying..."
    done
    return 1
}

if [ ! -f "$CS2_SH" ]; then
    # No game files yet: must install.
    if ! run_steamcmd "validate"; then
        log "ERROR: game not found at $INSTALL_DIR and steamcmd install failed."
        log "Either mount a directory containing the game, or set"
        log "STEAM_USERNAME/STEAM_PASSWORD and retry."
        exit 1
    fi
    date +%s > "$DATE_FILE"
elif need_validate; then
    if ! run_steamcmd "validate"; then
        log "WARNING: steamcmd validate/update failed; continuing with existing game files."
    else
        date +%s > "$DATE_FILE"
    fi
else
    log "Game files present and .cs2-docker-date is fresh (< 7 days); skipping steamcmd validate."
fi

if [ ! -f "$CS2_SH" ]; then
    log "ERROR: $CS2_SH not found after install."
    exit 1
fi

# shader-cache QOL: point the game's shadercache dir at the /cache volume.
if [ -n "${SHADER_CACHE:-}" ] && [ -d "$INSTALL_DIR/game/csgo" ]; then
    if [ ! -e "$INSTALL_DIR/game/csgo/shadercache" ]; then
        mkdir -p "$INSTALL_DIR/game/csgo"
        ln -sfn "$SHADER_CACHE" "$INSTALL_DIR/game/csgo/shadercache"
    fi
fi

# --- 2. Steam emulator setup -------------------------------------------------
/app/setup_gbe.sh

# --- 2.5 render device selection ---------------------------------------------
# (The old cs2_lvp_gpu implicit Vulkan layer was retired in favour of the
# patched lavapipe fork; there is no per-device layer switch any more.)

# --- 2.6 default video quality preset ----------------------------------------
# CS2 stores video settings in game/csgo/cfg/cs2_video.txt and regenerates that
# file from its own hardware autoconfig whenever it is missing or its
# "Version"/"VendorID"/"DeviceID" keys no longer match the running device.
# The file is seeded from the game's shipped low-tier defaults
# (video_defaults_0.txt inside pak01_dir.vpk) plus the current GPU identity, so
# a fresh container boots at a fixed quality instead of the auto-detected one.
# A user-edited cs2_video.txt is left alone unless CS2_VIDEO_FORCE=1.
# Running-device identity for cs2_video.txt: CS2 regenerates the whole file via
# its hardware autoconfig (which re-enables HDR) whenever these keys mismatch,
# so they must describe what the game will actually see. The fork runs on
# llvmpipe = PCI vendor 0x10005 (65541), device 0; a detected NVIDIA card wins
# for --gpus runs.
vendor_id=65541; device_id=0
dev_info="$(nvidia-smi --query-gpu=pci.device_id --format=csv,noheader 2>/dev/null || true)"
dev_info="${dev_info%%$'\n'*}"   # first GPU only, no SIGPIPE-prone pipe
dev_info="${dev_info//[[:space:]]/}"
if [ -n "$dev_info" ]; then
    vendor_id=$(( dev_info & 0xFFFF ))
    device_id=$(( dev_info >> 16 ))
fi

# Always seed at the low preset (lavapipe throughput).
preset=0
if [ -n "${preset:-}" ]; then
    CFG_DIR="$INSTALL_DIR/game/csgo/cfg"
    VIDEO_CFG="$CFG_DIR/cs2_video.txt"
    if [ -f "$VIDEO_CFG" ]; then
        log "cs2_video.txt already exists; leaving it."
    elif [ ! -f "/app/steam_settings/video_defaults/video_defaults_${preset}.txt" ]; then
        log "WARNING: video_defaults_${preset}.txt missing from the image; skipping preset."
    else
        mkdir -p "$CFG_DIR"
        {
            echo '"config"'
            echo '{'
            printf '\t"Version"\t\t\t"16"\n'
            printf '\t"VendorID"\t\t\t"%d"\n' "$vendor_id"
            printf '\t"DeviceID"\t\t\t"%d"\n' "$device_id"
            # the shipped defaults are themselves a "config" block with CRLF
            # line endings; strip the CRs and its outer braces so the keys
            # land inside our single block
            tr -d '\r' < "/app/steam_settings/video_defaults/video_defaults_${preset}.txt" \
                | sed -e '/^[[:space:]]*{/d' -e '/^[[:space:]]*}/d' -e '/^"config"/d'
        } > "$VIDEO_CFG"
        log "seeded low preset into $VIDEO_CFG (vendor=$vendor_id device=$device_id)."
    fi
fi

# --- 2.7 portable save dir seeding -------------------------------------------
# setup_gbe.sh set [user::saves] local_save_path (GSE_SAVE_DIR, default /app):
# the emu stores everything under <save>/<appid>/local/... and ignores the
# global "GSE Saves" folder. Seed the video config into that location so a
# fresh boot does not depend on a stale runtime autoconfig: prefer the volume's
# existing GSE Saves config, then the install-dir one the preset logic wrote.
SAVE_DIR="${GSE_SAVE_DIR:-/app}"
SAVE_VCFG="$SAVE_DIR/$APP_ID/local/cfg/cs2_video.txt"
if [ ! -f "$SAVE_VCFG" ]; then
    mkdir -p "$(dirname "$SAVE_VCFG")"
    # The seed MUST use the game's own "video.cfg"-header format with its full
    # key set: a "config"-header or partial file makes CS2 run its hardware
    # autoconfig at boot, and that autoconfig re-enables HDR -> black screen.
    for src in "$HOME/.local/share/GSE Saves/730/local/cfg/cs2_video.txt" \
               /app/steam_settings/cs2_video.default.txt; do
        if [ -f "$src" ]; then
            cp "$src" "$SAVE_VCFG"
            log "seeded $SAVE_VCFG from $src"
            break
        fi
    done
fi
# Stamp the running-device identity onto the seeded config: a stale identity
# (e.g. the NVIDIA ids a GPU run wrote into the install-dir cfg) makes CS2
# autoconfig on boot, and that autoconfig re-enables HDR -> black screen.
if [ -f "$SAVE_VCFG" ]; then
    sed -i -E "s/(\"VendorID\"[[:space:]]+\")[0-9]+(\")/\1${vendor_id}\2/;
               s/(\"DeviceID\"[[:space:]]+\")[0-9]+(\")/\1${device_id}\2/" "$SAVE_VCFG" \
        && log "device identity stamped into $SAVE_VCFG (vendor=$vendor_id device=$device_id)"
fi

# XXX: HDR and MSAA render black on the lavapipe fork; the low preset ships
# both off, so no runtime guard is needed.

# llvmpipe thread count: default to the host's CPU count, keep any explicit override.
export LP_NUM_THREADS="${LP_NUM_THREADS:-$(nproc)}"

# --- 3. launch ----------------------------------------------------------------
cd "$INSTALL_DIR/game"

# CS2 resolves audio symbols (snd_pcm_*, pa_*) through libsteam_api.so: Valve's
# original library re-exports ALSA/PulseAudio, the gbe emu does not. Preload the
# system libraries so those symbols resolve from the global scope.
export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libfreetype.so:/usr/lib/x86_64-linux-gnu/libasound.so:/usr/lib/x86_64-linux-gnu/libpulse.so${LD_PRELOAD:+:$LD_PRELOAD}"

case "${1:-}" in
    smoke-test)
        # Boot under a virtual X server and tell the game to quit.
        # Verifies emu + runtime wiring without needing a real display/GPU.
        shift
        log "Smoke test: booting CS2 under Xvfb (timeout ${SMOKE_TIMEOUT:-90}s)..."
        set +e
        # Xvfb must NOT inherit LD_LIBRARY_PATH. cs2.sh re-prepends the game's
        # bundled lib dir for the game process itself, but that dir ships an
        # old libfreetype.so.6 which breaks Xvfb (libharfbuzz needs
        # FT_Get_Color_Glyph_Layer, freetype >= 2.9). Without a working X
        # server lavapipe enumerates zero Vulkan devices and CS2 hangs.
        env -u LD_LIBRARY_PATH timeout "${SMOKE_TIMEOUT:-90}" xvfb-run -a ./cs2.sh -steam +quit 2>&1 | tail -40
        rc=$?
        set -e
        if [ "$rc" -eq 124 ]; then
            log "Smoke test: game did not exit on its own (timeout) - it may have booted to the menu."
        else
            log "Smoke test finished with exit code $rc."
        fi
        exit 0
        ;;
    *)
        GAME_ARGS=(-steam)
        [ -n "${CS2_ARGS:-}" ] && GAME_ARGS+=(${CS2_ARGS})
        GAME_ARGS+=("$@")
        case " ${GAME_ARGS[*]} " in
            *" -condebug "*) ;;
            *) GAME_ARGS+=(-condebug -conclearlog) ;;
        esac
        CONLOG="$INSTALL_DIR/game/csgo/console.log"
        if [ "${CS2_TAIL_CONSOLE:-1}" = "0" ]; then
            exec ./cs2.sh "${GAME_ARGS[@]}"
        fi
        rm -f "$CONLOG"
        ./cs2.sh "${GAME_ARGS[@]}" &
        GPID=$!
        trap 'kill -TERM $GPID 2>/dev/null' TERM INT
        for _ in $(seq 1 30); do
            [ -f "$CONLOG" ] && break
            kill -0 "$GPID" 2>/dev/null || break
            sleep 1
        done
        tail -n +1 -F "$CONLOG" 2>/dev/null &
        TPID=$!
        log "tailing $CONLOG (game pid $GPID; disable with CS2_TAIL_CONSOLE=0)"
        RC=0
        while kill -0 "$GPID" 2>/dev/null; do
            wait "$GPID" || RC=$?
        done
        trap - TERM INT
        kill "$TPID" 2>/dev/null
        wait "$TPID" 2>/dev/null
        log "game exited with code $RC"
        exit "$RC"
        ;;
esac
