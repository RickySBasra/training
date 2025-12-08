#!/usr/bin/env bash
set -euo pipefail

########################################
# CONFIG – EDIT THESE FOR YOUR ACCOUNT #
########################################
REGION="eu-west-2"
ACCOUNT_ID="722847566444"

CLUSTER_NAME="hartree-eks-dev"
PROJECT_TAG="hartree-eks"
ENV_TAG="dev"

# Remote Terraform state (if you used S3/Dynamo backend)
TFSTATE_BUCKET="hartree-tfstate"        # S3 bucket for state
TFSTATE_KEY_PREFIX="eks/dev"            # key prefix/folder
TF_LOCK_TABLE="hartree-tfstate-locks"         # DynamoDB lock table (dedicated to TF)

########################################
echo "Using region: ${REGION}"
aws configure set region "${REGION}"

############################
# Helper: delete VPC stack #
############################
delete_vpc_safely() {
  local VPC_ID="$1"
  echo "============================================"
  echo "==> Deep-cleaning VPC ${VPC_ID}"
  echo "============================================"

  # 0. Delete ELBv2 load balancers in this VPC
  echo "==> Deleting load balancers in VPC..."
  LBS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" --output text 2>/dev/null || true)
  for lb in ${LBS}; do
    echo "  - Deleting LB: ${lb}"
    aws elbv2 delete-load-balancer --load-balancer-arn "${lb}" || true
  done
  sleep 5

  # 1. Delete NAT Gateways
  echo "==> Deleting NAT Gateways..."
  NGWS=$(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=${VPC_ID} --query "NatGateways[].NatGatewayId" --output text 2>/dev/null || true)
  for ng in ${NGWS}; do
    echo "  - Deleting NATGW ${ng}"
    aws ec2 delete-nat-gateway --nat-gateway-id "${ng}" || true
  done

  echo "==> Waiting for NAT gateways to disappear..."
  while true; do
    STATES=$(aws ec2 describe-nat-gateways \
      --filter Name=vpc-id,Values=${VPC_ID} \
      --query "NatGateways[].State" \
      --output text 2>/dev/null || true)

    [[ -z "${STATES}" ]] && break

    if ! [[ "${STATES}" =~ "pending" || "${STATES}" =~ "available" || "${STATES}" =~ "deleting" ]]; then
      break
    fi

    echo "    NAT gateway states: ${STATES} ... waiting 10s"
    sleep 10
  done

  # 2. Release EIPs
  echo "==> Releasing EIPs..."
  EIPS=$(aws ec2 describe-addresses --filters Name=domain,Values=vpc --query "Addresses[].AllocationId" --output text 2>/dev/null || true)
  for eip in ${EIPS}; do
    echo "  - Releasing EIP ${eip}"
    aws ec2 release-address --allocation-id "${eip}" || true
  done

  # 3. Delete ENIs
  echo "==> Deleting ENIs..."
  ENIS=$(aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=${VPC_ID} --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>/dev/null || true)
  for eni in ${ENIS}; do
    echo "  - Deleting ENI ${eni}"
    aws ec2 delete-network-interface --network-interface-id "${eni}" || true
  done
  sleep 3

  # 4. Detach & delete IGWs
  echo "==> Deleting Internet Gateways..."
  IGWS=$(aws ec2 describe-internet-gateways \
    --filters Name=attachment.vpc-id,Values=${VPC_ID} \
    --query "InternetGateways[].InternetGatewayId" --output text 2>/dev/null || true)
  for igw in ${IGWS}; do
    echo "  - Detaching IGW ${igw}"
    aws ec2 detach-internet-gateway --internet-gateway-id "${igw}" --vpc-id "${VPC_ID}" || true
    echo "  - Deleting IGW ${igw}"
    aws ec2 delete-internet-gateway --internet-gateway-id "${igw}" || true
  done

  # 5. Delete non-main route tables
  echo "==> Deleting Route Tables..."
  RTBS=$(aws ec2 describe-route-tables --filters Name=vpc-id,Values=${VPC_ID} --query "RouteTables[].RouteTableId" --output text 2>/dev/null || true)
  for rtb in ${RTBS}; do
    MAIN=$(aws ec2 describe-route-tables --route-table-ids "${rtb}" --query "RouteTables[0].Associations[?Main].Main" --output text 2>/dev/null || true)
    if [[ "${MAIN}" != "True" ]]; then
      echo "  - Deleting RTB ${rtb}"
      aws ec2 delete-route-table --route-table-id "${rtb}" || true
    fi
  done

  # 6. Delete non-default security groups
  echo "==> Cleaning up and deleting Security Groups..."

  # Get all SG IDs except default
  SGS=$(aws ec2 describe-security-groups \
    --filters Name=vpc-id,Values=${VPC_ID} \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text || true)

  for sg in ${SGS}; do
    echo "==> Cleaning rules for SG ${sg}"

    # 1. Remove all ingress rules referencing other SGs
    REF_SGS=$(aws ec2 describe-security-groups \
      --group-ids ${sg} \
      --query "SecurityGroups[].IpPermissions[].UserIdGroupPairs[].GroupId" \
      --output text || true)

    for ref in ${REF_SGS}; do
      echo "  - Removing ingress rule referencing SG ${ref}"
      aws ec2 revoke-security-group-ingress \
        --group-id ${sg} \
        --source-group ${ref} \
        --protocol all 2>/dev/null || true
    done

    # 2. Remove all egress rules referencing other SGs
    REF_EGRESS_SGS=$(aws ec2 describe-security-groups \
      --group-ids ${sg} \
      --query "SecurityGroups[].IpPermissionsEgress[].UserIdGroupPairs[].GroupId" \
      --output text || true)

    for ref in ${REF_EGRESS_SGS}; do
      echo "  - Removing egress rule referencing SG ${ref}"
      aws ec2 revoke-security-group-egress \
        --group-id ${sg} \
        --destination-group ${ref} \
        --protocol all 2>/dev/null || true
    done

    # 3. Remove ALL remaining ingress rules (ports, CIDRs, etc.)
    echo "  - Removing all remaining ingress rules"
    aws ec2 describe-security-groups --group-ids ${sg} \
      --query "SecurityGroups[].IpPermissions" \
      --output json | \
      jq -c '.[]' | while read perm; do
        aws ec2 revoke-security-group-ingress \
          --group-id ${sg} \
          --ip-permissions "${perm}" 2>/dev/null || true
      done

    # 4. Remove ALL remaining egress rules
    echo "  - Removing all remaining egress rules"
    aws ec2 describe-security-groups --group-ids ${sg} \
      --query "SecurityGroups[].IpPermissionsEgress" \
      --output json | \
      jq -c '.[]' | while read perm; do
        aws ec2 revoke-security-group-egress \
          --group-id ${sg} \
          --ip-permissions "${perm}" 2>/dev/null || true
      done

    # 5. Try to delete the SG now
    echo "  - Deleting SG ${sg}"
    aws ec2 delete-security-group --group-id "${sg}" || true
  done


  # 7. Delete subnets
  echo "==> Deleting Subnets..."
  SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --query "Subnets[].SubnetId" --output text 2>/dev/null || true)
  for sn in ${SUBNETS}; do
    echo "  - Deleting Subnet ${sn}"
    aws ec2 delete-subnet --subnet-id "${sn}" || true
  done

  # 8. Delete VPC
  echo "==> Attempting VPC deletion..."
  aws ec2 delete-vpc --vpc-id "${VPC_ID}" || {
    echo "❌ VPC deletion failed for ${VPC_ID} — dependencies may still exist."
  }

  echo "==> VPC deletion attempted for ${VPC_ID}"
}

