#!/bin/bash

set -e
kustom_path_root=./tmp
kustom_path=$(mkdir -p $kustom_path_root 2>/dev/null && mktemp -d -p $kustom_path_root)
cd $kustom_path

# just mark which chart patch
touch eva-agent-vllm

# post-renderer stdin to all.yaml
cat <&0 > all.yaml

# create patch.yaml and kustomization.yaml for vllm 0.1.7
# - keep pvc after uninstallation

cat > patch.yaml << EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: placeholder-name    # any name available due to regex name matching
  annotations:
    helm.sh/resource-policy: keep
EOF

cat > kustomization.yaml << EOF
resources:
  - all.yaml
patches:
  - path: patch.yaml
    target:
      kind: PersistentVolumeClaim
      name: eva-agent-vllm-.*-storage-claim
EOF

kustomize build . && cd - >/dev/null 2>&1 && rm -rf $kustom_path_root
