resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "6.7.12"

  skip_crds = true
  timeout   = 600

  values = []

  depends_on = [
    module.eks,
    time_sleep.wait_for_rbac
    # helm_release.aws_load_balancer_controller,
  ]
}
