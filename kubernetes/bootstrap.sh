#!/usr/bin/env bash
#
# Ordered, idempotent apply of the cluster infrastructure.
# Used by .github/workflows/deploy.yml and for local runs.
#
# Requires: kubectl (with a working KUBECONFIG / context) and network access.
#
#   export KUBECONFIG=$PWD/kubeconfig/kube-cp-01.yaml
#   kubernetes/bootstrap.sh
#
set -euo pipefail

# --- pinned upstream operator versions (Renovate-managed) -------------------
# renovate: datasource=github-releases depName=cert-manager/cert-manager
CERT_MANAGER_VERSION="v1.21.1"
# renovate: datasource=github-releases depName=cloudnative-pg/cloudnative-pg
CNPG_VERSION="1.30.0"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

step "Traefik configuration (K3s bundled Traefik)"
kubectl apply -k "${here}/infrastructure/traefik"

step "cert-manager ${CERT_MANAGER_VERSION}"
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=180s
kubectl apply -k "${here}/infrastructure/cert-manager"

step "Headscale + Headplane"
kubectl apply -k "${here}/infrastructure/headscale"
if ! kubectl -n headscale get secret headplane-secret >/dev/null 2>&1; then
  echo "  ! Secret headscale/headplane-secret is missing - Headplane will stay"
  echo "    NotReady until you create it (see infrastructure/headscale/README.md)."
fi

step "CloudNativePG operator ${CNPG_VERSION}"
kubectl apply --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION%.*}/releases/cnpg-${CNPG_VERSION}.yaml"
kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=180s
kubectl apply -k "${here}/infrastructure/cloudnative-pg"

step "Application scaffolding (namespace / RBAC / database / ingress)"
# Only the platform side of each app lives here. The Deployment + Service are
# owned and applied by the app's own repo (see kubernetes/apps/README.md).
# Directories starting with "_" (e.g. _template) are skipped.
shopt -s nullglob
for app in "${here}"/apps/*/; do
  name="$(basename "${app}")"
  [[ "${name}" == _* ]] && continue
  [[ -f "${app}kustomization.yaml" ]] || continue
  echo "  - ${name}"
  kubectl apply -k "${app}"
done
shopt -u nullglob

step "done"
