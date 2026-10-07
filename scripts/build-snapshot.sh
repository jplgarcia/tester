#!/usr/bin/env bash
# Build the tester machine snapshot reproducibly and print its template hash.
#
#   scripts/build-snapshot.sh            # incremental (BuildKit cache allowed)
#   NO_CACHE=1 scripts/build-snapshot.sh # cold build of the root filesystem
#
# Environment:
#   OUT        output directory (default .build)
#   IMAGES_DIR directory with the kernel and rootfs-tools (default $OUT/images);
#              missing files are downloaded, every file is sha256-checked
#   NO_CACHE   1 = docker buildx build --no-cache
#
# Pipeline (all pinned in scripts/build.env and the Dockerfile):
#   1. kernel + rootfs-tools of the node tag, checked against scripts/dependencies.sha256
#   2. docker buildx (linux/riscv64) -> $OUT/root.tar, file times = SOURCE_DATE_EPOCH
#   3. xgenext2fs (same flags as `cartesi build`) -> $OUT/root.ext2
#   4. cartesi-machine 0.21.0 boots the dapp until its first "accepted" yield and
#      stores the machine -> $OUT/snapshot ; template hash = cartesi-machine-stored-hash
#   5. $OUT/snapshot.tar.gz (deterministic tar), .sha256, template-hash.txt, build-info.txt
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=build.env
. scripts/build.env

OUT=${OUT:-.build}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
IMAGES_DIR=${IMAGES_DIR:-$OUT/images}
mkdir -p "$IMAGES_DIR"
IMAGES_DIR=$(cd "$IMAGES_DIR" && pwd)
NO_CACHE=${NO_CACHE:-0}
UIDGID="$(id -u):$(id -g)"

log() { printf '==> %s\n' "$*" >&2; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# 1. kernel and rootfs-tools ---------------------------------------------------
fetch() { # file url
    if [ ! -f "$IMAGES_DIR/$1" ]; then
        log "downloading $1"
        curl -fsSL -o "$IMAGES_DIR/$1.part" "$2"
        mv "$IMAGES_DIR/$1.part" "$IMAGES_DIR/$1"
    fi
}
fetch "$KERNEL_FILE" "$KERNEL_URL"
fetch "$ROOTFS_TOOLS_FILE" "$ROOTFS_TOOLS_URL"
log "checking kernel and rootfs-tools against scripts/dependencies.sha256"
(cd "$IMAGES_DIR" && sha256 -c "$ROOT/scripts/dependencies.sha256") >&2

# 2. root filesystem tarball -----------------------------------------------------
log "building the riscv64 root filesystem (NO_CACHE=$NO_CACHE)"
rm -f "$OUT/root.tar" "$OUT/root.ext2"
build_args=(--platform linux/riscv64 --provenance=false --sbom=false
    --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
    --output "type=tar,dest=$OUT/root.tar")
[ "$NO_CACHE" = 1 ] && build_args+=(--no-cache)
docker buildx build "${build_args[@]}" "$ROOT" >&2

# 3. ext2 image --------------------------------------------------------------------
log "creating root.ext2 with xgenext2fs"
docker run --rm --user "$UIDGID" -v "$OUT:/work" -w /work --entrypoint xgenext2fs \
    "$XGENEXT2FS_IMAGE" --block-size 4096 --faketime --readjustment +0 \
    --tarball root.tar root.ext2 >&2

# 4. machine snapshot -------------------------------------------------------------
log "booting the machine with cartesi-machine $EMULATOR_VERSION"
rm -rf "$OUT/snapshot"
IMG=/usr/share/cartesi-machine/images
docker run --rm --user "$UIDGID" -v "$OUT:/work" \
    -v "$IMAGES_DIR/$KERNEL_FILE:$IMG/linux.bin:ro" \
    -v "$IMAGES_DIR/$ROOTFS_TOOLS_FILE:$IMG/rootfs.ext2:ro" \
    --entrypoint cartesi-machine "$EMULATOR_IMAGE" \
    --ram-length="$RAM_LENGTH" \
    --flash-drive=label:root,data_filename:/work/root.ext2 \
    --env=PATH="$GUEST_PATH" \
    --workdir="$WORKDIR" \
    --final-hash --store=/work/snapshot \
    -- "$ENTRYPOINT" > "$OUT/machine.log" 2>&1 || { cat "$OUT/machine.log" >&2; exit 1; }
tail -n 5 "$OUT/machine.log" >&2
if ! grep -q "Manual yield rx-accepted" "$OUT/machine.log"; then
    log "the machine did not stop at an rx-accepted yield (see $OUT/machine.log)"
    exit 1
fi

HASH=$(docker run --rm --user "$UIDGID" -v "$OUT:/work" --entrypoint cartesi-machine-stored-hash \
    "$EMULATOR_IMAGE" /work/snapshot | tr -d '[:space:]')
# the CLI deploy path reads the same 32 bytes at offset 0x60 of hash_tree.sht
SHT=0x$(od -An -tx1 -j96 -N32 "$OUT/snapshot/hash_tree.sht" | tr -d ' \n')
case "$HASH" in 0x*) ;; *) HASH="0x$HASH" ;; esac
if [ "$HASH" != "$SHT" ]; then
    log "stored hash $HASH differs from hash_tree.sht@0x60 $SHT"
    exit 1
