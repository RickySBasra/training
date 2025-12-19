#!/usr/bin/env bash
# hartree-destroy-clean.sh
#
# Re-runnable clean destroy sequence:
#   apps → k8s pre-clean (Ingress/LB svc/CRDs) → terraform-gitops → terraform
#
# Usage:
#   ./hartree-destroy-clean.sh
#
# Optional env overrides:
#   CLUSTER_NAME=hartree-eks-dev REGION=eu-west-2 TF_INFRA_DIR=./terraform TF_GITOPS_DIR=./terraform-gitops \
#   WAIT_LB_TIMEOUT_SECS=900 WAIT_NS_TIMEOUT_SECS=600 WAIT_POLL_SECS=15 \
#   DRY_RUN=true ./hartree-destroy-clean.sh

set -Eeuo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-hartree-eks-dev}"
REGION="${REGION:-eu-west-2}"
TF_INFRA_DIR="${TF_INFRA_DIR:-$(pwd)/terraform}"
TF_GITOPS_DIR="${TF_GITOPS_DIR:-$(pwd)/terraform-gitops}"

WAIT_LB_TIMEOUT_SECS="${WAIT_LB_TIMEOUT_SECS:-900}"   # 15 min
WAIT_NS_TIMEOUT_SECS="${WAIT_NS_TIMEOUT_SECS:-600}"   # 10 min
WAIT_POLL_SECS="${WAIT_POLL_SECS:-15}"

DRY_RUN="${DRY_RUN:-false}"

