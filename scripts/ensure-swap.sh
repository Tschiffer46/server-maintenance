#!/bin/bash
# Ensure /swapfile exists at the desired size, is active, and is persisted in
# /etc/fstab — idempotently. Safe to run repeatedly.
#
# Why this exists: running the raw `fallocate -l … /swapfile; mkswap; swapon`
# sequence a second time fails with "fallocate: Text file busy",
# "/swapfile is mounted; will not make swapspace" and "swapon failed: Device or
# resource busy", because you cannot resize or reformat a swapfile that is
# already active. Repeated `tee -a /etc/fstab` also leaves duplicate entries.
# This script handles all of that.
#
# Usage:  sudo bash ensure-swap.sh [SIZE]
#   SIZE defaults to 2G. Examples: 2G, 4G, 512M
#   Override swappiness with SWAPPINESS=<n> (default 10).
set -uo pipefail

SWAPFILE="/swapfile"
SIZE="${1:-2G}"
SWAPPINESS="${SWAPPINESS:-10}"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (sudo bash ensure-swap.sh [SIZE])"
  exit 1
fi

echo "=== ensure-swap: target ${SWAPFILE} = ${SIZE}, swappiness ${SWAPPINESS} ($(date)) ==="

want_bytes=$(numfmt --from=iec "$SIZE") \
  || { echo "ERROR: invalid size '$SIZE' (use e.g. 2G, 4G, 512M)"; exit 1; }

have_bytes=0
[ -f "$SWAPFILE" ] && have_bytes=$(stat -c %s "$SWAPFILE")

is_active() { swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; }

# 1. Swapfile itself — only touch it if size or active-state is wrong
if [ -f "$SWAPFILE" ] && [ "$have_bytes" -eq "$want_bytes" ] && is_active; then
  echo "OK: ${SWAPFILE} is already ${SIZE} and active — leaving it untouched."
else
  if is_active; then
    echo "--- swapoff ${SWAPFILE} (active, must be off before resize/reformat) ---"
    swapoff "$SWAPFILE" \
      || { echo "ERROR: swapoff failed — not enough free RAM to absorb swapped pages right now. Try again when memory is less loaded."; exit 1; }
  fi
  echo "--- (re)creating ${SWAPFILE} at ${SIZE} ---"
  rm -f "$SWAPFILE"
  if ! fallocate -l "$SIZE" "$SWAPFILE"; then
    echo "fallocate not supported on this filesystem — falling back to dd"
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$(( want_bytes / 1024 / 1024 ))" status=progress
  fi
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
  swapon "$SWAPFILE"
fi

# 2. /etc/fstab — exactly one correct entry (no duplicates from manual tee -a)
total=$(grep -cE "^${SWAPFILE}[[:space:]]" /etc/fstab 2>/dev/null) || total=0
correct=$(grep -cE "^${SWAPFILE}[[:space:]]+none[[:space:]]+swap" /etc/fstab 2>/dev/null) || correct=0
if [ "$total" -eq 1 ] && [ "$correct" -eq 1 ]; then
  echo "fstab: already has exactly one correct ${SWAPFILE} entry."
else
  cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  sed -i "\#^${SWAPFILE}[[:space:]]#d" /etc/fstab
  echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
  echo "fstab: normalised to a single ${SWAPFILE} entry (backup saved as /etc/fstab.bak.*)."
fi

# 3. swappiness
echo "vm.swappiness=${SWAPPINESS}" > /etc/sysctl.d/99-swappiness.conf
sysctl -q -w "vm.swappiness=${SWAPPINESS}"
echo "swappiness: set to ${SWAPPINESS}."

echo ""
echo "=== Result ==="
swapon --show
free -h
