#!/usr/bin/env bash
#
# Install Argo CD onto an environment's cluster, and prove the platform it then applies from git
# is answering from the public internet before claiming success.
#
#   scripts/build.sh dev
#   scripts/build.sh dev --dry-run
#
# This script can only create. It contains no destroy and no delete; those belong to the
# teardown, and keeping the two apart is what makes each safe to run without reading it first.
#
# Why a script at all, when the Terraform root is four resources: `terraform apply` returns when
# Argo CD's pods are ready and the root Application exists. That is minutes before anything is
# usable. Argo CD still has to read git and create the other Applications, Google has to build a
# load balancer from the Gateway one of them applies, the backend has to pass its first health
# check, and Google's edge has to start answering. Nothing in Terraform's output marks any of
# that. So the last thing this does is make a real HTTPS request to Argo CD and show the answer.
#
# The cluster must already exist. It is built by terraform-gcp's build script, and this one
# refuses to start if it is missing, naming that script rather than failing inside a data source
# with an error about the wrong thing.
#
# Measured on the first dev build, which is where every timeout below comes from:
#
#   terraform apply             1m40s    Argo CD's images pulled onto a cold cluster
#   root Synced                 +17s     it syncs on creation
#   argocd, platform Synced     +1m34s   argocd takes over its own objects, platform applies the Gateway
#   Gateway Programmed          +2m35s   endpoint groups and forwarding rules were up within seconds
#   first 200                   +3m23s   the load balancer answered 404 until the route was attached
#   total                       9m29s
#
# Safe to run again at any point. Terraform converges, and every check is a read.
#
# Exit codes:
#   0  built, and Argo CD answering
#   1  built, but something never became ready
#   2  refused to start, or refused a plan that would destroy something
#   3  terraform plan or apply failed

set -euo pipefail

# ---------------------------------------------------------------------------------------------
# Which environment, and what everything in it is called: read from the files that declare it,
# never written out here. See scripts/lib/platform.sh.
# ---------------------------------------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/platform.sh"

if [[ -z "${1:-}" || "${1:-}" == -* ]]; then
  echo "usage: scripts/build.sh <environment> [--dry-run] [--yes]" >&2
  exit 2
fi

load_platform "$1" "$ROOT_DIR"
shift

# Where the infrastructure repository is checked out. Only used to name the script that builds
# the cluster when it is missing. A sibling of this repository, by convention.
INFRA_DIR="${INFRA_DIR:-$(cd "$ROOT_DIR/.." && pwd)/terraform-gcp}"

LOG_FILE="${LOG_FILE:-/tmp/platform-build-$ENVIRONMENT-$(date +%Y%m%d-%H%M%S).log}"
STARTED_AT=$(date +%s)

# This script's own kubeconfig, so it can never repoint your shell or write into ~/.kube.
#
# mktemp is used for the name, then the file is removed. gcloud refuses to parse a zero-length
# kubeconfig: it warns, writes the empty file aside as a .backup, and recreates it. Handing it a
# name that does not exist yet skips all of that. The path is still reserved against collision,
# because mktemp created it once.
KUBECONFIG_FILE="$(mktemp -t platform-build-$ENVIRONMENT-kubeconfig)"
rm -f "$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"

# The plan Stage 1 checks and then applies. Outside the repository, so a plan is never committed.
PLAN_FILE="$(mktemp -t platform-build-$ENVIRONMENT-plan)"

DRY_RUN=false
ASSUME_YES=false
FAILURES=()
SERVED_CODE=""

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

# The glob catches the dated .backup gcloud leaves beside the kubeconfig if it ever rewrites it.
cleanup() { rm -f "$KUBECONFIG_FILE" "$KUBECONFIG_FILE".*.backup "$PLAN_FILE"; }
trap cleanup EXIT

elapsed() {
  local now; now=$(date +%s)
  printf '%dm%02ds' $(( (now - STARTED_AT) / 60 )) $(( (now - STARTED_AT) % 60 ))
}

# Wait until a command's output matches what is wanted.
#
#   wait_for "<what>" <attempts> <seconds> "<command>" "<expected>"
#
# A leading "=" on the expected value requires the whole output to equal it. Counts need that:
# "3" as a substring also matches 13.
#
# Every wait in this script goes through here. There is no bare sleep anywhere, because a sleep
# that is not checking anything is a guess about someone else's system.
wait_for() {
  local label="$1" attempts="$2" pause="$3" cmd="$4" want="$5"
  local n got matched

  if $DRY_RUN; then
    log "dry run: would wait for $label"
    return 0
  fi

  for ((n = 1; n <= attempts; n++)); do
    got="$(eval "$cmd" 2>/dev/null || true)"
    matched=false
    if [[ "$want" == "="* ]]; then
      [[ "$got" == "${want#=}" ]] && matched=true
    else
      [[ "$got" == *"$want"* ]] && matched=true
    fi

    if $matched; then
      log "$label: ready (at $(elapsed))"
      return 0
    fi
    log "$label: waiting, saw '${got:-nothing}' ($n/$attempts)"
    sleep "$pause"
  done

  warn "$label: never became ready after $((attempts * pause))s"
  FAILURES+=("$label")
  return 1
}

