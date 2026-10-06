#!/usr/bin/env bash
#
# fix-setuid-bits.sh
#
# Restores setuid bits stripped from core system binaries (sudo, su, mount,
# passwd, pkexec, crontab, etc). Root cause on sky141 (2026-09-23): a chmod
# sweep on 2026-09-16 09:54 stripped the setuid bit from 20 binaries,
# breaking `sudo` host-wide. This silently broke openstack-manila-share
# (it crashed in init_host() calling `sudo manila-rootwrap ... ip link set`,
# looped via oslo_service respawn, and never registered with the DB — so
# systemd showed "active (running)" while `manila service-list` never showed
# the host), plus designate-worker and telegraf, which failed every sudo call.
#
# What this script does, per file:
#   1. Determine the correct mode (prefer RPM package metadata; fall back to
#      a hardcoded reference for vendor binaries not owned by any package).
#   2. Compare to the current on-disk mode.
#   3. chmod it back if different (skipped in --dry-run).
#
# Usage:
#   ./fix-setuid-bits.sh                # fix on this host
#   ./fix-setuid-bits.sh --dry-run       # show what would change, no writes
#   ./fix-setuid-bits.sh --host sky141   # run remotely over ssh as root
#   ./fix-setuid-bits.sh --restart-manila  # also restart openstack-manila-share.service
#
set -euo pipefail

DRY_RUN=0
REMOTE_HOST=""
RESTART_MANILA=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --host) REMOTE_HOST="${2:?--host requires a hostname}"; shift 2 ;;
    --restart-manila) RESTART_MANILA=1; shift ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Re-exec on the remote host if --host was given, then run this same script
# there as root over ssh (so the logic only has to live in one place).
if [[ -n "$REMOTE_HOST" ]]; then
  ARGS=()
  [[ "$DRY_RUN" -eq 1 ]] && ARGS+=("--dry-run")
  [[ "$RESTART_MANILA" -eq 1 ]] && ARGS+=("--restart-manila")
  exec ssh -o StrictHostKeyChecking=no "root@${REMOTE_HOST}" "bash -s -- ${ARGS[*]}" < "$0"
fi

# --- files and their correct mode -------------------------------------------
# Format: "path:mode". Mode is looked up from the owning RPM package when
# possible; this list is the fallback (and the source of truth for files
# not owned by any package, e.g. vendor/hex_* binaries).
REFERENCE_FILES=(
  "/usr/bin/sudo:4111"
  "/usr/bin/su:4755"
  "/usr/bin/mount:4755"
  "/usr/bin/umount:4755"
  "/usr/bin/chage:4755"
  "/usr/bin/gpasswd:4755"
  "/usr/bin/newgrp:4755"
  "/usr/bin/passwd:4755"
  "/usr/bin/pkexec:4755"
  "/usr/bin/crontab:4755"
  "/usr/bin/fusermount:4755"
  "/usr/bin/fusermount3:4755"
  "/usr/sbin/unix_chkpwd:4755"
  "/usr/sbin/pam_timestamp_check:4755"
  "/usr/sbin/usernetctl:4755"
  "/usr/sbin/grub2-set-bootflag:4755"
  "/usr/sbin/mount.nfs:4755"
  # Vendor binaries, not owned by any RPM package (verified via peer comparison)
  "/usr/bin/nvidia-modprobe:4755"
  "/usr/sbin/hex_config:4755"
  "/usr/sbin/hex_firsttime:4755"
)

log() { printf '%s\n' "$*"; }

fixed_count=0
skipped_count=0
ok_count=0

for entry in "${REFERENCE_FILES[@]}"; do
  file="${entry%%:*}"
  fallback_mode="${entry##*:}"

  if [[ ! -e "$file" ]]; then
    log "MISSING   $file (not present on this host, skipping)"
    ((skipped_count++)) || true
    continue
  fi

  # Prefer the mode recorded in the owning RPM package, when there is one.
  want_mode="$fallback_mode"
  if pkg=$(rpm -qf --qf '%{NAME}' "$file" 2>/dev/null); then
    rpm_mode=$(rpm -q --qf '[%{FILEMODES:octal} %{FILENAMES}\n]' "$pkg" 2>/dev/null \
      | awk -v f="$file" '$2==f {print substr($1, length($1)-3)}')
    [[ -n "$rpm_mode" ]] && want_mode="$rpm_mode"
  fi

  current_mode=$(stat -c '%a' "$file")

  if [[ "$current_mode" == "$want_mode" ]]; then
    log "OK        $file ($current_mode)"
    ((ok_count++)) || true
    continue
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "WOULD FIX $file  $current_mode -> $want_mode"
  else
    chmod "$want_mode" "$file"
    log "FIXED     $file  $current_mode -> $(stat -c '%a' "$file")"
  fi
  ((fixed_count++)) || true
done

log ""
log "=== summary: ok=$ok_count fixed=$fixed_count skipped=$skipped_count dry_run=$DRY_RUN ==="

# --- verification ------------------------------------------------------------
if [[ "$DRY_RUN" -eq 0 ]]; then
  log ""
  log "=== rpm -V mode/digest check (should print nothing below) ==="
  for pkg in sudo util-linux util-linux-core shadow-utils passwd polkit cronie \
             fuse fuse3 pam nfs-utils grub2-tools-minimal openstack-network-scripts; do
    rpm -V "$pkg" 2>/dev/null | grep -E '^[^ ]*M' | grep -v 'rules\.d' || true
  done

  log ""
  log "=== sudo sanity check ==="
  if sudo -n true 2>/dev/null; then
    log "sudo -n true: OK"
  else
    log "sudo -n true: FAILED (may just need a tty/password; check manually)"
  fi
fi

# --- optional: restart manila-share and confirm it registers -----------------
if [[ "$RESTART_MANILA" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
  log ""
  log "=== restarting openstack-manila-share.service ==="
  systemctl restart openstack-manila-share.service
  sleep 20
  systemctl is-active openstack-manila-share.service
  tail -n 10 /var/log/manila/share.log || true
  log ""
  log "Check registration with: manila service-list"
fi
