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

2. **`terraform/` here is applied.** Three things happen, in this order:
   1. The `argocd` namespace is created, carrying the label that lets it attach a route to the
      shared Gateway later.
   2. A Kubernetes Secret is written into that namespace holding the GitHub App's credentials:
      the App ID, the installation ID, and the private key, which Terraform reads from Secret
      Manager for the length of the apply and never stores. Argo CD will find this Secret by its
      label and use it for every repository under `github.com/kavoori`.
   3. The Argo CD Helm chart is installed, with the values in `argocd/values.yaml`. Those values
      include one Argo CD `Application` object named `root`, whose only instruction is: read the
      `apps/` directory of this repository and apply whatever is there.

3. **Argo CD starts, finds `root`, and reads `apps/`.** It finds two more `Application` objects
   there and applies them. This is the pattern Argo CD calls "app of apps": one Application whose
   contents are other Applications.
   - `apps/platform.yaml` tells Argo CD to apply the `platform/` directory. That creates the
     `platform` namespace and the Gateway. Google sees the Gateway and builds the load balancer,
     bound to the reserved address.
   - `apps/argocd.yaml` tells Argo CD to apply the Argo CD chart at a pinned version with the
     values in `argocd/values.yaml`, plus the plain files in `argocd/`. The chart and values are
     exactly what Terraform installed a minute earlier, so Argo CD finds its own objects already
     present and matching, and takes ownership of them. The plain files add Argo CD's route on
     the Gateway and the load balancer's health check for it.

4. **From here, git is the only input.** A commit to `argocd/values.yaml` changes Argo CD. A new
   file in `apps/` adds a platform component. Anything changed in the cluster by hand is put
   back within minutes, because every Application here has self-heal on. Terraform is not run
   again unless the cluster is rebuilt, and then it does step 2 again from nothing.

Step 3 has one moment worth understanding. `apps/argocd.yaml` makes Argo CD manage its own
installation, including the `root` Application that started everything, because `root` is
inside the values file. So Argo CD manages the thing that tells it to manage things. That is
not a loop that runs; it is a description that is consistent with itself, and it is how every
self-managed Argo CD works. The cost is that a mistake in `argocd/values.yaml` can make Argo CD
unable to apply the fix. The recovery is to apply `terraform/` again, which reinstalls from the
corrected file.

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
| `argocd.tf` | The three objects, in order: the namespace, the credential Secret written with write-only arguments, the Helm release |
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
| `values.yaml` | The chart's input: Argo CD's own hostname, the server in the mode that expects TLS terminated in front of it, which optional components are on, resource requests sized for this cluster, and the `root` Application under `extraObjects` |
| `httproute.yaml` | Three objects: the HTTPS route for `argocd.dev.gcp.kavoori.com` on the shared Gateway, the HTTP-to-HTTPS redirect, and the health check the load balancer uses for the Argo CD server |

---

### `docs/` — decisions and runbooks

| Path | What it is |
| --- | --- |
| `adr/0001-chart-lives-with-the-application.md` | Why an application's Helm chart lives in the application repository, versioned with the code, and its deploy repository holds environments only. With the reference documents that were checked |
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

Up: `terraform-gcp` environment root, then `terraform/` here. Down: `terraform/` here first,
then `terraform-gcp`'s teardown. No script spans the two, so the order has to be known, and the
teardown script refuses to start while an `argocd` namespace exists.
