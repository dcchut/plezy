#!/usr/bin/env bash
#
# compile.sh - build a Plezy .deb on Ubuntu inside a throwaway Ubuntu 24.04
# distrobox, mirroring the Linux job in .github/workflows/build.yml.
#
# Why a container: the pinned prebuilt libmpv links Ubuntu 24.04's libraries
# (e.g. libdisplay-info.so.1), which newer releases no longer ship. The finished
# .deb bundles those libraries, so it still installs and runs on newer Ubuntu.
#
# Usage: ./compile.sh [--out DIR] [--keep] [--container NAME]
#
#   --out DIR         where to write the .deb (default: <repo>/dist)
#   --keep            skip cleanup: keep the container, toolchain and build tree
#                     (faster rebuilds; use it to debug a failed build)
#   --container NAME  distrobox container name (default: plezy-build)
#
# Without --keep, cleanup runs whether the build succeeds or fails. It removes
# the container, the ubuntu:24.04 image (only if this script pulled it), the
# toolchain cache, and the generated build/, .dart_tool/, libmpv-prefix/ and
# linux/packaging/icons/ in the repo. The .deb in --out is kept.
#
# Host requirements: x86_64 Ubuntu, sudo (only to install distrobox/podman if
# missing), and the repo checked out somewhere under $HOME (distrobox shares
# $HOME with the container).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="$REPO/.github/workflows/build.yml"
WORK="${PLEZY_COMPILE_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/plezy-compile}"
IMAGE="docker.io/library/ubuntu:24.04"
CONTAINER="plezy-build"
OUT="$REPO/dist"
KEEP=0

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

# ── Stage 2: runs inside the container ─────────────────────────────────────
inside() {
    local out="$1"

    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${VERSION_ID:-}" == "24.04" ]] || die "expected Ubuntu 24.04 inside the container, got ${VERSION_ID:-unknown}"

    cd "$REPO"

    # Same package list CI installs, read from the workflow so it tracks upstream.
    local apt_packages flutter_version
    apt_packages="$(awk '/^  LINUX_APT_PACKAGES: *>/ {f=1; next} f && /^    / {print; next} f {exit}' "$WORKFLOW" | xargs)"
    [[ "$apt_packages" == *libgtk-3-dev* ]] || die "could not read LINUX_APT_PACKAGES from $WORKFLOW"
    flutter_version="$(sed -n 's/^[[:space:]]*FLUTTER_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' "$WORKFLOW" | head -1)"
    [[ -n "$flutter_version" ]] || die "could not read FLUTTER_VERSION from $WORKFLOW"

    log "Installing build dependencies (apt)"
    export DEBIAN_FRONTEND=noninteractive
    sudo -E apt-get update
    # shellcheck disable=SC2086  # word-splitting the package list is intended
    sudo -E apt-get install -y $apt_packages \
        openjdk-21-jdk git curl ca-certificates unzip xz-utils zip zstd python3 file

    # sentry_flutter -> jni registers a native plugin whose CMake needs a JDK.
    export JAVA_HOME="/usr/lib/jvm/java-21-openjdk-amd64"
    [[ -d "$JAVA_HOME" ]] || die "JDK not found at $JAVA_HOME"

    if ! command -v fpm >/dev/null || [[ "$(fpm --version 2>/dev/null)" != "1.17.0" ]]; then
        log "Installing fpm"
        sudo gem install fpm --version 1.17.0 --no-document
    fi

    log "Setting up Flutter $flutter_version"
    local flutter_dir="$WORK/flutter"
    if [[ -d "$flutter_dir/.git" ]] && [[ "$(git -C "$flutter_dir" describe --tags --exact-match 2>/dev/null)" == "$flutter_version" ]]; then
        echo "Reusing $flutter_dir"
    else
        rm -rf "$flutter_dir"
        git clone --depth 1 --branch "$flutter_version" https://github.com/flutter/flutter.git "$flutter_dir"
    fi
    export PATH="$flutter_dir/bin:$PATH"
    export PUB_CACHE="$WORK/pub-cache"   # keep ~/.pub-cache untouched
    flutter --disable-analytics >/dev/null 2>&1 || true
    flutter config --no-analytics --no-cli-animations >/dev/null 2>&1 || true
    flutter precache --linux

    log "Fetching dependencies"
    rm -rf build .dart_tool   # may hold a build configured against the host's libraries
    flutter pub get --enforce-lockfile --no-example

    log "Fetching pinned libmpv"
    rm -rf libmpv-prefix
    python3 scripts/fetch_linux_libmpv.py --dest libmpv-prefix

    log "Building Linux release"
    # Like the official Linux build, minus Sentry and the update check.
    PKG_CONFIG_PATH="$REPO/libmpv-prefix/lib/pkgconfig:$REPO/libmpv-prefix/lib/x86_64-linux-gnu/pkgconfig" \
        flutter build linux --release \
            --dart-define=SUPPORTER_MODE=unlocked \
            --dart-define=GIT_COMMIT="$(git rev-parse HEAD)"

    local bundle="$REPO/build/linux/x64/release/bundle"
    [[ -x "$bundle/plezy" ]] || die "bundle not found at $bundle"

    log "Staging the bundle (libmpv, bundled libraries, wrapper)"
    local libmpv_dir
    libmpv_dir="$(dirname "$(find libmpv-prefix -name 'libmpv.so' | head -1)")"
    cp -a "$libmpv_dir"/libmpv.so* "$bundle/lib/"
    cp -a libmpv-prefix/lib/libshaderc_shared.so* "$bundle/lib/"
    bash linux/packaging/bundle-libs.sh "$bundle"
    cp linux/packaging/plezy.sh "$bundle/plezy.sh"

    log "Packaging"
    local pkg_out="$WORK/packages"
    rm -rf "$pkg_out" && mkdir -p "$pkg_out"
    # build-packages.py runs check-bundle-host-deps.py first, then builds .deb, .rpm and .pkg.tar.zst.
    BUILD_DIR="$bundle" ARCH_SUFFIX=x64 OUTPUT_DIR="$pkg_out" python3 linux/packaging/build-packages.py
    python3 linux/packaging/check-package-deps.py "$pkg_out" --arch x64

    local version sha deb
    version="$(python3 scripts/pubspec_version.py pubspec.yaml)"
    version="${version%%+*}"
    sha="$(git rev-parse --short HEAD)"
    deb="$out/plezy-$version-$sha-linux-x64.deb"
    mkdir -p "$out"
    cp "$pkg_out/plezy-linux-x64.deb" "$deb"
    echo "$deb" > "$WORK/last-deb"
}

