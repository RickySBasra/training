###############################################
# IAM for Cluster Autoscaler (IRSA)
###############################################

data "aws_iam_policy_document" "cluster_autoscaler_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values = [
        "system:serviceaccount:kube-system:cluster-autoscaler",
      ]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${var.cluster_name}-cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume.json
}

data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeTags",
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup",
      "ec2:DescribeLaunchTemplateVersions"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name   = "${var.cluster_name}-cluster-autoscaler-policy"
  policy = data.aws_iam_policy_document.cluster_autoscaler.json
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

###############################################
# Helm: Cluster Autoscaler
###############################################

resource "helm_release" "cluster_autoscaler" {
  name             = "cluster-autoscaler"
  namespace        = "kube-system"
  create_namespace = false

  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.37.0" # recent version, OK with 1.31

  values = [
    yamlencode({
      autoDiscovery = {
        clusterName = module.eks.cluster_name
        enabled     = true
      }
      awsRegion = var.region
      rbac = {
        serviceAccount = {
          create = true
          name   = "cluster-autoscaler"
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.cluster_autoscaler.arn
          }
        }
      }
      extraArgs = {
        "balance-similar-node-groups"      = "true"
        "skip-nodes-with-local-storage"    = "false"
        "skip-nodes-with-system-pods"      = "false"
        "scan-interval"                    = "10s"
      }
    })
  ]

  depends_on = [
    module.eks,
    time_sleep.wait_for_rbac,
    aws_iam_role_policy_attachment.cluster_autoscaler,
  ]
}
