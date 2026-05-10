#!/usr/bin/env bash
# scripts/backup/lvm-snapshot-restic.sh
#
# LVM snapshot + Restic backup pattern (consensus.md § 6).
# Used by helm/aegis-statefulset/templates/backup-cronjob.yaml as the
# in-pod backup command. The order matters:
#
#   1. LVM snapshot is instant, copy-on-write — no service interruption.
#   2. Restic reads from the read-only snapshot, never from live data.
#      This avoids the inconsistency window that "Restic on live data"
#      would suffer (compaction + WAL writes mid-backup).
#   3. Snapshot is removed at the end so COW overhead is bounded to the
#      duration of the backup.
#
# Required environment:
#   POD_NAME             — fed by Downward API (statefulset pod name)
#   RESTIC_REPOSITORY    — e.g. s3:s3.amazonaws.com/<bucket>/<prefix>
#   RESTIC_PASSWORD_FILE — path to the password file (mounted from ESO)
#
# Optional:
#   VG_NAME              — LVM volume group (default: vg-aegis)
#   DATA_LV              — data logical volume (default: data-lv)
#   SNAPSHOT_SIZE        — COW reservation (default: 100G)

set -euo pipefail

POD_NAME="${POD_NAME:?POD_NAME env var required}"
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:?RESTIC_REPOSITORY env var required}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE env var required}"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

VG_NAME="${VG_NAME:-vg-aegis}"
DATA_LV="${DATA_LV:-data-lv}"
SNAPSHOT_SIZE="${SNAPSHOT_SIZE:-100G}"

SNAP_NAME="snap-$(date +%Y%m%d-%H%M%S)"
SNAP_MOUNT="/mnt/${SNAP_NAME}"

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

cleanup() {
  if mountpoint -q "${SNAP_MOUNT}" 2>/dev/null; then
    umount "${SNAP_MOUNT}" || log "WARN: umount failed"
  fi
  if lvdisplay "/dev/${VG_NAME}/${SNAP_NAME}" >/dev/null 2>&1; then
    lvremove -f "/dev/${VG_NAME}/${SNAP_NAME}" || log "WARN: lvremove failed"
  fi
  rmdir "${SNAP_MOUNT}" 2>/dev/null || true
}
trap cleanup EXIT

log "Backup start for ${POD_NAME}"

# 1. LVM snapshot — instant, COW
log "Creating LVM snapshot ${SNAP_NAME} (size=${SNAPSHOT_SIZE})"
lvcreate --snapshot --size "${SNAPSHOT_SIZE}" \
  --name "${SNAP_NAME}" "/dev/${VG_NAME}/${DATA_LV}"

# 2. Mount snapshot read-only
mkdir -p "${SNAP_MOUNT}"
mount -o ro "/dev/${VG_NAME}/${SNAP_NAME}" "${SNAP_MOUNT}"

# 3. Restic backup against snapshot
log "Restic backup -> ${RESTIC_REPOSITORY}"
restic backup "${SNAP_MOUNT}" \
  --tag "pod=${POD_NAME}" \
  --tag "time=$(date +%s)"

# 4. Cleanup happens via trap
log "Backup complete for ${POD_NAME}"