# ── Stage 1: runs on the host ──────────────────────────────────────────────
# build-packages.py chmods these to 0755 so they're executable inside the
# package, but git tracks them as 100644. Put the mode back so the working tree
# stays clean; only the mode is touched, never the contents.
restore_modes() {
    local f
    for f in linux/packaging/plezy.sh linux/packaging/after-install.sh linux/packaging/after-remove.sh; do
        [[ "$(git -C "$REPO" ls-files -s -- "$f" | cut -c1-6)" == "100644" ]] && chmod 644 "$REPO/$f"
    done
    return 0
}

cleanup() {
    local status=$?
    trap - EXIT
    restore_modes
    if (( KEEP )); then
        log "Skipping cleanup (--keep). Container '$CONTAINER' and $WORK are still there."
        exit "$status"
    fi
    log "Cleaning up"
    if podman container exists "$CONTAINER" 2>/dev/null; then
        distrobox rm --force "$CONTAINER" || echo "warning: could not remove container $CONTAINER" >&2
    fi
    if [[ -f "$WORK/.pulled-image" ]]; then
        podman image rm "$IMAGE" >/dev/null 2>&1 || echo "note: $IMAGE is still in use, left in place" >&2
    fi
    rm -rf "$WORK"
    rm -rf "$REPO/build" "$REPO/.dart_tool" "$REPO/libmpv-prefix" "$REPO/linux/packaging/icons"
    if (( status != 0 )); then
        echo "Build failed (exit $status). Re-run with --keep to inspect the container and build tree." >&2
    fi
    exit "$status"
}

host() {
    [[ "$(uname -m)" == "x86_64" ]] || die "only x86_64 is supported (CI builds arm64 on Flutter master)"
    [[ "$REPO/" == "$HOME/"* ]] || die "the repo must live under \$HOME so the container can see it ($REPO)"
    [[ "$WORK/" == "$HOME/"* ]] || die "PLEZY_COMPILE_WORK must be under \$HOME ($WORK)"
    [[ -f "$WORKFLOW" ]] || die "$WORKFLOW not found; run this from a Plezy checkout"

    if ! command -v distrobox >/dev/null || ! command -v podman >/dev/null; then
        log "Installing distrobox and podman on the host"
        sudo apt-get update
        sudo apt-get install -y distrobox podman
    fi
    export DBX_CONTAINER_MANAGER=podman

    mkdir -p "$WORK" "$OUT"
    OUT="$(cd "$OUT" && pwd)"
    rm -f "$WORK/last-deb"
    trap cleanup EXIT

    if ! podman image exists "$IMAGE"; then
        log "Pulling $IMAGE"
        podman pull "$IMAGE"
        touch "$WORK/.pulled-image"
    fi

    if podman container exists "$CONTAINER"; then
        log "Reusing container '$CONTAINER'"
    else
        log "Creating container '$CONTAINER'"
        distrobox create --name "$CONTAINER" --image "$IMAGE" --yes --no-entry
    fi

    distrobox enter "$CONTAINER" -- env PLEZY_COMPILE_WORK="$WORK" bash "$REPO/compile.sh" --inside "$OUT"

    [[ -f "$WORK/last-deb" ]] || die "the build finished without producing a .deb"
    local deb
    deb="$(cat "$WORK/last-deb")"
    log "Done: $deb"
    echo "Install with: sudo apt install '$deb'"
}

# ── Argument parsing ───────────────────────────────────────────────────────
if [[ "${1:-}" == "--inside" ]]; then
    inside "${2:?--inside needs the output directory}"
    exit 0
fi

while (( $# )); do
    case "$1" in
        --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --container) CONTAINER="${2:?--container needs a name}"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

host