fi

# 5. release artifacts ------------------------------------------------------------
log "packing snapshot.tar.gz"
rm -f "$OUT/snapshot.tar.gz"
docker run --rm --user "$UIDGID" -v "$OUT:/work" --entrypoint sh "$EMULATOR_IMAGE" -c \
    "tar --sort=name --mtime=@$SOURCE_DATE_EPOCH --owner=0 --group=0 --numeric-owner \
         --format=gnu -C /work/snapshot -cf - . | gzip -n -9 > /work/snapshot.tar.gz"
(cd "$OUT" && sha256 snapshot.tar.gz > snapshot.tar.gz.sha256)
echo "$HASH" > "$OUT/template-hash.txt"

{
    echo "template_hash=$HASH"
    echo "snapshot_tar_gz_sha256=$(cut -d' ' -f1 "$OUT/snapshot.tar.gz.sha256")"
    echo "root_ext2_sha256=$(sha256 "$OUT/root.ext2" | cut -d' ' -f1)"
    echo "root_tar_sha256=$(sha256 "$OUT/root.tar" | cut -d' ' -f1)"
    echo "git_commit=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "rollups_node=v2.0.0-alpha.13"
    echo "rollups_contracts=v3.0.0-alpha.10"
    echo "machine_emulator=$EMULATOR_VERSION ($EMULATOR_IMAGE)"
    echo "machine_guest_tools=$(sed -n 's/^ARG MACHINE_GUEST_TOOLS_VERSION=//p' Dockerfile) (sha256 $(sed -n 's/^ARG MACHINE_GUEST_TOOLS_SHA256SUM=//p' Dockerfile))"
    echo "kernel=$KERNEL_FILE (sha256 $(grep " $KERNEL_FILE\$" scripts/dependencies.sha256 | cut -d' ' -f1))"
    echo "rootfs_tools=$ROOTFS_TOOLS_FILE (sha256 $(grep " $ROOTFS_TOOLS_FILE\$" scripts/dependencies.sha256 | cut -d' ' -f1))"
    echo "base_image=$(sed -n 's/^ARG UBUNTU_IMAGE=//p' Dockerfile)"
    echo "apt_snapshot=$(sed -n 's/^ARG APT_UPDATE_SNAPSHOT=//p' Dockerfile)"
    echo "xgenext2fs_image=$XGENEXT2FS_IMAGE"
    echo "source_date_epoch=$SOURCE_DATE_EPOCH"
    echo "ram_length=$RAM_LENGTH"
    echo "entrypoint=$ENTRYPOINT"
} > "$OUT/build-info.txt"
cat "$OUT/build-info.txt" >&2

log "template hash: $HASH"
echo "$HASH"
