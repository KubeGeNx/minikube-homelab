#!/usr/bin/env bash
# Creates the runner auth token secret GitLab Runner expects. GitLab CE
# must already be up (make gitlab) -- create a runner in its UI first:
#   http://gitlab.lab.local/  ->  Settings > CI/CD > Runners > "New instance
#   runner", pick the "kubernetes" tag/executor, and copy the generated
#   glrt-... authentication token. Then:
#     GITLAB_RUNNER_TOKEN=glrt-... ./scripts/11-gitlab-runner-secret.sh
set -euo pipefail

NAMESPACE="${GITLAB_RUNNER_NAMESPACE:-gitlab}"
TOKEN="${GITLAB_RUNNER_TOKEN:-}"

if [ -z "$TOKEN" ]; then
  echo "ERROR: set GITLAB_RUNNER_TOKEN (the glrt-... runner auth token from"
  echo "GitLab's Settings > CI/CD > Runners), e.g.:"
  echo "  GITLAB_RUNNER_TOKEN=glrt-... $0"
  exit 1
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" create secret generic gitlab-runner-auth-token \
  --from-literal=runner-token="$TOKEN" \
  --from-literal=runner-registration-token="" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret 'gitlab-runner-auth-token' created/updated in namespace '$NAMESPACE'."
echo "Enable the runner: GITLAB_RUNNER_ENABLED=true, or run: make gitlab-runner"
