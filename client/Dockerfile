# ---------------------------------------------------------------------------
# Stage 1: prebuilt gbe (Steam client emulator) and lavapipe (Vulkan software
# ICD + cs2 patch series), both built in steamrt4 by GitHub CI:
#   https://github.com/personcopperfine/gbe-steamrt
#   https://github.com/personcopperfine/lavapipe-steamrt
# Default is the latest release of each; to build a specific one pass e.g.
#   --build-arg GBE_RELEASE=download/release-2026_09_27
#   --build-arg LAVAPIPE_RELEASE=download/mesa-26.3.0-rc3
# The tarball is verified against that release's SHA256SUMS; ADD re-fetches the
# sums on every build, so a new release (or a rebuild of the same tag) busts the
# cache. Each BUILDINFO is kept in the image as /app/BUILDINFO.<name>.
# ---------------------------------------------------------------------------
FROM registry.gitlab.steamos.cloud/steamrt/steamrt4/sdk AS prebuilt
ARG GBE_RELEASE=latest/download
ARG LAVAPIPE_RELEASE=latest/download
ADD https://github.com/personcopperfine/gbe-steamrt/releases/${GBE_RELEASE}/SHA256SUMS /tmp/gbe/SHA256SUMS
ADD https://github.com/personcopperfine/lavapipe-steamrt/releases/${LAVAPIPE_RELEASE}/SHA256SUMS /tmp/lavapipe/SHA256SUMS
RUN fetch() { \
        mkdir -p "/artifacts/$1" \
        && curl -fsSL -o "/tmp/$1/$3" "https://github.com/personcopperfine/$1-steamrt/releases/$2/$3" \
        && (cd "/tmp/$1" && sha256sum -c SHA256SUMS) \
        && tar -xzf "/tmp/$1/$3" -C "/artifacts/$1" \
        && cat "/artifacts/$1/BUILDINFO"; \
    } \
    && fetch gbe "$GBE_RELEASE" gbe-linux-x64.tar.gz \
    && fetch lavapipe "$LAVAPIPE_RELEASE" lavapipe-x86_64.tar.gz

### SteamCMD Install ###
FROM registry.gitlab.steamos.cloud/steamrt/steamrt4/sdk AS steamcmd
# stage https://github.com/steamcmd/docker under MIT
#
# MIT License
#
# Copyright (c) 2020 Jona Koudijs
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

RUN useradd -m -s /bin/bash steam

# FIXME: still building as root (the cs2-home volume is mounted over /home/steam)
ENV USER steam
ENV HOME /home/steam
ARG GAME_DIR="${HOME}/games/"

WORKDIR $HOME

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN echo steam steam/question select "I AGREE" | debconf-set-selections \
    && echo steam steam/license note '' | debconf-set-selections

RUN \
    DEBIAN_FRONTEND=noninteractive apt-get update \
    && apt-get install --yes --no-install-recommends --no-install-suggests steamcmd \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN ln -s /usr/games/steamcmd /usr/bin/steamcmd

RUN steamcmd +force_install_dir "${GAME_DIR}" +quit \
    && rm -rf $HOME/Steam/package $HOME/package

# sdk64 stays a real directory: setup_gbe.sh installs the emulator's
# libsteam_api.so/steamclient.so there, and a link into steamcmd's linux64
# would overwrite steamcmd's own steamclient.so.
RUN mkdir -p $HOME/.steam/sdk64 \
    && ln -s $HOME/.local/share/Steam/steamcmd/linux32 $HOME/.steam/sdk32 \
    && ln -s $HOME/.steam/sdk32/steamclient.so $HOME/.steam/sdk32/steamservice.so \
    && chown -R steam:steam $HOME

ENTRYPOINT ["steamcmd"]
CMD ["+help", "+quit"]

# Stage 2: runtime image (game files are installed at runtime by entrypoint.sh)
FROM steamcmd AS gameinstall

ENV APP_GAME "730"

COPY --from=prebuilt /artifacts/gbe/libsteam_api.so /artifacts/gbe/steamclient.so /artifacts/gbe/libsteamnetworkingsockets.so /artifacts/gbe/generate_interfaces /app/
COPY --from=prebuilt /artifacts/gbe/BUILDINFO /app/BUILDINFO.gbe
COPY --from=prebuilt /artifacts/lavapipe/BUILDINFO /app/BUILDINFO.lavapipe

COPY --from=prebuilt /artifacts/lavapipe/libvulkan_lvp.so /usr/local/lib/x86_64-linux-gnu/libvulkan_lvp.so
COPY --from=prebuilt /artifacts/lavapipe/lvp_icd.x86_64.json /usr/share/vulkan/icd.d/lvp_cs2_fork.x86_64.json
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && apt-get install --yes --no-install-recommends --no-install-suggests libllvm22 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
RUN ldd /usr/local/lib/x86_64-linux-gnu/libvulkan_lvp.so | grep -q 'libLLVM.so.22' \
    && ! ldd /usr/local/lib/x86_64-linux-gnu/libvulkan_lvp.so | grep 'not found'
# lavapipe uses LLVM's C++ internals: refuse a different LLVM major.minor than it
# was built against; a point-release/packaging difference only warns.
RUN built="$(sed -n 's/^llvm=//p' /app/BUILDINFO.lavapipe)" \
    && have="$(dpkg-query -W -f '${Version}' libllvm22)" \
    && mm() { echo "$1" | sed -E 's/^[0-9]+://; s/^([0-9]+\.[0-9]+).*/\1/'; } \
    && echo "libllvm22: lavapipe built against $built, image has $have" \
    && { [ "$(mm "$built")" = "$(mm "$have")" ] \
         || { echo "FATAL: LLVM $(mm "$have") != $(mm "$built") (lavapipe build)"; exit 1; }; } \
    && { [ "$built" = "$have" ] || echo "WARNING: libllvm22 package differs from the lavapipe build"; }

COPY src/steam_settings/ /app/steam_settings/

ENV PATH="/usr/local/bin:$PATH"
ENV PIPEWIRE_RUNTIME_DIR "/tmp"

ENV SHADER_CACHE "/cache"
ENV DXVK_STATE_CACHE_PATH "${SHADER_CACHE}"
ENV MESA_SHADER_CACHE_DIR "${SHADER_CACHE}"
ENV XDG_CACHE_HOME "${SHADER_CACHE}"
VOLUME [ "${SHADER_CACHE}" ]
RUN mkdir -p "${SHADER_CACHE}/vulkan"

ENV GALLIVM_PERF "brilinear"

# cs2.sh exits unless the runtime codename is "sniper".
RUN sed -i 's/^VERSION_CODENAME=.*/VERSION_CODENAME=sniper/' /etc/os-release

COPY entrypoint.sh setup_gbe.sh /app/
RUN chmod 755 /app/generate_interfaces /app/entrypoint.sh /app/setup_gbe.sh \
    && chown -R steam:steam /app /home/steam

ENTRYPOINT ["/app/entrypoint.sh"]