############################
# 1. Delete EKS nodegroups #
############################
echo "==> Deleting EKS nodegroups for ${CLUSTER_NAME}..."
NGS=$(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query "nodegroups[]" --output text 2>/dev/null || true)

if [[ -n "${NGS}" ]]; then
  for ng in ${NGS}; do
    echo "  - Deleting nodegroup: ${ng}"
    aws eks delete-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${ng}" || true
  done

  echo "==> Waiting for nodegroups to disappear..."
  while true; do
    REMAINING=$(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query "nodegroups[]" --output text 2>/dev/null || true)
    [[ -z "${REMAINING}" ]] && break
    echo "  - Still present: ${REMAINING} ... sleeping 15s"
    sleep 15
  done
else
  echo "  - No nodegroups found."
fi

##########################
# 2. Delete EKS cluster  #
##########################
echo "==> Deleting EKS cluster ${CLUSTER_NAME} (if exists)..."
if aws eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  aws eks delete-cluster --name "${CLUSTER_NAME}"
  echo "==> Waiting for cluster deletion..."
  while aws eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1; do
    echo "  - Cluster still exists, sleeping 15s"
    sleep 15
  done
else
  echo "  - Cluster not found, skipping."
fi

##########################################
# 3. Delete KMS alias & CW log group     #
##########################################
echo "==> Deleting KMS alias for EKS (if exists)..."
if aws kms list-aliases --query "Aliases[?AliasName=='alias/eks/${CLUSTER_NAME}']" --output text 2>/dev/null | grep -q "alias/eks/${CLUSTER_NAME}"; then
  aws kms delete-alias --alias-name "alias/eks/${CLUSTER_NAME}" || true
  echo "  - Deleted KMS alias alias/eks/${CLUSTER_NAME}"
