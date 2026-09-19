#!/usr/bin/env bash
#
# Work out what the platform is called, by reading the files that declare it.
#
# Sourced by build.sh and teardown.sh:
#
#   source "$ROOT_DIR/scripts/lib/platform.sh"
#   load_platform dev "$ROOT_DIR"
#
# Every name the scripts need is already written down once, in the file that owns it:
#
#   terraform/providers.tf   environment name, project, shared project, region, GitHub owner
#   terraform/backend.tf     state bucket and prefix
#   terraform/argocd.tf      the Secret Manager secret holding the GitHub App's key
#   argocd/values.yaml       the hostname Argo CD answers on
#   platform/values.yaml     the environment name and project the platform chart renders from
#   apps/*.yaml              the Applications Argo CD creates from the root
#
# Everything else is derived from the environment's name, the same way terraform-gcp derives
# every resource name: the cluster is <environment>-gke, the address <environment>-gateway.
#
# Reading them here means a rename happens in one place and the scripts follow. A script that
# carries its own copy of a project id is a script that will one day be pointed at the wrong
# project by a stale line nobody remembered to change.
#
# Not `terraform output`: outputs exist only after an apply, and build.sh runs before one.

# Pull a quoted scalar out of an HCL file: `key = "value"` -> value. First match wins.
hcl_value() {
  local key="$1" file="$2"
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -1
}

# Pull a plain scalar out of a YAML file: `key: value` -> value, at any indentation. First match
# wins, so the caller names a key that appears once in that file, or first for the right reason.
yaml_value() {
  local key="$1" file="$2"
  sed -n "s/^[[:space:]]*${key}:[[:space:]]*\"\{0,1\}\([^\"#]*\)\"\{0,1\}[[:space:]]*$/\1/p" "$file" | head -1
}

# Read one required value, or stop. A script that carries on with an empty project id changes
# nothing and reports success, which is the worst of both.
require_value() {
  local what="$1" value="$2" file="$3"
  [[ -n "$value" ]] || {
    echo "STOPPED: no '$what' found in $file" >&2
    echo "         the scripts read the platform's identity out of that file" >&2
    exit 2
  }
  printf '%s' "$value"
}

# Sets every name the scripts use. Call once, early.
load_platform() {
  local env="$1" root="$2"

  ENVIRONMENT="$env"
  TF_DIR="$root/terraform"

  [[ -f "$TF_DIR/providers.tf" ]] || {
    echo "STOPPED: $TF_DIR/providers.tf does not exist" >&2
    exit 2
  }

  # --- terraform/ ------------------------------------------------------------------------------
  # The environment named on the command line must be the one this root declares. Two names for
  # one thing is how a script ends up checking a cluster that is not the one being installed into.
  local declared_environment
  declared_environment="$(require_value environment "$(hcl_value environment "$TF_DIR/providers.tf")" "$TF_DIR/providers.tf")"
  [[ "$declared_environment" == "$env" ]] || {
    echo "STOPPED: $TF_DIR/providers.tf declares environment '$declared_environment', not '$env'" >&2
    exit 2
  }

  PROJECT="$(require_value project_id "$(hcl_value project_id "$TF_DIR/providers.tf")" "$TF_DIR/providers.tf")"
  SHARED_PROJECT="$(require_value shared_project_id "$(hcl_value shared_project_id "$TF_DIR/providers.tf")" "$TF_DIR/providers.tf")"
  REGION="$(require_value region "$(hcl_value region "$TF_DIR/providers.tf")" "$TF_DIR/providers.tf")"
  STATE_BUCKET="$(require_value bucket "$(hcl_value bucket "$TF_DIR/backend.tf")" "$TF_DIR/backend.tf")"
  STATE_PREFIX="$(require_value prefix "$(hcl_value prefix "$TF_DIR/backend.tf")" "$TF_DIR/backend.tf")"
  GITHUB_APP_KEY_SECRET="$(require_value secret "$(hcl_value secret "$TF_DIR/argocd.tf")" "$TF_DIR/argocd.tf")"

  # --- argocd/ ---------------------------------------------------------------------------------
  ARGOCD_NAMESPACE="argocd"
  ARGOCD_HOSTNAME="$(require_value domain "$(yaml_value domain "$root/argocd/values.yaml")" "$root/argocd/values.yaml")"

  # --- platform/ -------------------------------------------------------------------------------
  # The chart renders every name from these two values. They must agree with terraform/ and with
  # terraform-gcp's environments/<env>/main.tf, which created what they name.
  local chart_environment chart_project
  chart_environment="$(require_value environment "$(yaml_value environment "$root/platform/values.yaml")" "$root/platform/values.yaml")"
  chart_project="$(require_value projectId "$(yaml_value projectId "$root/platform/values.yaml")" "$root/platform/values.yaml")"
  [[ "$chart_environment" == "$env" && "$chart_project" == "$PROJECT" ]] || {
    echo "STOPPED: platform/values.yaml names environment '$chart_environment' in project '$chart_project';" >&2
    echo "         terraform/providers.tf names '$env' in '$PROJECT'. They must agree." >&2
    exit 2
  }

  # --- names derived from the environment, as the module and the chart derive them -----------
  CLUSTER="$env-gke"
  GATEWAY_NAME="web"
  GATEWAY_NAMESPACE="platform"
  GATEWAY_ADDRESS="$env-gateway"
  CERTIFICATE_MAP="$env-certificates"

  # --- apps/ -----------------------------------------------------------------------------------
  # The Applications the root creates: one per file. Plus root itself, which Terraform creates.
  APPLICATIONS=("root")
  local file
  for file in "$root"/apps/*.yaml; do
    APPLICATIONS+=("$(require_value name "$(yaml_value name "$file")" "$file")")
  done
}
