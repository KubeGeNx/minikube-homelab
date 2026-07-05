#!/usr/bin/env bash
# Creates the S3-style credentials secret Velero needs to talk to MinIO,
# and makes sure the backup bucket exists. Run once MinIO's pod is Running
# and before (or right after) the Velero Application syncs -- Velero's pod
# will CrashLoop until this secret exists, which is harmless and self-heals.
set -euo pipefail

MINIO_NAMESPACE="${MINIO_NAMESPACE:-minio}"
VELERO_NAMESPACE="${VELERO_NAMESPACE:-velero}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-homelab-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-HomelabMinio123!}"
BUCKET="${VELERO_BUCKET:-velero-backups}"

echo "Waiting for MinIO pod in namespace '$MINIO_NAMESPACE'..."
kubectl -n "$MINIO_NAMESPACE" wait --for=condition=Ready pod -l app=minio --timeout=300s

echo "Ensuring bucket '$BUCKET' exists via a one-off mc job (the minio chart's"
echo "post-install job usually already created it from values.buckets, so an"
echo "'already exists' message here is expected and harmless)..."
kubectl -n "$MINIO_NAMESPACE" delete pod mc-bootstrap --ignore-not-found >/dev/null 2>&1 || true
# --command: the minio/mc image's entrypoint is `mc` itself, so without it
# "sh -c ..." would be passed as arguments to mc ("`sh` is not a recognized
# command"). Credentials go in via env vars, not the command line, so they
# don't end up in logged args.
kubectl -n "$MINIO_NAMESPACE" run mc-bootstrap --rm -i --restart=Never --image=minio/mc:latest \
  --env="MC_USER=${MINIO_ROOT_USER}" --env="MC_PASS=${MINIO_ROOT_PASSWORD}" --env="MC_BUCKET=${BUCKET}" \
  --command -- sh -c 'mc alias set homelab http://minio:9000 "$MC_USER" "$MC_PASS" && (mc mb -p "homelab/$MC_BUCKET" || true)'

echo "Creating/updating 'velero-minio-credentials' secret in namespace '$VELERO_NAMESPACE'..."
kubectl create namespace "$VELERO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

CREDS_FILE="$(mktemp)"
cat > "$CREDS_FILE" <<EOF
[default]
aws_access_key_id=${MINIO_ROOT_USER}
aws_secret_access_key=${MINIO_ROOT_PASSWORD}
EOF

kubectl -n "$VELERO_NAMESPACE" create secret generic velero-minio-credentials \
  --from-file=cloud="$CREDS_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -f "$CREDS_FILE"

echo "Done. Velero's Application (sync-wave 4) can now sync/self-heal successfully."
echo "NOTE: change MINIO_ROOT_PASSWORD from the default before this is anything but a throwaway homelab."
