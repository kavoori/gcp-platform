# Three providers: Google to find the cluster and read the secret, and Kubernetes and Helm to
# put things into the cluster.

locals {
  project_id        = "kavoori-dev"
  shared_project_id = "kavoori-shared"
  region            = "us-east1"
  cluster_name      = "dev-gke"
}

provider "google" {
  project = local.project_id
  region  = local.region

  # Charge every API call to kavoori-dev, including the read of the secret in kavoori-shared. That
  # is why Secret Manager has to be switched on in kavoori-dev as well as in kavoori-shared.
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
