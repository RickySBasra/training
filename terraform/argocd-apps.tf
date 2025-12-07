# We assume you already have:
# - module.eks
# - helm_release.argocd
# - kubernetes + helm providers configured as earlier

resource "kubernetes_namespace" "guestbook" {
  metadata {
    name = "guestbook"
  }

  depends_on = [
    module.eks,
    time_sleep.wait_for_rbac,
  ]
}

# ArgoCD Application: infra/argocd (ArgoCD ingress, etc.)
resource "kubernetes_manifest" "argocd_infra_app" {
  manifest = yamldecode(<<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: infra-argocd
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_GITHUB_USERNAME/YOUR_REPO.git
    targetRevision: main
    path: gitops/infra/argocd
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
YAML
  )

  depends_on = [
    helm_release.argocd,
    time_sleep.wait_for_rbac,
  ]
}

# ArgoCD Application: demo guestbook app
resource "kubernetes_manifest" "guestbook_app" {
  manifest = yamldecode(<<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_GITHUB_USERNAME/YOUR_REPO.git
    targetRevision: main
    path: gitops/apps/guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: guestbook
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
YAML
  )

  depends_on = [
    helm_release.argocd,
    kubernetes_namespace.guestbook,
    time_sleep.wait_for_rbac,
  ]
}
