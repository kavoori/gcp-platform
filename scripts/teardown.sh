#!/usr/bin/env bash
#
# Remove Argo CD and everything it applied from an environment's cluster, and prove the load
# balancer behind it is gone from Google before handing over to the cluster's own teardown.
#
#   scripts/teardown.sh dev --dry-run
#   scripts/teardown.sh dev
#
# This is the first half of tearing an environment down, and it has to be. Argo CD puts back
# from git anything deleted in the cluster, so a Gateway deleted while Argo CD runs is recreated
# within minutes, with a load balancer under it. terraform-gcp's teardown refuses to start while
# Argo CD is installed for exactly that reason, and names this script.
#
# What `terraform destroy` does here, and why it is enough in the normal case: it deletes the
# root Application first and waits for it to be gone. root carries Argo CD's cascade finalizer,
# so Argo CD, still running, deletes the Applications it created. The platform one carries the
# same finalizer, so its namespace and the Gateway go too, and Google takes the load balancer
# apart before the Application is allowed to disappear. Only then are Argo CD, its credential
# Secret and its namespace removed.
#
# What this script adds:
#
#   1. A refusal if the destroy would leave a stuck finalizer, caught before it starts rather
#      than as a timeout twenty minutes in.
#   2. The wait for Google's side. Kubernetes reports the Gateway deleted long before Google
#      has finished removing forwarding rules, proxies, backend services and endpoint groups,
#      and terraform-gcp's teardown cannot start until they are gone.
#   3. Proof: no namespace, no Application, no Gateway of ours left in the cluster, and nothing
#      of the load balancer left in the project.
#
# Measured on the first dev teardown:
#
#   root Application gone     1m18s   including the load balancer's forwarding rules
#   Argo CD uninstalled       +21s
#   argocd namespace gone     +2m07s  its endpoint groups being released
#
# The first run of this script, on a cluster that stayed up: destroy 3m12s, every Google
# resource already gone when Stage 2 looked, 3m20s in all.
#
# Exit codes:
#   0  everything gone
#   1  finished, but something was left behind
#   2  refused to start
#   3  terraform destroy failed

set -euo pipefail

# ---------------------------------------------------------------------------------------------
# Which environment, and what everything in it is called: read from the files that declare it,
# never written out here. See scripts/lib/platform.sh.
# ---------------------------------------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/platform.sh"

if [[ -z "${1:-}" || "${1:-}" == -* ]]; then
  echo "usage: scripts/teardown.sh <environment> [--dry-run] [--yes]" >&2
  exit 2
fi

load_platform "$1" "$ROOT_DIR"
shift

# Where the infrastructure repository is checked out. Only used to name the script that comes
# next. A sibling of this repository, by convention.
INFRA_DIR="${INFRA_DIR:-$(cd "$ROOT_DIR/.." && pwd)/terraform-gcp}"

LOG_FILE="${LOG_FILE:-/tmp/platform-teardown-$ENVIRONMENT-$(date +%Y%m%d-%H%M%S).log}"
STARTED_AT=$(date +%s)

# This script's own kubeconfig. Named by mktemp and then removed: gcloud refuses to parse a
# zero-length kubeconfig, warns, writes the empty file aside as a .backup and recreates it.
# Handing it a name that does not exist yet avoids the warning and the leftover file.
KUBECONFIG_FILE="$(mktemp -t platform-teardown-$ENVIRONMENT-kubeconfig)"
rm -f "$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"

DRY_RUN=false
ASSUME_YES=false
LEFTOVERS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --yes)     ASSUME_YES=true ;;
    *)         echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------------------------
