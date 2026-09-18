# gcp-platform

What runs inside the `dev-gke` cluster that belongs to the cluster rather than to any one
application, applied by Argo CD from this repository.

The cluster itself, and every other Google resource, is created by `terraform-gcp`. That
repository creates nothing that runs in the cluster; this one creates nothing outside it. The
seam is "Google resource or Kubernetes object".

---

## The sequence, from an empty cluster to a running platform

Everything in this repository is Kubernetes objects that Argo CD applies from git, with one
exception: Argo CD itself, which has to be put there by something else because it is the thing
that applies the rest. The order in which things come to exist:

1. **`terraform-gcp` builds the cluster.** Empty: no namespaces of ours, no Argo CD, no Gateway.
   It also reserves the address, creates the certificate, and writes the DNS record that the
   Gateway below will use. All Google resources.

2. **`terraform/` here is applied.** Four things happen, in this order:
   1. The `argocd` namespace is created, carrying the label that lets it attach a route to the
      shared Gateway later.
   2. A Kubernetes Secret is written into that namespace holding the GitHub App's credentials:
      the App ID, the installation ID, and the private key, which Terraform reads from Secret
      Manager for the length of the apply and never stores. Argo CD will find this Secret by its
      label and use it for every repository under `github.com/kavoori`.
   3. The Argo CD Helm chart is installed, with the values in `argocd/values.yaml`.
   4. A second, tiny Helm release creates one Argo CD `Application` object named `root`, whose
      only instruction is: read the `apps/` directory of this repository and apply whatever is
      there. It is a separate release because Helm checks every object in a release against the
      cluster before installing any, and an Argo CD object is a kind that does not exist until
      step 3 has installed Argo CD's definitions.

3. **Argo CD starts, finds `root`, and reads `apps/`.** It finds three more `Application`
   objects there and applies them. This is the pattern Argo CD calls "app of apps": one Application whose
   contents are other Applications.
   - `apps/platform.yaml` tells Argo CD to apply the `platform/` directory. That creates the
     `platform` namespace and the Gateway. Google sees the Gateway and builds the load balancer,
     bound to the reserved address.
   - `apps/argocd.yaml` tells Argo CD to apply the Argo CD chart at a pinned version with the
     values in `argocd/values.yaml`, plus the plain files in `argocd/`. The chart and values are
     exactly what Terraform installed a minute earlier, so Argo CD finds its own objects already
     present and matching, and takes ownership of them. The plain files add Argo CD's route on
     the Gateway and the load balancer's health check for it.
   - `apps/config-connector.yaml` tells Argo CD to apply the `config-connector/` directory: the
     one object that puts the Config Connector add-on into cluster mode acting as the identity
     `terraform-gcp` created. The add-on's operator then starts the controller in `cnrm-system`.

4. **From here, git is the only input.** A commit to `argocd/values.yaml` changes Argo CD. A new
   file in `apps/` adds a platform component. Anything changed in the cluster by hand is put
   back within minutes, because every Application here has self-heal on. Terraform is not run
   again unless the cluster is rebuilt, and then it does step 2 again from nothing.

Step 3 has one moment worth understanding. `apps/argocd.yaml` makes Argo CD manage its own
installation. It does not manage `root`: that object belongs to Terraform, carries a different
release label, and Argo CD leaves it alone. So Argo CD manages everything about itself except
the one pointer that started it, which is the cleanest place for the line to be. The cost is
that a mistake in `argocd/values.yaml` can make Argo CD unable to apply the fix. The recovery is
to apply `terraform/` again, which reinstalls from the corrected file.

---

## The directories

Named for what they contain, in Argo CD's own vocabulary where one exists.

### `terraform/` — the bootstrap

The one step git cannot do. Its own Terraform root, its own state under
`gs://kavoori-tfstate/dev-platform/`. Applied after `terraform-gcp`'s environment root, and
destroyed before that root's teardown, because while Argo CD runs it recreates anything a
teardown deletes.