else
  echo "  - No KMS alias found for alias/eks/${CLUSTER_NAME}"
fi

echo "==> Deleting CloudWatch log group for EKS cluster (if exists)..."
aws logs delete-log-group --log-group-name "/aws/eks/${CLUSTER_NAME}/cluster" 2>/dev/null || echo "  - No log group to delete."

#################################
# 4. Delete IAM roles & policies#
#################################
echo "==> Deleting IAM roles related to ${CLUSTER_NAME}/${PROJECT_TAG}..."
ROLE_NAMES=$(aws iam list-roles --query "Roles[?contains(RoleName, '${CLUSTER_NAME}') || contains(RoleName, 'alb-controller') || contains(RoleName, 'eks-node-group')].RoleName" --output text 2>/dev/null || true)
for role in ${ROLE_NAMES}; do
  echo "  - Processing role: ${role}"
  ARNS=$(aws iam list-attached-role-policies --role-name "${role}" --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null || true)
  for arn in ${ARNS}; do
    echo "    * Detaching policy ${arn}"
    aws iam detach-role-policy --role-name "${role}" --policy-arn "${arn}" || true
  done

  INLINES=$(aws iam list-role-policies --role-name "${role}" --query "PolicyNames[]" --output text 2>/dev/null || true)
  for pol in ${INLINES}; do
    echo "    * Deleting inline policy ${pol}"
    aws iam delete-role-policy --role-name "${role}" --policy-name "${pol}" || true
  done

  echo "    * Deleting role ${role}"
  aws iam delete-role --role-name "${role}" || true
done

echo "==> Deleting standalone IAM policies related to ${CLUSTER_NAME}..."
POLICY_ARNS=$(aws iam list-policies --scope Local --query "Policies[?contains(PolicyName, '${CLUSTER_NAME}') || contains(PolicyName, 'alb-controller')].Arn" --output text 2>/dev/null || true)
for parn in ${POLICY_ARNS}; do
  echo "  - Deleting policy ${parn}"
  aws iam delete-policy --policy-arn "${parn}" || true
done

###########################
# 5. Delete tagged VPC(s) #
###########################
echo "==> Deleting VPCs tagged Project=${PROJECT_TAG}, Environment=${ENV_TAG}..."
VPCS=$(aws ec2 describe-vpcs \
   --filters "Name=tag:Project,Values=${PROJECT_TAG}" "Name=tag:Environment,Values=${ENV_TAG}" \
   --query "Vpcs[].VpcId" --output text 2>/dev/null || true)

for v in ${VPCS}; do
  delete_vpc_safely "${v}"
done

#################################
# 6. Delete Terraform state     #
#################################
echo "==> Cleaning Terraform local state..."
rm -f terraform.tfstate terraform.tfstate.backup || true
rm -rf .terraform .terraform.lock.hcl || true

echo "==> Cleaning remote Terraform state (if configured)..."
if aws s3 ls "s3://${TFSTATE_BUCKET}/${TFSTATE_KEY_PREFIX}/terraform.tfstate" >/dev/null 2>&1; then
  echo "  - Deleting S3 state object"
  aws s3 rm "s3://${TFSTATE_BUCKET}/${TFSTATE_KEY_PREFIX}/terraform.tfstate" || true
else
  echo "  - No S3 state object found at s3://${TFSTATE_BUCKET}/${TFSTATE_KEY_PREFIX}/terraform.tfstate"
fi

if aws dynamodb describe-table --table-name "${TF_LOCK_TABLE}" >/dev/null 2>&1; then
  echo "  - Deleting DynamoDB lock table ${TF_LOCK_TABLE}"
  aws dynamodb delete-table --table-name "${TF_LOCK_TABLE}" || true

else
  echo "  - No DynamoDB lock table ${TF_LOCK_TABLE} found."
fi

  aws dynamodb create-table \
  --table-name hartree-tfstate-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
echo "============================================"
echo "==> ALL DONE. EKS/VPC/IAM/state for ${CLUSTER_NAME} cleaned (best-effort)."
echo "============================================"
