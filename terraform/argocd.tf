# The bootstrap: the one thing in this repository that git cannot apply, because it is what
# applies the rest. Three objects. After this root has been applied once, Argo CD manages its own
# installation from ../argocd/values.yaml, and this root's only continuing job is to exist.

# Argo CD's namespace. Created here rather than by the chart so that the repository credential
# below can be written into it before Argo CD starts, and so that it can carry the label the
# shared Gateway requires of any namespace that attaches a route.
resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "shared-gateway-access" = "true"
    }
  }
}

# The GitHub App's private key, read from Secret Manager in kavoori-shared. Ephemeral: the value
# exists only while Terraform runs and is never written to state.
ephemeral "google_secret_manager_secret_version" "github_app_key" {
  project = local.shared_project_id
  secret  = "argocd-github-app-private-key"
  version = "latest"
}

# How Argo CD authenticates to GitHub. A credential template, in Argo CD's terms: it applies to
# every repository whose URL starts with the prefix below, so every deploy repository under the
# same account is covered by this one Secret and no further credential is ever added.
#
# Every field is written with the write-only argument, so nothing in this Secret enters state,
# and Terraform resends the values only when github_app_key_revision changes.
resource "kubernetes_secret_v1" "github_app_credentials" {
  metadata {
    name      = "github-app-kavoori"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repo-creds"
    }
  }

  type = "Opaque"

  data_wo = {
    type                    = "git"
    url                     = "https://github.com/kavoori"
    githubAppID             = tostring(var.github_app_id)
    githubAppInstallationID = tostring(var.github_app_installation_id)
    githubAppPrivateKey     = ephemeral.google_secret_manager_secret_version.github_app_key.secret_data
  }
  data_wo_revision = var.github_app_key_revision
}

# Argo CD itself, from the same values file its self-management Application reads. That file
# also carries the root Application, under extraObjects, so the bootstrap and the git copy define
# it identically and Argo CD takes it over without a difference to reconcile.
resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.9.2"

  values = [file("${path.module}/../argocd/values.yaml")]

  # Wait for every Deployment to be ready before reporting success. Ten minutes covers a cold
  # cluster pulling every image.
  wait    = true
  timeout = 600

  # The credential must exist before Argo CD's first attempt to read the repository, or the root
  # Application's first sync fails and waits for its retry.
  depends_on = [kubernetes_secret_v1.github_app_credentials]
}
