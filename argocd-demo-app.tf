resource "helm_release" "argocd" {
  # … your existing Argocd release …
}

resource "argocd_application" "guestbook" {
  metadata {
    name      = "guestbook"
    namespace = "argocd"
  }

  spec {
    destination {
      namespace = "guestbook"
      server    = "https://kubernetes.default.svc"
    }

    source {
      repo_url        = "https://github.com/YOUR_GITHUB_USERNAME/git-demo-apps.git"
      path            = "guestbook"
      target_revision = "main"
    }

    sync_policy {
      automated {
        prune    = true
        self_heal = true
      }
    }
  }

  depends_on = [
    helm_release.argocd
  ]
}