# ---------------------------------------------------------------------------------------------
# Stage 0 — refuse to start if anything is wrong
# ---------------------------------------------------------------------------------------------
stage "Stage 0 — checks before anything is created ($ENVIRONMENT)"
log "log file: $LOG_FILE"
$DRY_RUN && log "DRY RUN: nothing will be created."

for tool in gcloud terraform kubectl jq dig curl; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

# kubectl cannot authenticate to GKE without this. Kubernetes 1.26 removed every in-tree cloud
# auth provider, so the kubeconfig names an external binary instead. Without it, get-credentials
# succeeds and the first kubectl command fails with "no Auth Provider found" — which reads as a
# permissions problem and is not one.
command -v gke-gcloud-auth-plugin >/dev/null \
  || die "gke-gcloud-auth-plugin is not on PATH — run: gcloud components install gke-gcloud-auth-plugin"

# The environment named on the command line and the state prefix in the backend must agree, or
# this run applies one environment's platform with another environment's state file.
[[ "$STATE_PREFIX" == "$ENVIRONMENT-platform" ]] \
  || die "$TF_DIR/backend.tf stores state under '$STATE_PREFIX', not '$ENVIRONMENT-platform'"

gcloud auth print-access-token >/dev/null 2>&1 \
  || die "gcloud is not logged in — run: gcloud auth login"

# Terraform reads a different set of credentials from gcloud's own, and they expire separately
# under the Workspace session limit. Failing here beats failing two minutes into an apply with an
# invalid_rapt error.
gcloud auth application-default print-access-token >/dev/null 2>&1 \
  || die "Terraform's credentials are missing or expired — run: gcloud auth application-default login"

gcloud projects describe "$PROJECT" --format="value(projectId)" >/dev/null 2>&1 \
  || die "cannot read project $PROJECT"

# A lock left behind by an interrupted run blocks every later command with an error that does not
# explain itself. Catch it here, where the fix can be printed.
if gcloud storage ls "gs://$STATE_BUCKET/$STATE_PREFIX/default.tflock" >/dev/null 2>&1; then
  warn "a Terraform state lock exists for $STATE_PREFIX."
  warn "if nothing else is running, clear it with:"
  warn "  terraform -chdir=terraform force-unlock <LOCK_ID>"
  die  "refusing to start while the state is locked"
fi

# The cluster this root installs into. Its own Terraform never creates it, only finds it, and a
# data source that finds nothing fails with a message about the data source. Say the real thing.
cluster_status="$(gcloud container clusters describe "$CLUSTER" --region="$REGION" --project="$PROJECT" --format='value(status)' 2>/dev/null || true)"
[[ -n "$cluster_status" ]] \
  || die "cluster $CLUSTER does not exist in $PROJECT — build it first: $INFRA_DIR/scripts/build.sh $ENVIRONMENT"
[[ "$cluster_status" == "RUNNING" ]] \
  || die "cluster $CLUSTER is $cluster_status, not RUNNING — wait for it, or finish the build in $INFRA_DIR"

# What the Gateway will name, by name. Both are terraform-gcp's resources. If either is missing
# the Gateway never programs and never says why, so find out now and say which repository owns it.
gcloud compute addresses describe "$GATEWAY_ADDRESS" --global --project="$PROJECT" --format='value(address)' >/dev/null 2>&1 \
  || die "reserved address $GATEWAY_ADDRESS does not exist in $PROJECT — it is created by $INFRA_DIR"
gcloud certificate-manager maps describe "$CERTIFICATE_MAP" --project="$PROJECT" --format='value(name)' >/dev/null 2>&1 \
  || die "certificate map $CERTIFICATE_MAP does not exist in $PROJECT — it is created by $INFRA_DIR"

# The one credential. Terraform reads its latest version during the apply; a secret with no
# enabled version fails inside the ephemeral read, minutes in. The key is bootstrap step 5 in
# terraform-gcp's docs/bootstrap.md.
enabled_versions="$(gcloud secrets versions list "$GITHUB_APP_KEY_SECRET" --project="$SHARED_PROJECT" --filter='state=ENABLED' --format='value(name)' 2>/dev/null | grep -c . || true)"
[[ "$enabled_versions" -ge 1 ]] \
  || die "secret $GITHUB_APP_KEY_SECRET in $SHARED_PROJECT has no enabled version — add the GitHub App's key first"

