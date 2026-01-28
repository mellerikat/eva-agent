#!/bin/bash
set -euo pipefail

kustom_path_root="./tmp"
mkdir -p "$kustom_path_root" 2>/dev/null || true

kustom_path="$(mktemp -d -p "$kustom_path_root")"
cleanup() {
  rm -rf "$kustom_path"
}
trap cleanup EXIT

cd "$kustom_path"

# just mark which chart patch (breadcrumb)
touch eva-agent-vllm

# post-renderer stdin -> all.yaml (Helm rendered manifests)
cat <&0 > all.yaml

#
# Patch 1) Keep PVCs after helm uninstall
#
cat > pvc-keep-patch.yaml << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: placeholder-name
  annotations:
    helm.sh/resource-policy: keep
EOF

#
# Patch 2) Router probes (the chart's values didn't reflect, so we patch the rendered Deployment)
#
cat > router-probes-patch.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: eva-agent-vllm-deployment-router
spec:
  template:
    spec:
      containers:
        - name: router-container
          startupProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 24   # ~2 minutes total budget
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 60
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
EOF

cat > kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - all.yaml

patches:
  # Keep PVCs
  - path: pvc-keep-patch.yaml
    target:
      kind: PersistentVolumeClaim
      name: eva-agent-vllm-.*-storage-claim

  # Router probes
  - path: router-probes-patch.yaml
    target:
      kind: Deployment
      name: eva-agent-vllm-deployment-router
EOF

kustomize build .
