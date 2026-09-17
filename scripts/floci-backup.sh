#!/usr/bin/env bash
# Back up everything floci holds. Run on the box, from anywhere.
#
# floci keeps state in two places and a backup must cover BOTH:
#   tier 2  ~/floci/data/aws        — control plane: clusters, secrets, ALB config
#   tier 3  docker volumes labelled floci=true — the real Postgres and k3s data
#
# Databases get a pg_dump as well, because a volume snapshot of a running Postgres
# is a crash-consistent copy, not a clean one. The dump is what you actually restore
# from; the volume tar is the fallback.
set -euo pipefail

FLOCI_DIR="${FLOCI_DIR:-$HOME/floci}"
DEST="${1:-$HOME/floci-backups/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$DEST"

echo "==> backing up to $DEST"

# 1. logical database dumps — the most reliable restore path
for c in $(docker ps --format '{{.Names}}' | grep -E '^floci-rds-' || true); do
  echo "  pg_dumpall: $c"
  docker exec "$c" pg_dumpall -U postgres > "$DEST/db-$c.sql" 2>/dev/null \
    || echo "     (skipped — not postgres, or different superuser)"
done

# 2. floci's control-plane state
if [ -d "$FLOCI_DIR/data" ]; then
  tar czf "$DEST/floci-data.tgz" -C "$FLOCI_DIR" data
  echo "  control-plane state: floci-data.tgz"
fi

# 3. every floci-owned docker volume.
#    Matching on the label ALONE is not enough: floci labels its RDS/ElastiCache
#    volumes floci=true, but the EKS k3s volumes carry NO labels at all. Filtering
#    on the label silently skips every cluster. Match name OR label, deduplicated.
for v in $( { docker volume ls -q --filter label=floci=true
              docker volume ls -q --filter name=^floci-; } | sort -u ); do
  docker run --rm -v "$v":/v -v "$DEST":/b alpine tar czf "/b/vol-$v.tgz" -C /v . 2>/dev/null
  echo "  volume: $v"
done

# 4. the operational config you would otherwise have to remember
cp "$FLOCI_DIR/compose.yaml" "$DEST/" 2>/dev/null || true
sudo cp /etc/systemd/system/floci.service "$DEST/" 2>/dev/null || true

echo "==> done. $(du -sh "$DEST" | cut -f1) in $DEST"
echo "    Copy it OFF this box — a backup on the same disk is not a backup."