log "environment: $ENVIRONMENT"
log "project:     $PROJECT"
log "cluster:     $CLUSTER"
log "terraform:   $TF_DIR"
log "argo cd:     https://$ARGOCD_HOSTNAME"
log "gateway:     $GATEWAY_NAMESPACE/$GATEWAY_NAME on $GATEWAY_ADDRESS"

if ! $DRY_RUN && ! $ASSUME_YES; then
  log ""
  log "This installs Argo CD into $CLUSTER and lets it apply the platform from git, which builds"
  log "one external load balancer in $PROJECT at roughly \$0.025 an hour."
  read -r -p "Type the project name to continue: " answer
  [[ "$answer" == "$PROJECT" ]] || die "not confirmed"
fi

# ---------------------------------------------------------------------------------------------
# Stage 1 — Terraform
#
# The plan is written to a file, machine-checked to contain nothing but creates and updates, and
# that file is applied. Applying a saved plan performs exactly the actions checked and re-reads
# no configuration. A build never destroys, and a replacement is a decision for a human reading
# a plan, not for a script running unattended.
# ---------------------------------------------------------------------------------------------
stage "Stage 1 — terraform apply (about 2 minutes)"

# init runs in a dry run too. It downloads providers and configures the backend; it creates
# nothing and writes no state.
if [[ ! -d "$TF_DIR/.terraform" ]]; then
  log "terraform is not initialised here; running init"
  terraform -chdir="$TF_DIR" init -input=false >>"$LOG_FILE" 2>&1 \
    || die "terraform init failed — see $LOG_FILE"
fi

terraform -chdir="$TF_DIR" plan -input=false -lock-timeout=60s -out="$PLAN_FILE" >>"$LOG_FILE" 2>&1 \
  || die "terraform plan failed — see $LOG_FILE" 3

# A replace is reported as two actions on one resource, ["delete","create"], so filtering to the
# actions a build may take catches replacements as well as plain deletions.
FORBIDDEN="$(terraform -chdir="$TF_DIR" show -json "$PLAN_FILE" \
  | jq -r '[.resource_changes[]?.change.actions[]?] | unique
           | map(select(. != "no-op" and . != "create" and . != "update" and . != "read"))
           | join(",")')"

if [[ -n "$FORBIDDEN" ]]; then
  terraform -chdir="$TF_DIR" show "$PLAN_FILE" | tee -a "$LOG_FILE"
  warn "this plan would '$FORBIDDEN' existing resources."
  warn "a build never destroys. If the change is intended, read that plan and apply it yourself."
  die  "refusing to apply"
fi

log "plan: only creates and updates"

if $DRY_RUN; then
  terraform -chdir="$TF_DIR" show "$PLAN_FILE" | tee -a "$LOG_FILE"
else
  terraform -chdir="$TF_DIR" apply -input=false "$PLAN_FILE" 2>&1 | tee -a "$LOG_FILE" \
    || die "terraform apply failed — see $LOG_FILE" 3
  log "terraform finished at $(elapsed)"
fi

# ---------------------------------------------------------------------------------------------
# Stage 2 — Argo CD reads git
#
# Terraform created one Application, root. Argo CD syncs it on creation, which creates the
# Applications in apps/, and each of those syncs in turn. Synced means git and the cluster
# agree; Healthy means what was applied is up. Both, for every Application, is the platform
# existing. Measured: root in 17 seconds, the other two 1m34s later. Allowed ten, because a first sync that
# finds the GitHub credential not yet usable waits for Argo CD's retry.
# ---------------------------------------------------------------------------------------------
stage "Stage 2 — Argo CD applying the platform from git"

if $DRY_RUN; then
  log "would run: gcloud container clusters get-credentials $CLUSTER --region=$REGION --project=$PROJECT --dns-endpoint"
  log "would wait for Applications: ${APPLICATIONS[*]}"
else
  gcloud container clusters get-credentials "$CLUSTER" \
    --region="$REGION" --project="$PROJECT" --dns-endpoint >>"$LOG_FILE" 2>&1 \
    || die "could not fetch credentials for $CLUSTER"
  log "credentials written to this script's own kubeconfig; ~/.kube untouched"

  for app in "${APPLICATIONS[@]}"; do
    wait_for "application $app Synced and Healthy" 40 15 \
      "kubectl -n $ARGOCD_NAMESPACE get application $app -o jsonpath='{.status.sync.status}/{.status.health.status}'" \
      "=Synced/Healthy" || true
  done
fi

# ---------------------------------------------------------------------------------------------
# Stage 3 — what Google builds from the Gateway
# ---------------------------------------------------------------------------------------------
stage "Stage 3 — waiting for the load balancer"

