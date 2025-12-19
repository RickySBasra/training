#!/usr/bin/env bash

set +e

echo "========================================================="
echo " EKS Cleanup Script - Removes LBs, TGs, CRDs, Helm, etc. "
echo "========================================================="

### 1. Delete Kubernetes Ingresses
echo "[1/10] Deleting all Ingress objects..."
kubectl delete ingress --all -A --ignore-not-found=true

### 2. Delete Services of type LoadBalancer
echo "[2/10] Deleting all LoadBalancer Services..."
for ns in $(kubectl get ns --no-headers | awk '{print $1}'); do
  kubectl delete svc -n "$ns" --field-selector spec.type=LoadBalancer --ignore-not-found=true
done

### 3. Delete TargetGroupBindings (CRD resources)
echo "[3/10] Deleting all TargetGroupBindings..."
kubectl delete targetgroupbinding --all -A --ignore-not-found=true || true

### 4. Delete IngressClassParams (CRD resources)
echo "[4/10] Deleting IngressClassParams..."
kubectl delete ingressclassparams --all --ignore-not-found=true || true

### 5. Uninstall AWS Load Balancer Controller Helm release
echo "[5/10] Uninstalling AWS Load Balancer Controller Helm chart..."
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true

### 6. Delete ALB Controller CRDs
echo "[6/10] Deleting CRDs..."
kubectl delete crd ingressclassparams.elbv2.k8s.aws --ignore-not-found=true || true
kubectl delete crd targetgroupbindings.elbv2.k8s.aws --ignore-not-found=true || true

### 7. Delete orphaned ALBs
echo "[7/10] Checking for ALBs to delete..."
ALBS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerArn" --output text)

for alb in $ALBS; do
  echo "Deleting ALB: $alb"
  aws elbv2 delete-load-balancer --load-balancer-arn "$alb" || true
done

### 8. Delete orphaned Target Groups
echo "[8/10] Checking for Target Groups to delete..."
TGS=$(aws elbv2 describe-target-groups --query "TargetGroups[].TargetGroupArn" --output text)

for tg in $TGS; do
  echo "Deleting Target Group: $tg"
  aws elbv2 delete-target-group --target-group-arn "$tg" || true
done

### 9. Delete orphaned EBS Volumes (optional but recommended)
echo "[9/10] Checking for orphaned EBS volumes..."
VOLS=$(aws ec2 describe-volumes --filters Name=status,Values=available --query "Volumes[].VolumeId" --output text)

for vol in $VOLS; do
  echo "Deleting orphaned EBS volume: $vol"
  aws ec2 delete-volume --volume-id "$vol" || true
done

echo "======================================================="
echo "  EKS OIDC PROVIDER CLEANUP SCRIPT (SAFE MODE ENABLED)"
echo "======================================================="

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "AWS Account: $ACCOUNT_ID"
echo ""

# Get all EKS OIDC providers
OIDC_PROVIDERS=$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[].Arn" --output text)

if [ -z "$OIDC_PROVIDERS" ]; then
  echo "No OIDC providers found. Nothing to delete."
  exit 0
fi

echo "Found OIDC Providers:"
echo "$OIDC_PROVIDERS"
echo ""
echo "Checking dependencies..."
echo ""

for OIDC_ARN in $OIDC_PROVIDERS; do
  echo "---------------------------------------------"
  echo "Checking: $OIDC_ARN"

  # Get the provider ID for grep convenience
  PROVIDER_ID=$(echo "$OIDC_ARN" | awk -F'/' '{print $NF}')

  # Search roles referencing this provider
  MATCHING_ROLES=$(aws iam list-roles --query "Roles[?AssumeRolePolicyDocument.Statement[].Principal[].Federated!=null]|[?contains(AssumeRolePolicyDocument.Statement[].Principal[].Federated, '$OIDC_ARN')].RoleName" --output text)

  if [ -n "$MATCHING_ROLES" ]; then
    echo "⚠️ Provider is still in use by IAM roles:"
    echo "$MATCHING_ROLES"
    echo "❌ SKIPPING deletion for safety."
  else
    echo "✅ No IAM roles depend on this provider."
    echo "🗑 Deleting OIDC provider..."
    
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" && \
    echo "✔ Successfully deleted $OIDC_ARN" || \
    echo "❌ Failed to delete $OIDC_ARN"
  fi

  echo ""
done

echo "======================================================="
echo "Cleanup complete!"
echo "Only unused OIDC providers were deleted."
echo "======================================================="


### 10. Final confirmation
echo "========================================================="
echo " Cleanup complete. You may now safely run:"
echo "       terraform destroy"
echo "========================================================="
