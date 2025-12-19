resource "kubernetes_manifest" "guestbook" {
  manifest = yamldecode(<<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-options: CreateNamespace=true
spec:
  project: default
  source:
    repoURL: https://github.com/RickySBasra/training.git
    path: gitops/apps/guestbook
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: guestbook
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
  )

  depends_on = [
    data.terraform_remote_state.infra, # ensures cluster + argocd exist
  ]
}
