#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${SCRIPT_DIR}/bin:${PATH}"

CLUSTER_NAME="metrics-cluster"

echo "=== 1. Creating KIND Cluster (${CLUSTER_NAME}) ==="
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "KIND cluster '${CLUSTER_NAME}' already exists."
else
  kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/kind-config.yaml"
fi

echo "=== 2. Installing NGINX Ingress Controller ==="
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

echo "Waiting for NGINX Ingress Controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

echo "=== 3. Installing ArgoCD ==="
kubectl create namespace argocd || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD Server to be ready..."
kubectl wait --namespace argocd \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=argocd-server \
  --timeout=180s

echo "=== 4. Deploying metrics-app via Helm directly & applying ArgoCD Application ==="
helm upgrade --install metrics-app "${SCRIPT_DIR}/metrics-app"

kubectl apply -f "${SCRIPT_DIR}/argocd/application.yaml"

echo "=== Setup Complete! ==="
