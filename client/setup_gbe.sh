#!/bin/bash
# =============================================================================
# GBE (Goldberg Emulator) setup, runs as user "steam"
#
#   * Valve Linux games resolve libsteam_api.so to ~/.steam/sdk64/libsteam_api.so,
#     so the emu is installed there together with its steam_settings folder.
#   * steam_interfaces.txt is generated (once) from the game's ORIGINAL
#     libsteam_api.so via the generate_interfaces tool; the original is backed
#     up before it gets replaced.
# =============================================================================
set -euo pipefail

SDK64="$HOME/.steam/sdk64"
SETTINGS="$SDK64/steam_settings"
BACKUP="$HOME/.steam/gbe_orig_libsteam_api.so"
EMU=/app/libsteam_api.so
GAME_LIB="${GAME_DIR:-${INSTALL_DIR:-/usr/local/games}}/game/bin/linuxsteamrt64/libsteam_api.so"

log() { echo "[gbe] $*" >&2; }

mkdir -p "$SETTINGS"

# 1. config files (never overwrite user-modified ones)
for f in /app/steam_settings/*; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    [ -e "$SETTINGS/$b" ] || cp "$f" "$SETTINGS/$b"
done

SAVE_DIR="${GSE_SAVE_DIR:-/app}"
UCFG="$SETTINGS/configs.user.ini"
touch "$UCFG"
if grep -qE '^[[:space:]]*local_save_path[[:space:]]*=' "$UCFG"; then
    sed -i -E "s|^[[:space:]]*local_save_path[[:space:]]*=.*|local_save_path=$SAVE_DIR|" "$UCFG"
else
    printf '\n[user::saves]\nlocal_save_path=%s\n' "$SAVE_DIR" >> "$UCFG"
fi
log "portable saves active: local_save_path=$SAVE_DIR (in $UCFG)"

# 2. back up the game's original libsteam_api.so (needed to generate interfaces)
if [ ! -f "$BACKUP" ] && [ -e "$GAME_LIB" ]; then
    R="$(readlink -f "$GAME_LIB")"
    if [ -f "$R" ] && ! cmp -s "$R" "$EMU"; then
        cp "$R" "$BACKUP"
        log "backed up original libsteam_api.so -> $BACKUP"
    fi
fi

# 3. figure out the original (non-emu) library, if any
ORIG=""
[ -f "$BACKUP" ] && ORIG="$BACKUP"
if [ -z "$ORIG" ] && [ -e "$GAME_LIB" ]; then
    R="$(readlink -f "$GAME_LIB")"
    if [ -f "$R" ] && ! cmp -s "$R" "$EMU"; then
        ORIG="$R"
    fi
fi

# 4. generate steam_interfaces.txt from the original library (once)
if [ ! -f "$SETTINGS/steam_interfaces.txt" ]; then
    if [ -n "$ORIG" ]; then
        log "generating steam_interfaces.txt from $ORIG"
        rm -f /tmp/steam_interfaces.txt
        ( cd /tmp && /app/generate_interfaces "$ORIG" )
        mv /tmp/steam_interfaces.txt "$SETTINGS/steam_interfaces.txt"
    fi
fi
if [ ! -f "$SETTINGS/steam_interfaces.txt" ]; then
    log "WARNING: original libsteam_api.so not available, using bundled fallback interface list."
    cp /app/steam_settings/steam_interfaces.fallback.txt "$SETTINGS/steam_interfaces.txt"
fi

# 5. if the game links against libsteamnetworkingsockets, provide the emu's copy
if [ -n "$ORIG" ] && objdump -p "$ORIG" 2>/dev/null | grep NEEDED | grep -q libsteamnetworkingsockets; then
    BIN_DIR="$(dirname "$GAME_LIB")"
    cp -f /app/libsteamnetworkingsockets.so "$BIN_DIR/"
    log "installed emu libsteamnetworkingsockets.so -> $BIN_DIR"
fi

# 6. install the emulator where CS2 resolves libsteam_api.so from, together
#    with its companion steamclient.so (the emu dlopens it from the same dir;
#    without it SteamAPI_Init() fails).
cp -f "$EMU" "$SDK64/libsteam_api.so"
cp -f /app/steamclient.so "$SDK64/steamclient.so"
log "emulator installed at $SDK64/libsteam_api.so (settings: $SETTINGS)"

# 7. CS2 also ships its OWN libsteam_api.so in game/bin/linuxsteamrt64, and the
#    loader prefers it over ~/.steam/sdk64 — replace that one with the emu too
#    (the original is preserved in $BACKUP for interface generation).
if [ -e "$GAME_LIB" ]; then
    R="$(readlink -f "$GAME_LIB")"
    if [ -f "$R" ] && ! cmp -s "$R" "$EMU"; then
        cp -f "$EMU" "$R"
        log "replaced bundled $R with the emulator (original kept at $BACKUP)"
    fi
fi

# 8. the emu looks for its steam_settings folder next to the LOADED .so, and
#    after step 7 that is the game's own bin dir, not sdk64. Link it there or
#    configs.user.ini (incl. [user::saves] local_save_path) is never read.
if [ -e "$GAME_LIB" ]; then
    BIN_DIR="$(dirname "$GAME_LIB")"
    if [ "$(readlink "$BIN_DIR/steam_settings" 2>/dev/null)" != "$SETTINGS" ]; then
        ln -sfn "$SETTINGS" "$BIN_DIR/steam_settings"
        log "linked $BIN_DIR/steam_settings -> $SETTINGS"
    fi
fi