log() { printf "\n[%s] %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY_RUN> $*"
  else
    eval "$@"
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

need_cmds() {
  local missing=0
  for c in "$@"; do
    if ! have_cmd "$c"; then
      echo "❌ Missing required command: $c"
      missing=1
    fi
  done
  if [[ "$missing" -eq 1 ]]; then
    echo "Install missing tools and re-run."
    exit 1
  fi
}

safe_kubectl() {
  # kubectl returns non-zero for some "not found" edge cases even with ignore flags; keep script moving.
  set +e
  run "kubectl $*"
  local rc=$?
  set -e
  return $rc
}

wait_for_condition() {
  # wait_for_condition <timeout_secs> <poll_secs> <desc> <command_that_returns_0_when_done>
  local timeout="$1"; shift
  local poll="$1"; shift
  local desc="$1"; shift
  local start now
  start=$(date +%s)
  while true; do
    if eval "$@" >/dev/null 2>&1; then
      log "✅ $desc"
      return 0
    fi
    now=$(date +%s)
    if (( now - start > timeout )); then
      log "⚠️ Timed out waiting for: $desc"
      return 1
    fi
    log "⏳ Waiting for: $desc (poll=${poll}s, remaining=$((timeout - (now - start)))s)"
    sleep "$poll"
  done
}

aws_lb_names() {
  aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[].LoadBalancerName" --output text 2>/dev/null || true
}

aws_lb_count() {
  aws elbv2 describe-load-balancers --region "$REGION" --query "length(LoadBalancers[])" --output text 2>/dev/null || echo "0"
}

ns_exists() {
  local ns="$1"
  kubectl get ns "$ns" >/dev/null 2>&1
}

list_argocd_apps() {
  kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

delete_argocd_apps() {
  if ! ns_exists "argocd"; then
    log "ArgoCD namespace not found; skipping ArgoCD Application deletions."
    return 0
  fi

  local apps
  apps="$(list_argocd_apps)"
  if [[ -z "${apps// /}" ]]; then
    log "No ArgoCD Applications found; skipping."
    return 0
  fi

  log "Deleting ArgoCD Applications (re-runnable)."
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    log " - Deleting application: $app"
    safe_kubectl "-n argocd delete application $app --ignore-not-found"
  done <<< "$apps"
}

delete_k8s_lb_things() {
  log "Deleting Kubernetes Ingresses (all namespaces)."
  safe_kubectl "delete ingress -A --all --ignore-not-found"

  log "Deleting Kubernetes Services of type LoadBalancer (all namespaces)."
  # Iterate namespaces reliably
  local namespaces
  namespaces="$(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    # Field selector works on spec.type
    safe_kubectl "-n $ns delete svc --field-selector spec.type=LoadBalancer --ignore-not-found"
  done <<< "$namespaces"

  log "Deleting AWS Load Balancer Controller CRD instances (ignore if CRDs absent)."
  safe_kubectl "delete targetgroupbinding -A --all --ignore-not-found" || true
  safe_kubectl "delete ingressclassparams --all --ignore-not-found" || true
}

wait_for_aws_lbs_to_clear() {
  log "Waiting for AWS load balancers to be deleted (region: $REGION)."
  local desc="AWS ELBv2 load balancers count to be 0"
  wait_for_condition "$WAIT_LB_TIMEOUT_SECS" "$WAIT_POLL_SECS" "$desc" \
    "[ \"$(aws_lb_count)\" = \"0\" ]"
}

destroy_tf_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    log "Directory not found: $dir (skipping)"
    return 0
  fi

  log "Terraform destroy in: $dir"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY_RUN> (cd \"$dir\" && terraform destroy -auto-approve)"
    return 0
  fi

  ( cd "$dir" && terraform destroy -auto-approve )
}

update_kubeconfig_if_possible() {
  # Only needed if kubectl is used and kubeconfig not set up.
  # Safe to run even if already configured.
  log "Ensuring kubeconfig is set for cluster '$CLUSTER_NAME' in region '$REGION'."
  set +e
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY_RUN> aws eks update-kubeconfig --name \"$CLUSTER_NAME\" --region \"$REGION\""
    echo "DRY_RUN> kubectl get nodes"
    set -e
    return 0
  fi

  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1
  kubectl get nodes >/dev/null 2>&1
  local rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    log "⚠️ Could not reach cluster via kubectl (it may already be gone). Continuing with Terraform destroys."
  else
    log "✅ kubectl can reach the cluster."
  fi
}

wait_for_ns_gone() {
  local ns="$1"
  if ! ns_exists "$ns"; then
    return 0
  fi

  log "Waiting for namespace to terminate: $ns"
  wait_for_condition "$WAIT_NS_TIMEOUT_SECS" "$WAIT_POLL_SECS" "namespace $ns deleted" \
    "! kubectl get ns \"$ns\" >/dev/null 2>&1"
}

main() {
  need_cmds aws terraform kubectl

  log "============================================================"
  log " CLEAN DESTROY SEQUENCE"
  log " Cluster: $CLUSTER_NAME"
  log " Region : $REGION"
  log " GitOps : $TF_GITOPS_DIR"
  log " Infra  : $TF_INFRA_DIR"
  log " DryRun : $DRY_RUN"
  log "============================================================"

  update_kubeconfig_if_possible

  # 1) Apps (GitOps layer): delete ArgoCD Applications if Argo exists
  delete_argocd_apps

  # If your apps are in known namespaces, you can add them here:
  # safe_kubectl "delete ns guestbook --ignore-not-found"
  # wait_for_ns_gone "guestbook"

  # 2) Pre-clean k8s resources that create AWS resources
  delete_k8s_lb_things

  # Give controllers a moment to react before checking AWS
  log "Sleeping 20s to allow controllers to begin cleanup..."
  [[ "$DRY_RUN" == "true" ]] || sleep 20

  # 2b) Wait for AWS load balancers to clear (best-effort; does not abort destroy)
  if have_cmd aws; then
    local_count="$(aws_lb_count || echo "0")"
    if [[ "$local_count" != "0" ]]; then
      log "Current ELBv2 LB count: $local_count"
      wait_for_aws_lbs_to_clear || log "Proceeding despite remaining load balancers (may block VPC/subnet deletion)."
    else
      log "No ELBv2 load balancers detected."
    fi
  fi

  # 3) Destroy terraform-gitops layer (addons/controllers)
  destroy_tf_dir "$TF_GITOPS_DIR"

  # 4) Destroy infra layer
  destroy_tf_dir "$TF_INFRA_DIR"

  log "============================================================"
  log " DONE"
  log " Notes:"
  log "  - If VPC/subnets fail to delete, re-run this script (it's re-runnable),"
  log "    then retry 'terraform destroy'."
  log "  - To see remaining LBs: aws elbv2 describe-load-balancers --region $REGION"
  log "============================================================"
}

main "$@"