| File | What it does |
| --- | --- |
| `versions.tf` | Pins Terraform to 1.16 and the three providers: Google, Kubernetes, Helm |
| `backend.tf` | Where this root's state lives. Same bucket as `terraform-gcp`, its own prefix |
| `providers.tf` | Finds the cluster by name with a data source, takes a short-lived token from the same Google login, and points the Kubernetes and Helm providers at the cluster's DNS endpoint. Nothing here reads `terraform-gcp`'s state |
| `variables.tf` | The GitHub App's ID and installation ID, neither secret, and a revision number that is bumped to make Terraform resend the key after a rotation |
| `argocd.tf` | The four objects, in order: the namespace, the credential Secret written with write-only arguments, the Argo CD Helm release, and the second release that creates the `root` Application |
| `root-application/` | The tiny chart for that second release: one `Application` template, its repository URL filled in by Terraform |
| `outputs.tf` | The URL and the chart version installed |
| `.tflint.hcl` | Lint rules, the same as `terraform-gcp`'s |

### `apps/` — one Argo CD Application per component

"App" here means Argo CD's `Application` object, not a program. An `Application` is Argo CD's
unit of work: a pointer to a place in git, a destination in a cluster, and a policy for keeping
the two the same. This directory holds one per component of the platform. The `root`
Application points at this directory, so adding a component is adding one file here and
nothing else.

| File | What it points Argo CD at |
| --- | --- |
| `platform.yaml` | The `platform/` directory, into the `platform` namespace. Has a finalizer so that deleting the Application deletes the Gateway rather than orphaning the load balancer behind it |
| `argocd.yaml` | Three sources at once: the Argo CD chart at a pinned version from Argo's chart repository, `argocd/values.yaml` from here as the chart's input, and the plain files in `argocd/` from here. This is Argo CD managing itself |
| `config-connector.yaml` | The `config-connector/` directory. Has a finalizer, so deleting it hands the object back to the operator's default rather than orphaning it. Server-side apply, because the operator created the object first and owns its fields |

### `config-connector/` — how the Config Connector add-on behaves

One object. Config Connector is the controller that turns Kubernetes objects such as
`PubSubTopic` into the Google resources they describe, so that an application's chart can carry
its own Google resources and a branch environment is self-contained. `terraform-gcp` switches
the add-on on and creates the identity it acts as; this directory tells it which mode to run in
and which identity that is. Applied by `apps/config-connector.yaml`.

| File | What it is |
| --- | --- |
| `config-connector.yaml` | The `ConfigConnector` object, name fixed by Google: cluster mode, acting as `dev-config-connector`, and `stateIntoSpec: Absent` so Google's defaults never leak back into the objects it reconciles. Every namespace that holds Config Connector objects must carry the annotation `cnrm.cloud.google.com/project-id` naming the project |

Why cluster mode, what the identity may and may not do, and the fences around a shared identity
are in `terraform-gcp`'s ADR 0003.

### `platform/` — what every application shares

Plain Kubernetes objects that belong to the cluster, not to any application. Applied by
`apps/platform.yaml`.

| File | What it is |
| --- | --- |
| `namespace.yaml` | The `platform` namespace |
| `gateway.yaml` | The one Gateway, and so the one load balancer, every application uses. It binds to the reserved address and the certificate map that `terraform-gcp` created, and it admits routes from any namespace labelled `shared-gateway-access: "true"`. No application creates a Gateway; each creates an HTTPRoute in its own namespace that names this one |

### `argocd/` — Argo CD's own configuration

Everything that is about Argo CD itself. Read by two things: `terraform/` at bootstrap, and
`apps/argocd.yaml` forever after. That is deliberate, and it is why there is one Argo CD
configuration rather than a bootstrap copy and a git copy.

| File | What it is |
| --- | --- |
| `values.yaml` | The chart's input: Argo CD's own hostname, the server in the mode that expects TLS terminated in front of it, which optional components are on, and resource requests sized for this cluster |
| `httproute.yaml` | Three objects: the HTTPS route for `argocd.dev.gcp.kavoori.com` on the shared Gateway, the HTTP-to-HTTPS redirect, and the health check the load balancer uses for the Argo CD server |

