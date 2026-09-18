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

# Argo CD itself, from the same values file its self-management Application reads, so the
# bootstrap and the git copy define Argo CD identically and Argo CD takes over its own objects
# without a difference to reconcile.
resource "helm_release" "argocd" {
  name      = "argocd"
  namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  # The chart as an OCI artifact, the same chart Argo's own chart repository serves. Named this
  # way, Helm fetches it directly and never consults the repository list on the machine running
  # Terraform, so the bootstrap behaves the same on every machine.
  repository = "oci://ghcr.io/argoproj/argo-helm"
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

# The root Application, as a second release. Helm checks every object in a release against the
# cluster before installing any of them, and an Argo CD Application is a kind that does not exist
# until the release above has installed Argo CD's definitions. So it cannot ride inside that
# release; it follows it. Terraform owns this object; Argo CD's self-management does not manage
# it, and it carries a different release label so Argo CD never mistakes it for its own.
resource "helm_release" "root_application" {
  name      = "argocd-root"
  namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  chart     = "${path.module}/root-application"

  set = [
    {
      name  = "repositoryURL"
      value = var.platform_repository_url
    }
  ]

  # On destroy, this release goes first, and Helm waits until the root Application is gone. It
  # is gone only once Argo CD has deleted the Applications it created, and the platform one only
  # once Google has taken the load balancer apart, which takes about five minutes. Argo CD is
  # still running throughout, because its own release is destroyed after this one. Ten minutes
  # leaves room for a slow load balancer teardown.
  wait    = true
  timeout = 600

  depends_on = [helm_release.argocd]
}
