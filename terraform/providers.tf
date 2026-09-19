# Three providers: Google to find the cluster and read the secret, and Kubernetes and Helm to
# put things into the cluster.

# What this root is called, and where it lives: the one place in terraform/ that names anything.
# The scripts read these lines. Moving this root to another environment, project or GitHub
# owner is an edit here, in backend.tf, which cannot read locals, and in ../platform/values.yaml,
# which the platform chart reads.
locals {
  # The environment's name, the same one terraform-gcp's environments/<name>/ uses. Every
  # resource name derives from it: the cluster is <name>-gke.
  environment = "dev"

  project_id        = "kavoori-dev"
  shared_project_id = "kavoori-shared"
  region            = "us-east1"

  # The GitHub account or organization Argo CD reads repositories from.
  github_owner = "kavoori"

  cluster_name = "${local.environment}-gke"
}

provider "google" {
  project = local.project_id
  region  = local.region

  # Charge every API call to the environment's project, including the read of the secret in the
  # shared project. That is why Secret Manager has to be switched on in both.
  user_project_override = true
  billing_project       = local.project_id
}

# The cluster, found by name. This root never reads terraform-gcp's state. If the cluster does
# not exist, this fails at plan time with a clear message, which is the right time to find out.
data "google_container_cluster" "dev" {
  name     = local.cluster_name
  location = local.region
  project  = local.project_id
}

# A short-lived access token from the same Google login Terraform is already using. Ephemeral:
# it exists during plan and apply and is never written to state.
ephemeral "google_client_config" "current" {}

locals {
  # The control plane's DNS endpoint, the only endpoint the cluster has. Its certificate is
  # issued by a public authority, so no cluster certificate is needed to trust it.
  cluster_host = "https://${data.google_container_cluster.dev.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint}"
}

provider "kubernetes" {
  host  = local.cluster_host
  token = ephemeral.google_client_config.current.access_token
}

provider "helm" {
  kubernetes = {
    host  = local.cluster_host
    token = ephemeral.google_client_config.current.access_token
  }
}
