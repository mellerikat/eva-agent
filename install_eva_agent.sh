#!/usr/bin/env bash

# If sourced, re-exec in a child bash to avoid killing the current shell.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  bash "${BASH_SOURCE[0]}" "$@"
  return $?
fi

# Safety flags: fail fast, no unset vars, propagate pipe errors.
set -euo pipefail

# EVA Agent deploy: ECR login -> dockerConfig -> Helm upgrade -> optional rollout restart.

usage() {
  cat <<'USAGE'
Usage:
  ./install_eva_agent.sh [options]

Options:
  --chart <chart>             Helm chart reference (default: eva-agent/eva-agent)
  --chart-version <ver>       Helm chart version (latest if omitted)
  --image <tag>               Image tag (defaults to values.yaml image.tag)
  --namespace <ns>            Namespace (default: eva-agent)
  --context <ctx>             Kube context (default: current context)
  --base-dir <dir>            Base directory with eva-agent values (default: pwd)
  --ecr-host <host>           ECR host (default: 339713051385.dkr.ecr.ap-northeast-2.amazonaws.com)
  --ecr-repo <repo>           ECR repo name (default: mellerikat/release/eva-agent)
  --profile <aws-profile>     AWS profile (default: default)
  --check-digest <0|1>        Compare digest when tag is the same (default: 1)
  --docker-config <path>      DOCKER_CONFIG path (default: /tmp/docker)
  -f, --values <file>         Extra values file (repeatable)
  -h, --help                  Show help

Expected layout under base-dir:
  ./eva-agent/values.yaml
  ./eva-agent/values-secret.yaml
  ./eva-agent/values-k3s.yaml (optional)
  ./eva-agent/values-aws.yaml (optional)

Examples:
  ./install_eva_agent.sh --image 2.4.0b1
  ./install_eva_agent.sh --chart eva-agent/eva-agent --chart-version 2.1.2
USAGE
}

# Defaults (override via env vars or CLI).
NS="${NS:-eva-agent}"
AWS_ECR_HOST="${AWS_ECR_HOST:-339713051385.dkr.ecr.ap-northeast-2.amazonaws.com}"
AWS_PROFILE="${AWS_PROFILE:-}"
ECR_REPO_NAME="${ECR_REPO_NAME:-mellerikat/release/eva-agent}"
CHART="${CHART:-eva-agent/eva-agent}"
CHART_VERSION="${CHART_VERSION:-}"
IMAGE_TAG="${IMAGE_TAG:-}"
CHECK_DIGEST="${CHECK_DIGEST:-1}"
DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker}"
BASE_DIR="${BASE_DIR:-$(pwd)}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
EXTRA_VALUES=()

# Parse CLI args (extra values are collected in an array).
while [ "${1:-}" != "" ]; do
  case "$1" in
    --chart) CHART="$2"; shift 2 ;;
    --chart-version) CHART_VERSION="$2"; shift 2 ;;
    --image) IMAGE_TAG="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --context) KUBE_CONTEXT="$2"; shift 2 ;;
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    --ecr-host) AWS_ECR_HOST="$2"; shift 2 ;;
    --ecr-repo) ECR_REPO_NAME="$2"; shift 2 ;;
    --profile) AWS_PROFILE="$2"; shift 2 ;;
    --check-digest) CHECK_DIGEST="$2"; shift 2 ;;
    --docker-config) DOCKER_CONFIG="$2"; shift 2 ;;
    -f|--values) EXTRA_VALUES+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

echo "[INFO] Namespace: ${NS}"
echo "[INFO] ECR Host: ${AWS_ECR_HOST}"
echo "[INFO] Chart: ${CHART}"
echo "[INFO] Base Dir: ${BASE_DIR}"

# If not provided, default to the "default" AWS profile.
if [ -z "$AWS_PROFILE" ]; then
  AWS_PROFILE="default"
fi
echo "[INFO] AWS Profile: ${AWS_PROFILE}"

VALUES_DIR="${BASE_DIR}/eva-agent"

HELM_CONTEXT_ARGS=()
KUBECTL_CONTEXT_ARGS=()
if [ -n "$KUBE_CONTEXT" ]; then
  HELM_CONTEXT_ARGS=(--kube-context "$KUBE_CONTEXT")
  KUBECTL_CONTEXT_ARGS=(--context "$KUBE_CONTEXT")
  echo "[INFO] Kube Context: ${KUBE_CONTEXT}"
fi

