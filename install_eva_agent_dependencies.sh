#!/usr/bin/env bash

# If sourced, re-exec in a child bash to avoid killing the current shell.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  bash "${BASH_SOURCE[0]}" "$@"
  return $?
fi

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./install_eva_agent_dependencies.sh [options]

Options:
  --namespace <ns>           Namespace (default: eva-agent)
  --release <ver>            Release version (default: 2.5.0)
  --base-dir <dir>           Base directory with values/plugin folders (default: pwd)
  --qdrant-chart-version <v> Qdrant chart version (default: 1.16.3)
  --vllm-chart-version <v>   vLLM chart version (default: 0.1.7)
  --qdrant-values <file>     Extra values file for Qdrant (repeatable)
  --vllm-values <file>       Extra values file for vLLM (repeatable)
  --aws-credential <profile> AWS CLI profile name to seed aws-credentials Secret
  --aws-secret-name <name>   Secret name for AWS creds (default: aws-credentials)
  -h, --help                 Show help

Expected layout under base-dir:
  ./eva-agent-qdrant/values.yaml
  ./eva-agent-vllm/values.yaml
  ./plugin/eva-agent-qdrant/{plugin.yaml,post-renderer.sh}

Examples:
  ./install_eva_agent_dependencies.sh \
    --qdrant-values eva-agent-qdrant/values-aws.yaml \
    --vllm-values eva-agent-vllm/values-aws.yaml
USAGE
}

NS="${NS:-eva-agent}"
RELEASE_VERSION="${RELEASE_VERSION:-2.5.0}"
BASE_DIR="${BASE_DIR:-$(pwd)}"
QDRANT_CHART_VERSION="${QDRANT_CHART_VERSION:-1.16.3}"
VLLM_CHART_VERSION="${VLLM_CHART_VERSION:-0.1.8}"
AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-}"
AWS_SECRET_NAME="${AWS_SECRET_NAME:-aws-credentials}"

QDRANT_VALUES_EXTRA=()
VLLM_VALUES_EXTRA=()

while [ "${1:-}" != "" ]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --release) RELEASE_VERSION="$2"; shift 2 ;;
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    --qdrant-chart-version) QDRANT_CHART_VERSION="$2"; shift 2 ;;
    --vllm-chart-version) VLLM_CHART_VERSION="$2"; shift 2 ;;
    --qdrant-values) QDRANT_VALUES_EXTRA+=("$2"); shift 2 ;;
    --vllm-values) VLLM_VALUES_EXTRA+=("$2"); shift 2 ;;
    --aws-credential) AWS_PROFILE_NAME="$2"; shift 2 ;;
    --aws-secret-name) AWS_SECRET_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

command -v helm >/dev/null 2>&1 || { echo "[ERROR] helm not found" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "[ERROR] kubectl not found" >&2; exit 1; }
if [ -n "${AWS_PROFILE_NAME}" ]; then
  command -v aws >/dev/null 2>&1 || { echo "[ERROR] aws CLI not found (required for --aws-credential)" >&2; exit 1; }
fi

HELM_PLUGINS="$(helm env 2>/dev/null | awk -F= '/^HELM_PLUGINS=/{print $2}' | tr -d '\"')"
if [ -z "$HELM_PLUGINS" ]; then
  HELM_PLUGINS="$HOME/.local/share/helm/plugins"
fi

QDRANT_DIR="${BASE_DIR}/eva-agent-qdrant"
VLLM_DIR="${BASE_DIR}/eva-agent-vllm"
PLUGIN_DIR="${BASE_DIR}/plugin"
QDRANT_PLUGIN_DIR="${PLUGIN_DIR}/eva-agent-qdrant"

require_file() {
  if [ ! -f "$1" ]; then
    echo "[ERROR] Missing file: $1" >&2
    exit 1
  fi
}

require_file "${QDRANT_DIR}/values.yaml"
require_file "${VLLM_DIR}/values.yaml"

