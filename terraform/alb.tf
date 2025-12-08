###############################################
# ALB Controller IAM (IRSA)
###############################################

data "aws_iam_policy_document" "alb_assume_role" {
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
        "system:serviceaccount:kube-system:aws-load-balancer-controller",
      ]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.cluster_name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_assume_role.json
}

###############################################################
# Download AWS LB Controller policy JSON (v2.7.1)
###############################################################

data "http" "aws_lb_json" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json"
}

###############################################################
# Additional missing permissions (DescribeLoadBalancers, etc.)
###############################################################

locals {
  alb_extra_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes"
        ]
        Resource = "*"
      }
    ]
  })
}

###############################################################
# Combine JSON via native JSON merge at the policy resource
###############################################################

resource "aws_iam_policy" "alb_controller" {
  name = "${var.cluster_name}-alb-controller-policy"

  # Merge upstream JSON + custom JSON
  policy = jsonencode(
    merge(
      jsondecode(data.http.aws_lb_json.response_body),
      jsondecode(local.alb_extra_json)
    )
  )
}

###############################################################
# Attach the final IAM policy to the IAM role
###############################################################

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

###############################################################
# AWS Load Balancer Controller Helm Chart
###############################################################

resource "helm_release" "aws_load_balancer_controller" {
  name             = "aws-load-balancer-controller"
  namespace        = "kube-system"
  create_namespace = false

  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.7.1"  # latest matching controller 2.7.1

  values = [
    yamlencode({
      clusterName = module.eks.cluster_name
      region      = var.region
      vpcId       = module.vpc.vpc_id

      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
        }
      }
    })
  ]

  depends_on = [
    aws_iam_role_policy_attachment.alb_controller,
    module.eks,   # ensure cluster exists
  ]
}