log()  { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '%s  WARNING: %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { printf '%s  STOPPED: %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE" >&2; exit "${2:-2}"; }

stage() {
  log ""
  log "=============================================================================="
  log "$*"
  log "=============================================================================="
}

cleanup() { rm -f "$KUBECONFIG_FILE" "$KUBECONFIG_FILE".*.backup; }
trap cleanup EXIT

elapsed() {
  local now; now=$(date +%s)
  printf '%dm%02ds' $(( (now - STARTED_AT) / 60 )) $(( (now - STARTED_AT) % 60 ))
}

count() {
  local output
  output="$(eval "$1" 2>/dev/null || true)"
  if [[ -z "$output" ]]; then echo 0; else echo "$output" | grep -c . ; fi
}

# Wait until a listing command returns nothing. Bounded: a wait that never gives up hides the
# one thing worth knowing.
wait_until_empty() {
  local label="$1" attempts="$2" pause="$3" cmd="$4"
  local n remaining

  if $DRY_RUN; then
    log "dry run: $label — $(count "$cmd") now (not waiting)"
    return 0
  fi

  for ((n = 1; n <= attempts; n++)); do
    remaining="$(count "$cmd")"
    if [[ "$remaining" -eq 0 ]]; then
      log "$label: gone (at $(elapsed))"
      return 0
    fi
    log "$label: $remaining left ($n/$attempts)"
    sleep "$pause"
  done

  warn "$label: still $remaining after $((attempts * pause))s"
  LEFTOVERS+=("$label")
  return 1
}

expect_empty() {
  local label="$1" cmd="$2"
  local remaining
  remaining="$(count "$cmd")"

  if $DRY_RUN; then
    log "  inventory  $label ($remaining)"
    return 0
  fi

  if [[ "$remaining" -eq 0 ]]; then
    log "  ok       $label"
  else
    log "  LEFT     $label ($remaining)"
    eval "$cmd" | sed 's/^/             /' | tee -a "$LOG_FILE" || true
    LEFTOVERS+=("$label")
  fi
}

# ---------------------------------------------------------------------------------------------
# Stage 0 — refuse to start if anything is wrong
# ---------------------------------------------------------------------------------------------
stage "Stage 0 — checks before anything is deleted ($ENVIRONMENT)"
log "log file: $LOG_FILE"
$DRY_RUN && log "DRY RUN: nothing will be deleted."

for tool in gcloud terraform kubectl jq; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done
command -v gke-gcloud-auth-plugin >/dev/null \
  || die "gke-gcloud-auth-plugin is not on PATH — run: gcloud components install gke-gcloud-auth-plugin"

[[ "$STATE_PREFIX" == "$ENVIRONMENT-platform" ]] \
  || die "$TF_DIR/backend.tf stores state under '$STATE_PREFIX', not '$ENVIRONMENT-platform'"

gcloud auth print-access-token >/dev/null 2>&1 \
  || die "gcloud is not logged in — run: gcloud auth login"
gcloud auth application-default print-access-token >/dev/null 2>&1 \
  || die "Terraform's credentials are missing or expired — run: gcloud auth application-default login"
gcloud projects describe "$PROJECT" --format="value(projectId)" >/dev/null 2>&1 \
  || die "cannot read project $PROJECT"

if gcloud storage ls "gs://$STATE_BUCKET/$STATE_PREFIX/default.tflock" >/dev/null 2>&1; then
  warn "a Terraform state lock exists for $STATE_PREFIX."
  warn "if nothing else is running, clear it with:"
  warn "  terraform -chdir=terraform force-unlock <LOCK_ID>"
  die  "refusing to start while the state is locked"
fi

# The cluster. If it is already gone there is nothing to remove from it, and the only job left
# is telling Terraform so.
cluster_status="$(gcloud container clusters describe "$CLUSTER" --region="$REGION" --project="$PROJECT" --format='value(status)' 2>/dev/null || true)"
[[ -n "$cluster_status" ]] \
  || die "cluster $CLUSTER does not exist in $PROJECT — nothing to tear down. If this root's state still lists resources, remove them with: terraform -chdir=terraform state rm <address>"

# init runs in a dry run too. It downloads providers and configures the backend; it destroys
# nothing and writes no state.
if [[ ! -d "$TF_DIR/.terraform" ]]; then
  log "terraform is not initialised here; running init"
  terraform -chdir="$TF_DIR" init -input=false >>"$LOG_FILE" 2>&1 \
    || die "terraform init failed — see $LOG_FILE"
fi

gcloud container clusters get-credentials "$CLUSTER" \
  --region="$REGION" --project="$PROJECT" --dns-endpoint >>"$LOG_FILE" 2>&1 \
  || die "could not reach the cluster $CLUSTER"

log "environment: $ENVIRONMENT"
log "project:     $PROJECT"
log "cluster:     $CLUSTER"

# The destroy relies on Argo CD's controller to process the cascade. If the controller is not
# running, the root Application's finalizer is never removed, the Helm uninstall waits its full
# timeout, and the namespace deletion after it hangs on the same finalizer. Find out now.
if kubectl get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  controller_ready="$(kubectl -n "$ARGOCD_NAMESPACE" get statefulset argocd-application-controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [[ "${controller_ready:-0}" -ge 1 ]]; then
    log "argo cd:     controller running, will process the cascade"
  else
    warn "the Argo CD application controller is not running, so the destroy's cascade would hang"
    warn "on the root Application's finalizer. Either bring it back:"
    warn "  scripts/build.sh $ENVIRONMENT"
    warn "or remove the finalizers by hand and delete the Gateway yourself, then run this again:"
    for app in "${APPLICATIONS[@]}"; do
      warn "  kubectl --context=$ENVIRONMENT -n $ARGOCD_NAMESPACE patch application $app --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
    done
    warn "  kubectl --context=$ENVIRONMENT -n $GATEWAY_NAMESPACE delete gateway $GATEWAY_NAME"
    die "refusing to start a destroy that would hang"
  fi
else
  log "argo cd:     namespace $ARGOCD_NAMESPACE absent; the destroy will only update state"
fi

if ! $DRY_RUN && ! $ASSUME_YES; then
  log ""
  log "This removes Argo CD from $CLUSTER and, through it, the platform namespace, the Gateway"
  log "and the load balancer in $PROJECT. Every application Argo CD deployed goes with them."
  read -r -p "Type the project name to continue: " answer
  [[ "$answer" == "$PROJECT" ]] || die "not confirmed"
fi

# ---------------------------------------------------------------------------------------------
# Stage 1 — terraform destroy
#
# Four resources, in reverse order of creation: the root Application's release, Argo CD's
# release, the credential Secret, the namespace. The first waits for the cascade described at
# the top of this file, which is where the time goes.
# ---------------------------------------------------------------------------------------------
stage "Stage 1 — terraform destroy (about 4 minutes)"

if $DRY_RUN; then
  terraform -chdir="$TF_DIR" plan -destroy -input=false -lock-timeout=60s 2>&1 | tee -a "$LOG_FILE"
else
  terraform -chdir="$TF_DIR" destroy -input=false -auto-approve -lock-timeout=60s 2>&1 | tee -a "$LOG_FILE" \
    || die "terraform destroy failed — see $LOG_FILE. If it timed out on the root release, an Application is stuck on its finalizer: kubectl --context=$ENVIRONMENT -n $ARGOCD_NAMESPACE get applications" 3
  log "terraform finished at $(elapsed)"
fi

# ---------------------------------------------------------------------------------------------
# Stage 2 — Google's side of the load balancer
#
# The cascade waits for the Gateway object to be gone, and Google removes its finalizer once the
# forwarding rules are deleted. The rest of the load balancer is removed afterwards, and
# asynchronously. terraform-gcp's teardown waits for the same list; finding it already empty
# there is the point.
# ---------------------------------------------------------------------------------------------
stage "Stage 2 — waiting for the load balancer to be gone from $PROJECT"

# Measured: gone before the root release finished. Allowed 10 minutes.
wait_until_empty "forwarding rules" 40 15 \
  "gcloud compute forwarding-rules list --project=$PROJECT --format='value(name)'" || true
wait_until_empty "target proxies" 20 15 \
  "gcloud compute target-https-proxies list --project=$PROJECT --format='value(name)'; gcloud compute target-http-proxies list --project=$PROJECT --format='value(name)'" || true
wait_until_empty "url maps" 20 15 \
  "gcloud compute url-maps list --project=$PROJECT --format='value(name)'" || true
wait_until_empty "backend services" 20 15 \
  "gcloud compute backend-services list --project=$PROJECT --format='value(name)'" || true
wait_until_empty "health checks" 20 15 \
  "gcloud compute health-checks list --project=$PROJECT --format='value(name)'" || true
# Released about 90 seconds after the Service behind them is deleted.
wait_until_empty "network endpoint groups" 20 15 \
  "gcloud compute network-endpoint-groups list --project=$PROJECT --format='value(name)'" || true

# ---------------------------------------------------------------------------------------------
# Stage 3 — prove it
# ---------------------------------------------------------------------------------------------
if $DRY_RUN; then
  stage "Stage 3 — inventory of what a real run would remove"
else
  stage "Stage 3 — what is left"
fi

expect_empty "namespace $ARGOCD_NAMESPACE"      "kubectl get namespace $ARGOCD_NAMESPACE -o name"
expect_empty "namespace $GATEWAY_NAMESPACE"     "kubectl get namespace $GATEWAY_NAMESPACE -o name"
expect_empty "Argo CD Applications"             "kubectl get applications --all-namespaces -o name"
expect_empty "Gateways"                         "kubectl get gateways --all-namespaces -o name"
expect_empty "HTTPRoutes"                       "kubectl get httproutes --all-namespaces -o name"
expect_empty "resources in this root's state"   "terraform -chdir=$TF_DIR state list"

# ---------------------------------------------------------------------------------------------
# Stage 4 — what survives on purpose
# ---------------------------------------------------------------------------------------------
stage "Stage 4 — what is still there, deliberately"
log "  the cluster $CLUSTER, and every Google resource under it: terraform-gcp's to remove"
log "  Argo CD's custom resource definitions, kept by the chart; they go with the cluster"
log "  the GitHub App's key in Secret Manager in $SHARED_PROJECT"
log "  this root's state file, now empty, under gs://$STATE_BUCKET/$STATE_PREFIX/"

stage "Result"
log "elapsed: $(elapsed)"

if $DRY_RUN; then
  log "Dry run: nothing was deleted. A real run removes what the inventory above lists."
  log "Then: $INFRA_DIR/scripts/teardown.sh $ENVIRONMENT"
  log "Full log: $LOG_FILE"
  exit 0
fi

if [[ ${#LEFTOVERS[@]} -eq 0 ]]; then
  log "Nothing of the platform left behind."
  log "Next: $INFRA_DIR/scripts/teardown.sh $ENVIRONMENT"
  log "Full log: $LOG_FILE"
  exit 0
fi

log "Left behind, and worth looking at:"
for item in "${LEFTOVERS[@]}"; do
  log "  - $item"
done
log "Full log: $LOG_FILE"
exit 1
