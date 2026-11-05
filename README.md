# cs2-docker

Counter-Strike 2 in a container on a CPU-only machine: Steam Runtime 4 base,
[gbe_fork](https://github.com/Detanup01/gbe_fork) as the Steam client, and a
patched Mesa lavapipe as the Vulkan driver.

The two native dependencies are built in their own repos and pulled from their
latest GitHub release at image build time (each verified against the release's
`SHA256SUMS`):

- [gbe-steamrt](https://github.com/personcopperfine/gbe-steamrt): gbe_fork built in steamrt4
- [lavapipe-steamrt](https://github.com/personcopperfine/lavapipe-steamrt): lavapipe + CS2 patches built in steamrt4

The image is published to `ghcr.io/personcopperfine/cs2-docker` by
`.github/workflows/image.yml` on every push to `client/`, weekly, and on demand.

## Usage

```bash
podman pull ghcr.io/personcopperfine/cs2-docker:latest

# headless check: boot CS2 under Xvfb and quit
podman run --rm --network=host \
    -v cs2-home:/home/steam -v cs2-shadercache:/cache \
    ghcr.io/personcopperfine/cs2-docker:latest smoke-test

# play/run on an X display (extra args are passed to cs2.sh)
podman run --rm --network=host \
    -e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v cs2-home:/home/steam -v cs2-shadercache:/cache \
    ghcr.io/personcopperfine/cs2-docker:latest
```

The game itself is not in the image: `entrypoint.sh` installs or updates it
with steamcmd (anonymous login, CS2 is free-to-play) into the `cs2-home`
volume. `STEAM_USERNAME` / `STEAM_PASSWORD` select a real account instead.
`/app/BUILDINFO.gbe` and `/app/BUILDINFO.lavapipe` record which dependency
releases an image contains.

## Building locally

```bash
podman build -t cs2-docker client/
# a specific dependency release instead of the latest:
podman build -t cs2-docker \
    --build-arg GBE_RELEASE=download/release-2026_09_27 \
    --build-arg LAVAPIPE_RELEASE=download/mesa-26.3.0-rc3 client/
```
