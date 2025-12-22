#!/usr/bin/env bash
# hartree-destroy-merged.sh
#
# Re-runnable “belt & braces” destroy/cleanup script.
# Goal: cleanly delete Kubernetes resources that create AWS infra,
# then destroy TF layers (gitops → infra), then optionally do best-effort
# post-clean of leftovers (LBs/TGs/EBS/OIDC) WITHOUT bombing out.
#
# ✅ Safe defaults:
#  - DOES NOT delete arbitrary VPCs/IAM roles/policies/state by default
#  - Only deletes OIDC providers if unused (safe mode)
#  - AWS cleanup steps are best-effort and time-bounded
#
# Usage:
#   ./hartree-destroy-merged.sh
#
# Common overrides:
#   CLUSTER_NAME=hartree-eks-dev REGION=eu-west-2 \
#   TF_INFRA_DIR=~/git/training/terraform TF_GITOPS_DIR=~/git/training/terraform-gitops \
#   ./hartree-destroy-merged.sh
#
# Dry run:
#   DRY_RUN=true ./hartree-destroy-merged.sh
#
# Optional toggles:
#   CLEAN_AWS_LBS=true         # delete all ELBv2 LBs in region (default false)
#   CLEAN_AWS_TGS=true         # delete all target groups in region (default false)
#   CLEAN_EBS_AVAILABLE=true   # delete AVAILABLE volumes in region (default false)
#   CLEAN_OIDC_UNUSED=true     # delete unused OIDC providers (default true)
#   CLEAN_HELM_LBC=true        # uninstall aws-load-balancer-controller helm release (default true)
#   DELETE_LBC_CRDS=true       # delete LBC CRDs after uninstall (default true)
#
set -Eeuo pipefail

########################################
# Config
########################################
CLUSTER_NAME="${CLUSTER_NAME:-hartree-eks-dev}"
REGION="${REGION:-eu-west-2}"

TF_INFRA_DIR="${TF_INFRA_DIR:-$(pwd)/terraform}"
TF_GITOPS_DIR="${TF_GITOPS_DIR:-$(pwd)/terraform-gitops}"

WAIT_POLL_SECS="${WAIT_POLL_SECS:-15}"
WAIT_LB_TIMEOUT_SECS="${WAIT_LB_TIMEOUT_SECS:-900}"      # 15 min
WAIT_K8S_TIMEOUT_SECS="${WAIT_K8S_TIMEOUT_SECS:-600}"    # 10 min

DRY_RUN="${DRY_RUN:-false}"

# Optional “extra” cleanup toggles (off by default except OIDC safe clean)
CLEAN_AWS_LBS="${CLEAN_AWS_LBS:-false}"
CLEAN_AWS_TGS="${CLEAN_AWS_TGS:-false}"
CLEAN_EBS_AVAILABLE="${CLEAN_EBS_AVAILABLE:-false}"

CLEAN_OIDC_UNUSED="${CLEAN_OIDC_UNUSED:-true}"

CLEAN_HELM_LBC="${CLEAN_HELM_LBC:-true}"
DELETE_LBC_CRDS="${DELETE_LBC_CRDS:-true}"

########################################
# Helpers
########################################
log() { printf "\n[%s] %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"; }

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
    exit 1
  fi
}

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY_RUN> $*"
    return 0
  fi
  # Never bomb out for “best-effort” actions; caller decides strictness
  eval "$@"
}

best_effort() {
  set +e
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY_RUN> $*"
    set -e
    return 0
  fi
  eval "$@"
  local rc=$?
  set -e
  return $rc
}

wait_for_condition() {
  # wait_for_condition <timeout> <poll> <desc> <test-cmd>
  local timeout="$1"; shift
  local poll="$1"; shift
  local desc="$1"; shift
  local start now
  start="$(date +%s)"
  while true; do
    if eval "$@" >/dev/null 2>&1; then
      log "✅ $desc"
      return 0
    fi
    now="$(date +%s)"
    if (( now - start > timeout )); then
      log "⚠️ Timed out waiting for: $desc"
      return 1
    fi
    log "⏳ Waiting for: $desc"
    sleep "$poll"
  done
}

ns_exists() { kubectl get ns "$1" >/dev/null 2>&1; }

