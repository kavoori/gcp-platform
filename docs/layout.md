# Layout, at scale

What the repositories and the cluster look like once the pattern is carrying real load: eight
applications, several branches and pull requests in flight. Drawn so the shape can be seen
rather than described. Every tree below follows [ADR 0001](adr/0001-chart-lives-with-the-application.md):
the chart lives with the application, the deploy repository holds environments only, and
pull-request environments are generated, never written.

The applications after `segment-builder` are named for illustration.

---

## 1. This repository, with eight applications

Grows by nothing per application and by nothing per branch. The two ApplicationSets in
`applications/` discover `-deploy` repositories and open pull requests from GitHub.

```
gcp-platform/
├── README.md
├── .gitignore
│
├── terraform/                          the bootstrap. Never grows.
│   ├── versions.tf  backend.tf  providers.tf  variables.tf  argocd.tf  outputs.tf  .tflint.hcl
│
├── apps/                               platform components. One Application each.
│   ├── platform.yaml                   → platform/
│   ├── argocd.yaml                     → argocd/ and the Argo CD chart
│   ├── config-connector.yaml           → platform/config-connector.yaml
│   ├── external-secrets.yaml           → chart from its registry, values from platform/
│   └── applications.yaml               → applications/
│
├── applications/                       what runs for users. Two files, at eight applications
│   │                                   and at three hundred.
│   ├── environments.yaml               ApplicationSet: for every repository named *-deploy,
│   │                                   read its envs/dev.yaml and deploy that version into a
│   │                                   namespace named after the application
│   └── pull-requests.yaml              ApplicationSet: for every application, for every open
│                                       pull request on its source repository, an environment
│
├── platform/                           shared objects. Grows with platform components only.
│   ├── namespace.yaml
│   ├── gateway.yaml                    the one load balancer
│   ├── config-connector.yaml
│   └── external-secrets-values.yaml
│
├── argocd/
│   ├── values.yaml
│   ├── httproute.yaml
│   └── projects.yaml                   two AppProjects: "platform" may touch anything,
│                                       "applications" may only deploy into its own namespaces
│                                       from *-deploy repositories
│
└── docs/
    ├── adr/
    ├── runbooks/
    └── layout.md                       this page
```

Onboarding the ninth application is creating `identity-broker-deploy` with an `envs/dev.yaml`
in it. Nothing here changes.

---

## 2. One application repository

Code and chart together, one version for both. Owned by developers.

```
segment-builder/
├── README.md
├── nuget.config                        where packages come from; credentials by environment variable
├── Dockerfile                          copies one service's publish output onto the runtime image
├── .github/workflows/
│   └── build.yaml                      on every push: version by svu, build, test, two images,
│                                       the chart, all at one version. On main: the git tag and
│                                       one line written into segment-builder-deploy/envs/dev.yaml
│
├── src/
│   ├── Audience.SegmentBuilder.Api/
│   │   └── appsettings.yaml            every setting with its default. Ships inside the image.
│   ├── Audience.SegmentBuilder.Worker/
│   │   └── appsettings.yaml
│   ├── Audience.SegmentBuilder.Core/
│   └── Audience.SegmentBuilder.UnitTests/
│
├── sql/                                Flyway migrations
│
└── chart/                              the templates. Change with the code, in the same commit.
    ├── Chart.yaml                      version: written by the workflow, equal to the image's
    ├── values.yaml                     the chart's own defaults; no environment in them
    ├── values.schema.json              what an envs/*.yaml may contain; a wrong key fails at render
    └── templates/
        ├── _helpers.tpl
        ├── serviceaccount.yaml         Kubernetes service account annotated to the Google identity
        ├── configmap.yaml              appsettings.<Environment>.yaml, rendered from a free-form
        │                               map in values, so any setting can be overridden
        ├── api-deployment.yaml         with the ConfigMap fingerprint annotation on the pod template
        ├── api-service.yaml
        ├── api-httproute.yaml          parentRef platform/web, hostname from values   ← the route
        ├── api-healthcheckpolicy.yaml
        ├── worker-deployment.yaml
        └── pubsub.yaml                 Config Connector: topic, dead-letter topic, subscriptions,
                                        grants, all named from values so a branch gets its own
```

The HTTPRoute is here, once, and every environment and every pull request of this application
gets one rendered from it with its own hostname. This repository never creates a Gateway.

---

## 3. One deploy repository

Environments only. Owned by operators. Small, and stays small.

```
segment-builder-deploy/
├── README.md
├── CODEOWNERS                          operators own envs/prod.yaml; a change there needs one of them
├── envs/
│   ├── dev.yaml                        version: 2.2.0        ← written by the build workflow, later Kargo
│   │                                   Estimation:
│   │                                     RequestStaleAfter: "00:30:00"   ← an override, only if dev differs
│   ├── stage.yaml                      version: 2.1.4        ← written by Kargo on promotion
│   ├── prod.yaml                       version: 2.1.4        ← written by Kargo on promotion
│   │                                   SegmentBuildSubmission:
│   │                                     MaxOutstandingBqJobs: 75         ← prod's real value, with a comment
│   └── branch.yaml                     the shape of a pull-request environment: replicas 1,
│                                       smaller requests. Hostname, namespace and image tag are
│                                       supplied by the ApplicationSet, not written here
└── docs/runbooks/
```