# One network endpoint group per zone, built from the Service behind the first route. The first
# thing the Gateway controller creates. Measured: present within a second of the platform
# Application reporting Synced.
wait_for "network endpoint groups" 30 20 \
  "test \$(gcloud compute network-endpoint-groups list --project=$PROJECT --format='value(name)' | grep -c .) -ge 3 && echo yes || echo no" \
  "=yes" || true

# The last thing it creates. Until the 443 rule exists the address answers nothing.
# Measured: present a second after the endpoint groups; the Gateway reported Programmed 2m35s later.
wait_for "forwarding rule on 443" 45 20 \
  "gcloud compute forwarding-rules list --project=$PROJECT --format='value(portRange)' | tr '\n' ' '" \
  "443" || true

if ! $DRY_RUN; then
  if kubectl -n "$GATEWAY_NAMESPACE" wait --for=condition=Programmed "gateway/$GATEWAY_NAME" --timeout=900s >>"$LOG_FILE" 2>&1; then
    log "gateway: Programmed, address $(kubectl -n "$GATEWAY_NAMESPACE" get gateway "$GATEWAY_NAME" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)"
  else
    warn "Gateway $GATEWAY_NAMESPACE/$GATEWAY_NAME never reported Programmed"
    FAILURES+=("Gateway Programmed")
  fi

  # A rebuilt environment gets a new address, and the wildcard record is rewritten to match.
  # Anything holding the old answer keeps it until the 300-second TTL expires, which looks
  # exactly like a broken load balancer. Checking this separately names the real cause.
  expected_ip="$(gcloud compute addresses describe "$GATEWAY_ADDRESS" --global --project="$PROJECT" --format='value(address)' 2>/dev/null || true)"
  if [[ -n "$expected_ip" ]]; then
    wait_for "DNS resolves $ARGOCD_HOSTNAME to $expected_ip" 20 20 \
      "dig +short $ARGOCD_HOSTNAME | tail -1" \
      "=$expected_ip" || true
  fi
fi

# ---------------------------------------------------------------------------------------------
# Stage 4 — the only check that matters
#
# Everything above can be correct while requests still fail, because a new load balancer has to
# reach Google's edge sites before any of them answer, and then the backend has to pass its first
# health check. Until the first, the connection is reset; until the second, the load balancer
# answers "fault filter abort", and until the route is attached at the edge it answers 404.
# Measured: 404 for 3m02s after the Gateway reported Programmed, then 200.
#
# Argo CD's login page is the request. A 200 from it has travelled DNS, the edge, TLS with a
# certificate nobody here has ever held, the URL map, a backend service, an endpoint group, and
# a pod on a node with no public address.
# ---------------------------------------------------------------------------------------------
stage "Stage 4 — is Argo CD answering from the internet?"

if $DRY_RUN; then
  log "dry run: would request https://$ARGOCD_HOSTNAME until it returns 200"
else
  for ((try = 1; try <= 30; try++)); do
    code="$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' "https://$ARGOCD_HOSTNAME" || true)"
    if [[ "$code" == "200" ]]; then
      SERVED_CODE="$code"
      log "https://$ARGOCD_HOSTNAME: 200 (at $(elapsed))"
      break
    fi
    log "https://$ARGOCD_HOSTNAME: waiting, got ${code:-no response} ($try/30)"
    sleep 20
  done

  [[ -n "$SERVED_CODE" ]] || FAILURES+=("https://$ARGOCD_HOSTNAME serving")

  # Plain HTTP must redirect and never serve. A 200 here would mean the login page is being
  # answered unencrypted.
  redirect="$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' "http://$ARGOCD_HOSTNAME" || true)"
  if [[ "$redirect" == "301" ]]; then
    log "http://$ARGOCD_HOSTNAME: 301, as it should be"
  else
    warn "http://$ARGOCD_HOSTNAME returned $redirect, expected 301"
    FAILURES+=("HTTP to HTTPS redirect")
  fi
fi

# ---------------------------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------------------------
stage "Result"
log "elapsed: $(elapsed)"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  log "built, but these never became ready:"
  for item in "${FAILURES[@]}"; do
    log "  - $item"
  done
  log "Full log: $LOG_FILE"
  exit 1
fi

log "the $ENVIRONMENT platform is up and Argo CD is serving."
log "  https://$ARGOCD_HOSTNAME"
log ""
log "Log in as admin with the password Argo CD generated at install, then change it and delete"
log "the Secret. This script does not print the password."
log "  kubectl --context=$ENVIRONMENT -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
log ""
log "  tear it down with: scripts/teardown.sh $ENVIRONMENT"
log "Full log: $LOG_FILE"
exit 0