HELM_VERSION_RAW="$(helm version --short 2>/dev/null || true)"
HELM_VERSION_RAW="${HELM_VERSION_RAW#v}"
HELM_MAJOR="${HELM_VERSION_RAW%%.*}"
if [ -z "$HELM_MAJOR" ]; then
  echo "[ERROR] Failed to detect Helm version." >&2
  exit 1
fi

qdrant_post_renderer=""

if [ "$HELM_MAJOR" -ge 4 ]; then
  require_file "${QDRANT_PLUGIN_DIR}/plugin.yaml"
  require_file "${QDRANT_PLUGIN_DIR}/post-renderer.sh"
  chmod +x "${QDRANT_PLUGIN_DIR}/post-renderer.sh"

  mkdir -p "${HELM_PLUGINS}"
  # Always refresh plugins from the local source to pick up changes.
  if helm plugin list | awk '{print $1}' | grep -qx "eva-agent-qdrant-postrenderer"; then
    helm plugin remove "eva-agent-qdrant-postrenderer" >/dev/null 2>&1 || true
  fi
  rm -rf "${HELM_PLUGINS}/eva-agent-qdrant"
  helm plugin install "${QDRANT_PLUGIN_DIR}"

  qdrant_post_renderer="eva-agent-qdrant-postrenderer"
else
  require_file "${QDRANT_PLUGIN_DIR}/post-renderer.sh"
  chmod +x "${QDRANT_PLUGIN_DIR}/post-renderer.sh"

  qdrant_post_renderer="${QDRANT_PLUGIN_DIR}/post-renderer.sh"
fi

qdrant_values_args=(-f "${QDRANT_DIR}/values.yaml")
for values_path in "${QDRANT_VALUES_EXTRA[@]}"; do
  qdrant_values_args+=(-f "$values_path")
done

vllm_values_args=(-f "${VLLM_DIR}/values.yaml")
for values_path in "${VLLM_VALUES_EXTRA[@]}"; do
  vllm_values_args+=(-f "$values_path")
done

echo "[INFO] Namespace: ${NS}"
echo "[INFO] Release: ${RELEASE_VERSION} (script supports >= 2.5.0 layout)"
if [ -n "${AWS_PROFILE_NAME}" ]; then
  AWS_ACCESS_KEY_ID="$(aws --profile "${AWS_PROFILE_NAME}" configure get aws_access_key_id)"
  AWS_SECRET_ACCESS_KEY="$(aws --profile "${AWS_PROFILE_NAME}" configure get aws_secret_access_key)"
  AWS_REGION="$(aws --profile "${AWS_PROFILE_NAME}" configure get region)"

  if [ -z "${AWS_ACCESS_KEY_ID}" ] || [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
    echo "[ERROR] Missing aws_access_key_id or aws_secret_access_key in profile '${AWS_PROFILE_NAME}'." >&2
    exit 1
  fi
  if [ -z "${AWS_REGION}" ]; then
    echo "[ERROR] Missing region in profile '${AWS_PROFILE_NAME}'." >&2
    exit 1
  fi

  kubectl -n "${NS}" create secret generic "${AWS_SECRET_NAME}" \
    --from-literal=AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
    --from-literal=AWS_REGION="${AWS_REGION}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "[INFO] Upserted Secret ${AWS_SECRET_NAME} from AWS profile ${AWS_PROFILE_NAME}"
fi

helm upgrade --install eva-agent-qdrant qdrant/qdrant \
  --version="${QDRANT_CHART_VERSION}" \
  -n "${NS}" \
  "${qdrant_values_args[@]}" \
  --post-renderer "${qdrant_post_renderer}"

helm upgrade --install eva-agent-vllm eva-agent/eva-agent-vllm \
  --version="${VLLM_CHART_VERSION}" \
  -n "${NS}" \
  "${vllm_values_args[@]}"
