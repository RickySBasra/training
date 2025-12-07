resource "aws_eks_access_entry" "admin_user" {
  cluster_name  = module.eks.cluster_name
  principal_arn = var.admin_principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin_access" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.admin_user.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# Give AWS 60–90s to propagate access into the cluster before
# Kubernetes/Helm try to connect.
resource "time_sleep" "wait_for_rbac" {
  depends_on = [
    aws_eks_access_policy_association.admin_access,
  ]

  create_duration = "90s"
}
