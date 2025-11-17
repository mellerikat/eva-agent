#!/bin/bash

set -e
kustom_path_root=./tmp
kustom_path=$(mkdir -p $kustom_path_root 2>/dev/null && mktemp -d -p $kustom_path_root)
cd $kustom_path

# just mark which chart patch
touch eva-agent-qdrant

# post-renderer stdin to all.yaml
cat <&0 > all.yaml

# create patch1.yaml, patch2.yaml and kustomization.yaml for qdrant
# - serviceAccount.name is not set to StatefulSet spec.template.spec.serviceAccountName (bug)

cat > patch1.yaml << EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: placeholder-name    # any name available due to regex name matching
spec:
  template:
    spec:
      serviceAccountName: sa-eva-agent
EOF

cat > patch2.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: placeholder-name    # any name available due to regex name matching
spec:
  serviceAccountName: sa-eva-agent
EOF

cat > kustomization.yaml << EOF
resources:
  - all.yaml
patches:
  - path: patch1.yaml
    target:
      kind: StatefulSet
      name: "^eva-agent-qdrant.*$"
  - path: patch2.yaml
    target:
      kind: Pod
      name: ".*-test-db-interaction$"
EOF

kustomize build . && cd - >/dev/null 2>&1 && rm -rf $kustom_path_root
