#!/usr/bin/env bash
# Bootstraps Keystone onto the current kube context:
#   1. installs Argo CD (the only imperative step),
#   2. creates secrets that must never live in Git,
#   3. hands everything else to GitOps via the app-of-apps.
# Usage: scripts/bootstrap.sh [git-revision]   (default: main)
set -euo pipefail
REVISION="${1:-main}"
REPO_URL="${REPO_URL:-https://github.com/nareshsaw/keystone.git}"
ARGOCD_CHART_VERSION="10.18.0"
cd "$(dirname "$0")/.."

echo "==> Installing Argo CD (chart ${ARGOCD_CHART_VERSION})"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd --version "${ARGOCD_CHART_VERSION}" \
  --namespace argocd --create-namespace -f bootstrap/argocd-values.yaml --wait --timeout 10m

echo "==> Creating backup-store credentials for the store and every tenant (generated, never committed)"
ACCESS_KEY="keystone-$(openssl rand -hex 6)"
SECRET_KEY="$(openssl rand -hex 24)"
for ns in backup-store $(ls gitops/tenants); do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if ! kubectl -n "$ns" get secret backup-store-credentials >/dev/null 2>&1; then
    kubectl -n "$ns" create secret generic backup-store-credentials \
      --from-literal=ACCESS_KEY_ID="$ACCESS_KEY" --from-literal=ACCESS_SECRET_KEY="$SECRET_KEY" >/dev/null
  fi
done

echo "==> Handing over to GitOps: app-of-apps at revision ${REVISION}"
kubectl apply -f - <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keystone
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  destination: { server: https://kubernetes.default.svc, namespace: argocd }
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${REVISION}
    path: gitops/bootstrap
    helm:
      parameters:
        - { name: revision, value: "${REVISION}" }
        - { name: repoURL, value: "${REPO_URL}" }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
YAML
echo "==> Done. Watch progress with: kubectl get applications -n argocd -w"