ensure_kubeconfig() {
  # Safe to run even if cluster is gone
  if ! have_cmd aws; then
    log "aws cli not found; skipping kubeconfig update."
    return 0
  fi

  log "Ensuring kubeconfig is set for cluster '$CLUSTER_NAME' in region '$REGION' (best-effort)."
  best_effort "aws eks update-kubeconfig --name \"$CLUSTER_NAME\" --region \"$REGION\" >/dev/null 2>&1"

  if best_effort "kubectl get nodes >/dev/null 2>&1"; then
    log "✅ kubectl can reach the cluster."
  else
    log "⚠️ kubectl cannot reach the cluster (it may already be deleted). Continuing anyway."
  fi
}

########################################
# Kubernetes cleanup (re-runnable)
########################################
delete_argocd_apps() {
  if ! ns_exists "argocd"; then
    log "ArgoCD namespace not found; skipping Argo applications deletion."
    return 0
  fi

  local apps
  apps="$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"

  if [[ -z "${apps// /}" ]]; then
    log "No ArgoCD applications found; skipping."
    return 0
  fi

  log "Deleting ArgoCD Applications (re-runnable)."
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    log " - Deleting application: $app"
    best_effort "kubectl -n argocd delete application \"$app\" --ignore-not-found"
  done <<< "$apps"
}

delete_ingresses_and_lb_services() {
  log "Deleting all Ingress objects..."
  best_effort "kubectl delete ingress --all -A --ignore-not-found=true"

  log "Deleting all Services of type LoadBalancer..."
  local namespaces
  namespaces="$(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    best_effort "kubectl -n \"$ns\" delete svc --field-selector spec.type=LoadBalancer --ignore-not-found=true"
  done <<< "$namespaces"
}

delete_lbc_crd_instances() {
  log "Deleting AWS Load Balancer Controller CRD instances (if present)..."
  best_effort "kubectl delete targetgroupbinding --all -A --ignore-not-found=true"
  best_effort "kubectl delete ingressclassparams --all --ignore-not-found=true"
}

uninstall_lbc_helm() {
  if [[ "$CLEAN_HELM_LBC" != "true" ]]; then
    log "Skipping Helm uninstall of aws-load-balancer-controller (CLEAN_HELM_LBC=false)."
    return 0
  fi

  if ! have_cmd helm; then
    log "helm not found; skipping Helm uninstall."
    return 0
  fi

  log "Uninstalling aws-load-balancer-controller Helm release (best-effort)..."
  best_effort "helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true"
}

delete_lbc_crds() {
  if [[ "$DELETE_LBC_CRDS" != "true" ]]; then
    log "Skipping deletion of LBC CRDs (DELETE_LBC_CRDS=false)."
    return 0
  fi

  log "Deleting AWS Load Balancer Controller CRDs (best-effort)..."
  best_effort "kubectl delete crd ingressclassparams.elbv2.k8s.aws --ignore-not-found=true"
  best_effort "kubectl delete crd targetgroupbindings.elbv2.k8s.aws --ignore-not-found=true"
}

########################################
# AWS cleanup (optional, guarded)
########################################
wait_for_elbv2_lbs_to_clear() {
  log "Waiting for ELBv2 load balancers to disappear (best-effort)..."
  wait_for_condition "$WAIT_LB_TIMEOUT_SECS" "$WAIT_POLL_SECS" "ELBv2 load balancer count == 0" \
    "[ \"$(aws elbv2 describe-load-balancers --region \"$REGION\" --query 'length(LoadBalancers[])' --output text 2>/dev/null || echo 0)\" = \"0\" ]" \
    || return 1
}

delete_all_elbv2_lbs_in_region() {
  [[ "$CLEAN_AWS_LBS" != "true" ]] && return 0

  log "CLEAN_AWS_LBS=true → deleting ALL ELBv2 load balancers in region $REGION (best-effort)."
  local lbs
  lbs="$(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[].LoadBalancerArn" --output text 2>/dev/null || true)"
  for lb in $lbs; do
    log " - Deleting LB: $lb"
    best_effort "aws elbv2 delete-load-balancer --region \"$REGION\" --load-balancer-arn \"$lb\""
  done
}

delete_all_target_groups_in_region() {
  [[ "$CLEAN_AWS_TGS" != "true" ]] && return 0

  log "CLEAN_AWS_TGS=true → deleting ALL target groups in region $REGION (best-effort)."
  local tgs
  tgs="$(aws elbv2 describe-target-groups --region "$REGION" --query "TargetGroups[].TargetGroupArn" --output text 2>/dev/null || true)"
  for tg in $tgs; do
    log " - Deleting target group: $tg"
    best_effort "aws elbv2 delete-target-group --region \"$REGION\" --target-group-arn \"$tg\""
  done
}

