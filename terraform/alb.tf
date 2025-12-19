###############################################
# AWS Load Balancer Controller – IRSA (IAM)
###############################################

# Official IAM policy for ALB Controller
data "http" "alb_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "alb_controller_policy" {
  name        = "AWSLoadBalancerControllerIAMPolicy"
  description = "IAM policy for AWS Load Balancer Controller"
  policy      = data.http.alb_iam_policy.response_body
}

# Trust policy for IRSA
data "aws_iam_policy_document" "alb_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

# IAM Role for ALB Controller
resource "aws_iam_role" "alb_controller_role" {
  name               = "aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_assume_role.json
}

resource "aws_iam_role_policy_attachment" "alb_controller_attach" {
  role       = aws_iam_role.alb_controller_role.name
  policy_arn = aws_iam_policy.alb_controller_policy.arn
}

##################################################
# Kubernetes ServiceAccount (with IRSA Annotation)
##################################################

resource "kubernetes_service_account" "alb_controller_sa" {
  provider = kubernetes.this

  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller_role.arn
    }
  }

  depends_on = [
    data.aws_eks_cluster.this,
    data.aws_eks_cluster_auth.this,
    aws_iam_role_policy_attachment.alb_controller_attach,
  ]
}

###############################################
# CRDs required by AWS Load Balancer Controller
###############################################

locals {
  alb_crd_files = {
    ingressclassparams  = "${path.module}/crds/elbv2.k8s.aws_ingressclassparams.yaml"
    targetgroupbindings = "${path.module}/crds/elbv2.k8s.aws_targetgroupbindings.yaml"
  }
}

resource "kubectl_manifest" "alb_crds" {
  provider = kubectl

  for_each  = local.alb_crd_files
  yaml_body = file(each.value)

  depends_on = [
    data.aws_eks_cluster.this,
    data.aws_eks_cluster_auth.this,
  ]
}

###############################################
# Helm Release – AWS Load Balancer Controller
###############################################

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  chart      = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  version    = "1.7.2"

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  # Use pre-created service account (IRSA)
  set {
    name  = "serviceAccount.create"
    value = false
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  skip_crds = true

  depends_on = [
    kubectl_manifest.alb_crds,
    kubernetes_service_account.alb_controller_sa,
    aws_iam_role_policy_attachment.alb_controller_attach
  ]
}
