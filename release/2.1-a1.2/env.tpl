#!/bin/bash

EA_NS=eva-agent       # namespace

#TODO: fill them up
# platform: aws, ncp, k3s(on-premise) - helm uses values-$EA_PLATFORM.yaml
EA_PLATFORM=
# Values directory root
EA_VALUE_ROOT=

# install from repo chart
# if not exists in repo, install from local chart
declare -A EA_REP_MAP

# https://artifacthub.io/packages/helm/qdrant/qdrant
EA_REP_MAP["eva-agent-qdrant"]="https://qdrant.github.io/qdrant-helm|qdrant|qdrant/qdrant|1.15.0" # appVersion: 1.15.0

# https://artifacthub.io/packages/helm/ollama-helm/ollama
EA_REP_MAP["eva-agent-ollama"]="https://helm.otwld.com/|otwld|otwld/ollama|1.27.0" # appVersion: 0.11.4

# https://mellerikat.github.io/eva-agent
EA_REP_MAP["eva-agent-init"]="https://mellerikat.github.io/eva-agent|eva-agent|eva-agent/eva-agent-init|1.0.0"

# https://mellerikat.github.io/eva-agent
EA_REP_MAP["eva-agent"]="https://mellerikat.github.io/eva-agent|eva-agent|eva-agent/eva-agent|2.1.2"