---

### `scripts/` — the bootstrap, with its checks

`terraform apply` returns when Argo CD's pods are up and the `root` Application exists. That is
minutes before anything answers: Argo CD still has to read git, Google still has to build the
load balancer, and the edge still has to start serving. The scripts wrap the Terraform with the
waits and checks that Terraform cannot see, the same way `terraform-gcp`'s scripts do for the
cluster. Neither runs the other repository's Terraform.

| Script | What it does |
| --- | --- |
| `build.sh <env>` | Refuses unless the cluster is `RUNNING`, the reserved address, certificate map and GitHub App key exist, and no state lock is held. Applies from a plan file that contains no delete. Waits for every Application to be `Synced` and `Healthy`, the Gateway to be `Programmed`, the forwarding rule on 443, DNS, and then requests Argo CD's login page until it returns 200 and confirms plain HTTP redirects. Prints the command that reads the initial admin password, never the password |
| `teardown.sh <env>` | Refuses if Argo CD's controller is not running, because the destroy's cascade needs it. Runs `terraform destroy`, which removes the `root` Application and, through its finalizer, everything Argo CD applied, including the Gateway and its load balancer, before Argo CD itself is uninstalled. Waits for the load balancer's Google resources to be gone, proves no namespace, Application or Gateway of ours is left, and names `terraform-gcp`'s teardown as the next step |
| `lib/platform.sh` | Sourced by both scripts. Reads the project, region, cluster and state prefix out of `terraform/`, the hostname out of `argocd/values.yaml`, the Gateway and what it names out of `platform/gateway.yaml`, and the Application names out of `apps/`, so no script holds its own copy of any of them |

### `docs/` — decisions and runbooks

| Path | What it is |
| --- | --- |
| `adr/0001-chart-lives-with-the-application.md` | Why an application's Helm chart lives in the application repository, versioned with the code, and its deploy repository holds environments only. With the reference documents that were checked |
| `adr/0002-schema-migrations-run-as-a-pre-sync-hook.md` | Who runs database migrations once the build is no longer the deploy: a Job in the application's chart that Argo CD runs before the rest of the sync, under a migrator identity separate from the application's |
| `runbooks/feature-development.md` | A feature from branch to production: who does what, which file changes, pull-request environments, promotion, rollback as a commit, and the night-time configuration change |
| `layout.md` | The repositories and the cluster drawn at scale: eight applications, branches and pull requests in flight, and who writes which file |

## What is deliberately not here

- **Applications.** Each has its own deploy repository holding its chart and its per-environment
  values. This repository only ever points Argo CD at them, from `apps/`.
- **Anything Google-side.** The cluster, the reserved address the Gateway binds to, the wildcard
  certificate and DNS record, Secret Manager. Those are in `terraform-gcp`.
- **Secrets.** None in git. The one credential Argo CD holds, the GitHub App's private key, is
  written into the cluster by `terraform/` from Secret Manager and never appears here.

---

## Order across the two repositories

Up: `terraform-gcp`'s `scripts/build.sh`, then `scripts/build.sh` here. Down: `scripts/teardown.sh`
here first, then `terraform-gcp`'s `scripts/teardown.sh`. No script runs the other repository's
Terraform, so the order has to be known. Each script ends by naming the next one, and
`terraform-gcp`'s teardown refuses to start while an `argocd` namespace exists.

What the teardown's `terraform destroy` does, in order. It deletes the `root` Application and waits for it
to be gone. `root` carries Argo CD's cascade finalizer, so Argo CD first deletes the Applications
in `apps/`. The `platform` one carries the same finalizer, so its namespace and the Gateway go
too, and Google takes the load balancer apart, which is the slow part at about five minutes. The
`argocd` one carries no finalizer, so only the Application object goes and Argo CD keeps running
to finish. Then Argo CD's own release is uninstalled, the credential Secret is deleted, and the
namespace is deleted. The cluster is left with nothing of ours in it.

The full sequence for a rebuild, with the hand steps counted, is in `terraform-gcp`'s
`docs/concepts/08-lifecycle.md`.