delete_available_ebs_volumes() {
  [[ "$CLEAN_EBS_AVAILABLE" != "true" ]] && return 0

  log "CLEAN_EBS_AVAILABLE=true → deleting AVAILABLE EBS volumes in region $REGION (best-effort)."
  local vols
  vols="$(aws ec2 describe-volumes --region "$REGION" --filters Name=status,Values=available --query "Volumes[].VolumeId" --output text 2>/dev/null || true)"
  for vol in $vols; do
    log " - Deleting EBS volume: $vol"
    best_effort "aws ec2 delete-volume --region \"$REGION\" --volume-id \"$vol\""
  done
}

########################################
# OIDC cleanup (safe-mode)
########################################
oidc_cleanup_unused() {
  [[ "$CLEAN_OIDC_UNUSED" != "true" ]] && return 0

  log "OIDC cleanup (safe mode): delete ONLY providers not referenced by any IAM role trust policy."
  local oidcs
  oidcs="$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[].Arn" --output text 2>/dev/null || true)"
  if [[ -z "${oidcs// /}" ]]; then
    log "No OIDC providers found."
    return 0
  fi

  for oidc_arn in $oidcs; do
    log "Checking OIDC provider: $oidc_arn"

    # Find roles that reference this provider in their AssumeRolePolicyDocument.
    # Note: list-roles returns AssumeRolePolicyDocument only in some environments; best-effort.
    local matching_roles
    matching_roles="$(aws iam list-roles \
      --query "Roles[?contains(to_string(AssumeRolePolicyDocument), '$oidc_arn')].RoleName" \
      --output text 2>/dev/null || true)"

    if [[ -n "${matching_roles// /}" ]]; then
      log "⚠️ Still referenced by IAM roles; skipping deletion:"
      echo "$matching_roles"
      continue
    fi

    log "🗑 Deleting unused OIDC provider: $oidc_arn"
    best_effort "aws iam delete-open-id-connect-provider --open-id-connect-provider-arn \"$oidc_arn\""
  done
}

########################################
# Terraform destroys
########################################
destroy_tf_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    log "Terraform directory not found: $dir (skipping)"
    return 0
  fi

  log "Terraform destroy: $dir"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY_RUN> (cd \"$dir\" && terraform destroy -auto-approve)"
    return 0
  fi

  ( cd "$dir" && terraform destroy -auto-approve ) || {
    log "⚠️ terraform destroy failed in $dir (you can re-run this script safely)."
    return 1
  }
}

########################################
# Main
########################################
main() {
  need_cmds aws kubectl terraform
  [[ "$CLEAN_HELM_LBC" == "true" ]] && need_cmds helm || true
  need_cmds jq || true # optional (not required)

  log "============================================================"
  log " Hartree merged destroy/cleanup (re-runnable)"
  log " Cluster: $CLUSTER_NAME"
  log " Region : $REGION"
  log " GitOps : $TF_GITOPS_DIR"
  log " Infra  : $TF_INFRA_DIR"
  log " DryRun : $DRY_RUN"
  log "============================================================"

  ensure_kubeconfig

  # 1) Apps first (Argo)
  delete_argocd_apps

  # 2) K8s pre-clean that triggers AWS deletions
  delete_ingresses_and_lb_services
  delete_lbc_crd_instances

  # Optional: uninstall LBC and remove CRDs (generally safe before cluster delete)
  uninstall_lbc_helm
  delete_lbc_crds

  log "Sleeping 20s to allow controllers to begin cleanup..."
  [[ "$DRY_RUN" == "true" ]] || sleep 20

  # Optional deeper AWS cleanup (off by default)
  delete_all_elbv2_lbs_in_region
  delete_all_target_groups_in_region
  delete_available_ebs_volumes

  # Best-effort wait for LBs to clear (helpful if you run with CLEAN_AWS_LBS=false too)
  best_effort "aws elbv2 describe-load-balancers --region \"$REGION\" >/dev/null 2>&1" && \
    wait_for_elbv2_lbs_to_clear || true

  # 3) Destroy TF layers (gitops → infra)
  destroy_tf_dir "$TF_GITOPS_DIR" || true
  destroy_tf_dir "$TF_INFRA_DIR" || true

  # 4) OIDC safe cleanup (optional, safe-mode)
  oidc_cleanup_unused || true

  log "============================================================"
  log " Done."
  log " Re-run safe. If something fails, fix the underlying issue and re-run."
  log "============================================================"
}

main "$@"