# Resolve IMAGE_TAG from values.yaml when not provided.
if [ -z "$IMAGE_TAG" ] && [ -f "${VALUES_DIR}/values.yaml" ]; then
  IMAGE_TAG="$(awk '
    $1 == "image:" {in_image=1; next}
    in_image && $1 == "tag:" {gsub(/"/, "", $2); print $2; exit}
    in_image && $1 ~ /^[A-Za-z_]/ {in_image=0}
  ' "${VALUES_DIR}/values.yaml")"
fi

if [ -n "$IMAGE_TAG" ]; then
  echo "[INFO] Image Tag: ${IMAGE_TAG}"
else
  echo "[WARN] IMAGE_TAG not set and no tag found in values.yaml."
fi

# Resolve chart version from Helm metadata when not provided.
if [ -z "$CHART_VERSION" ]; then
  CHART_VERSION="$(helm show chart "$CHART" | awk -F': ' '/^version:/{print $2; exit}')"
fi

if [ -z "$CHART_VERSION" ]; then
  echo "Failed to resolve chart version for ${CHART}. Set CHART_VERSION manually." >&2
  exit 1
fi
echo "[INFO] Chart Version: ${CHART_VERSION}"

# Detect the currently deployed image tag to handle same-tag rollouts.
prev_image="$(kubectl "${KUBECTL_CONTEXT_ARGS[@]}" -n "$NS" get deploy eva-agent \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
prev_tag=""
if [ -n "$prev_image" ] && [ "${prev_image#*@}" = "$prev_image" ]; then
  prev_tag="${prev_image##*:}"
fi

# Prepare a temporary docker config.
mkdir -p "$DOCKER_CONFIG"
printf '{"auths":{}}' > "$DOCKER_CONFIG/config.json"

echo "[INFO] Refreshing ECR login..."
if ! aws ecr get-login-password --profile "$AWS_PROFILE" | \
  docker --config "$DOCKER_CONFIG" login --username AWS --password-stdin "$AWS_ECR_HOST"; then
  echo "[ERROR] ECR login failed. Check AWS profile or network." >&2
  exit 1
fi

# Create a temporary values file containing dockerConfig.
docker_config_file="$DOCKER_CONFIG/config.json"
values_file="$docker_config_file-values.yaml"
cat > "$values_file" << EOF
dockerConfig:
  json: $(cat "$docker_config_file" | base64 -w0)
EOF

# Include default values only if files exist; append user values after.
default_values_args=()
for values_path in "${VALUES_DIR}/values.yaml" "${VALUES_DIR}/values-secret.yaml"; do
  if [ -f "$values_path" ]; then
    default_values_args+=(-f "$values_path")
  else
    echo "[INFO] values file not found: ${values_path} (skip)"
  fi
done
extra_values_args=()
for values_path in "${EXTRA_VALUES[@]}"; do
  extra_values_args+=(-f "$values_path")
done

echo "[INFO] Running helm upgrade..."
helm upgrade --install eva-agent "$CHART" --version="$CHART_VERSION" -n "$NS" \
  "${HELM_CONTEXT_ARGS[@]}" \
  "${default_values_args[@]}" \
  -f "$values_file" \
  "${extra_values_args[@]}" \
  ${IMAGE_TAG:+--set image.tag="$IMAGE_TAG"}

# If the tag is the same, compare digests and restart if needed.
if [ -n "$IMAGE_TAG" ] && [ -n "$prev_tag" ] && [ "$prev_tag" = "$IMAGE_TAG" ]; then
  if [ "$CHECK_DIGEST" = "1" ]; then
    desired_digest="$(aws ecr describe-images \
      --repository-name "$ECR_REPO_NAME" \
      --image-ids imageTag="$IMAGE_TAG" \
      --query 'imageDetails[0].imageDigest' \
      --output text 2>/dev/null || true)"
    if [ "$desired_digest" = "None" ]; then
      desired_digest=""
    fi

    current_image_id="$(kubectl "${KUBECTL_CONTEXT_ARGS[@]}" -n "$NS" get pod -l app.kubernetes.io/name=eva-agent \
      -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null || true)"
    current_digest="${current_image_id##*@}"

    if [ -n "$desired_digest" ] && [ -n "$current_digest" ] && [ "$current_digest" != "$desired_digest" ]; then
      echo "[INFO] Digest mismatch -> rollout restart"
      kubectl "${KUBECTL_CONTEXT_ARGS[@]}" rollout restart deploy/eva-agent -n "$NS"
    else
      echo "[INFO] Digest matches -> skip rollout restart"
    fi
  else
    echo "[INFO] CHECK_DIGEST=0 -> restart on same tag"
    kubectl "${KUBECTL_CONTEXT_ARGS[@]}" rollout restart deploy/eva-agent -n "$NS"
  fi
else
  echo "[INFO] Image tag changed or missing -> Helm rollout is sufficient"
fi

# Cleanup temporary files.
rm -f "$values_file"
rm -f "$DOCKER_CONFIG/config.json"