Two numbers per environment file at most: the version, written by a machine, and whatever
settings genuinely differ there, written by a person. Nothing else. A file that contains a
copy of a default is a file that will be wrong one day.

---

## 4. Three branches on the application repository

`main`, `feat1/some-feature` with a pull request open, `feat2/some-other-feature` with none.

| Branch | The build produces | Where it runs |
| --- | --- | --- |
| `main` | Images and chart `2.2.0`, tag `v2.2.0`, and one line in `envs/dev.yaml` | Namespace `segment-builder`, dev, by `environments.yaml`. The only path into dev |
| `feat1/some-feature`, pull request 1051 open | Images and chart tagged `2.3.0-a1b2c3d`, a pre-release of the version its commits forecast, and `sha-a1b2c3d`. No branch name appears anywhere | Namespace `segment-builder-pr-1051`, by `pull-requests.yaml`, at `segment-builder-pr-1051.dev.gcp.kavoori.com` |
| `feat2/some-other-feature`, no pull request | Images and chart tagged `2.2.1-e4f5g6h` and `sha-e4f5g6h` | Nowhere. They sit in the registry until a pull request opens |

Dev is changed by a merge to `main` and by nothing else. A branch never writes to
`segment-builder`'s namespace, and a pull-request environment renders the branch's own
templates with the branch's own image, so a feature that changes both code and chart is tested
whole.

---

## 5. The cluster, with dev, four branches and ten pull requests active

Nothing in any repository changed to produce this. The four branches without pull requests
have no namespace.

```
cluster dev-gke
│
├── namespace platform
│   └── Gateway web                                      the one load balancer, one address, one certificate
│
├── namespace argocd
│   ├── Application root, platform, argocd, config-connector, external-secrets, applications
│   ├── ApplicationSet environments-dev                  generates one Application per *-deploy repository
│   ├── ApplicationSet pull-requests                     generates one Application per open pull request
│   ├── Application segment-builder                      generated: dev, from envs/dev.yaml
│   ├── Application segment-builder-pr-1041 … pr-1050    generated: ten pull requests
│   └── Application audience-api … identity-broker       generated: the other seven, and their pull requests
│
├── namespace segment-builder                            dev. Labelled shared-gateway-access: "true"
│   ├── Deployment segment-builder-api      image 2.2.0
│   ├── Deployment segment-builder-worker   image 2.2.0
│   ├── Service segment-builder-api
│   ├── HTTPRoute segment-builder-api       host segment-builder.dev.gcp.kavoori.com → platform/web
│   ├── ConfigMap appsettings               rendered from envs/dev.yaml
│   ├── ServiceAccount segment-builder
│   └── PubSubTopic ×2, PubSubSubscription ×2, IAMPolicyMember ×4    Config Connector
│
├── namespace segment-builder-pr-1041                    one pull request. Same shape, smaller.
│   ├── Deployment ×2                       image sha-a1b2c3d, replicas 1
│   ├── HTTPRoute                           host segment-builder-pr-1041.dev.gcp.kavoori.com → platform/web
│   ├── ConfigMap appsettings               rendered from envs/branch.yaml
│   ├── PubSubTopic ×2                      named for the pull request; cannot hear dev's messages
│   └── …
├── namespace segment-builder-pr-1042
├── … eight more …
├── namespace segment-builder-pr-1050
│
├── namespace audience-api                               and its pull-request namespaces
├── namespace domain-match
└── … the other five, each with theirs
```

Every HTTPRoute in every namespace names the same Gateway. Eight applications, ten pull
requests and four idle branches add up to one load balancer and however many routes, and a
route costs nothing. The same count in a layout that builds a load balancer per application
per direction is what the forwarding-rule inventory of Bombora's dev project showed.

---

## 6. Who writes which file

| Change | Who | Repository and file | Image built? |
| --- | --- | --- | --- |
| New feature, new setting with a default | Developer | `segment-builder/src/…/appsettings.yaml`, and `chart/` if the shape changes | Yes, by the merge |
| A setting's value in one environment | Operator | `segment-builder-deploy/envs/<env>.yaml` | No |
| What version dev runs | The build workflow, later Kargo | `envs/dev.yaml`, one line | No |
| What version stage or prod runs | Kargo, or an operator until then | `envs/stage.yaml`, `envs/prod.yaml`, one line | No |
| Roll production back | Operator | `envs/prod.yaml`, the version line or an override | No |
| A pull-request environment | Nobody. A draft pull request | No file | Already built by the push |
| A new application | Whoever creates its `-deploy` repository with an `envs/dev.yaml` | A new repository | Its own workflow |
| A platform component | Platform owner | `gcp-platform/apps/` and `platform/` | No |
