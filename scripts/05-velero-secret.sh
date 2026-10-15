#!/usr/bin/env bash
# Creates the S3 credentials secret Velero needs to talk to SeaweedFS.
# and before (or right after) the Velero Application syncs -- Velero's pod
# will CrashLoop until this secret exists, which is harmless and self-heals.
set -euo pipefail

SEAWEEDFS_NAMESPACE="${SEAWEEDFS_NAMESPACE:-seaweedfs}"
VELERO_NAMESPACE="${VELERO_NAMESPACE:-velero}"
SEAWEEDFS_ACCESS_KEY="${SEAWEEDFS_ACCESS_KEY:-homelab-admin}"
SEAWEEDFS_SECRET_KEY="${SEAWEEDFS_SECRET_KEY:-HomelabSeaweedAdminKey123!}"
BUCKET="${VELERO_BUCKET:-velero-backups}"

echo "Waiting for SeaweedFS S3 deployment in namespace '$SEAWEEDFS_NAMESPACE'..."
kubectl -n "$SEAWEEDFS_NAMESPACE" rollout status deployment/seaweedfs-s3 --timeout=300s

echo "Creating/updating 'velero-seaweedfs-credentials' secret in namespace '$VELERO_NAMESPACE'..."
kubectl create namespace "$VELERO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

CREDS_FILE="$(mktemp)"
cat > "$CREDS_FILE" <<EOF
[default]
aws_access_key_id=${SEAWEEDFS_ACCESS_KEY}
aws_secret_access_key=${SEAWEEDFS_SECRET_KEY}
EOF

kubectl -n "$VELERO_NAMESPACE" create secret generic velero-seaweedfs-credentials \
  --from-file=cloud="$CREDS_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -f "$CREDS_FILE"

echo "Done. Velero's Application (sync-wave 4) can now sync/self-heal successfully."
echo "NOTE: change SEAWEEDFS_SECRET_KEY from the default before using this beyond a throwaway homelab."
