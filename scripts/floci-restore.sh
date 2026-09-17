#!/usr/bin/env bash
# Restore a floci backup produced by floci-backup.sh.
#   ./floci-restore.sh ~/floci-backups/20260915-181900
set -euo pipefail

SRC="${1:?usage: floci-restore.sh <backup-dir>}"
FLOCI_DIR="${FLOCI_DIR:-$HOME/floci}"

echo "==> restoring from $SRC"
echo "    This overwrites current floci state. Ctrl-C now if that is not what you want."
sleep 5

cd "$FLOCI_DIR" && docker compose down            # NOT -v: volumes are restored below

# control-plane state
[ -f "$SRC/floci-data.tgz" ] && tar xzf "$SRC/floci-data.tgz" -C "$FLOCI_DIR" && echo "  control-plane state restored"

# volumes
for f in "$SRC"/vol-*.tgz; do
  [ -e "$f" ] || continue
  v=$(basename "$f" .tgz); v=${v#vol-}
  # recreate with the label only for volumes that had one (floci's own);
  # k3s volumes are unlabelled and floci matches them by name.
  case "$v" in
    floci-eks-*) docker volume create "$v" >/dev/null ;;
    *)           docker volume create --label floci=true "$v" >/dev/null ;;
  esac
  docker run --rm -v "$v":/v -v "$SRC":/b alpine tar xzf "/b/$(basename "$f")" -C /v
  echo "  volume restored: $v"
done

docker compose up -d
echo "==> floci restarting. Watch the clusters come back:"
echo "    aws eks list-clusters --endpoint-url http://localhost:4566"
echo "    (a restored cluster reports CREATING until its API server answers, then ACTIVE)"
echo
echo "If a database came back inconsistent, reload it from the logical dump instead:"
echo "    cat $SRC/db-floci-rds-<id>.sql | docker exec -i <container> psql -U postgres"
