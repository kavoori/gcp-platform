# Feature development, from branch to production

What happens, who does it, and which file changes, from the first commit of a feature to the
day it runs in production. Written for one application, `segment-builder`, and true for every
application that follows the same layout.

The rollback and the night-time configuration change are at the end. Read those first if that
is why you are here.

---

## Who does what

| Role | What they touch | What they never touch |
| --- | --- | --- |
| **Developer** | `segment-builder`: code under `src/`, defaults in `appsettings.yaml`, templates under `chart/` | Any `envs/` file in the deploy repository. What runs where is not a developer's decision |
| **Reviewer** | Approves pull requests on `segment-builder` | |
| **Operator** (devops) | `segment-builder-deploy`: `envs/dev.yaml`, `envs/stage.yaml`, `envs/prod.yaml`, the settings that differ per environment | Code. An operator changes what production runs and how it is configured, never what the application does |
| **GitHub Actions** | Builds images and the chart on every push; on `main`, writes the new version into `envs/dev.yaml` | |
| **Argo CD** | Applies whatever `envs/*.yaml` says, and creates and deletes pull-request environments | |
| **Kargo** | Writes the version line in `envs/stage.yaml` and `envs/prod.yaml` when a version is promoted. Until Kargo is installed, an operator writes that line | |

Access follows the table. `CODEOWNERS` in `segment-builder-deploy` names the operators for
`envs/prod.yaml`, so a change to production's settings cannot merge without one of them.
Developers hold write on `segment-builder` and read on the deploy repository.

---

## The repositories and the files that matter

```
segment-builder/                      the application. Owned by developers.
├── src/
│   ├── Audience.SegmentBuilder.Api/appsettings.yaml        every setting, with its default
│   └── Audience.SegmentBuilder.Worker/appsettings.yaml     inside the image
├── chart/                            the templates. Versioned with the code.
│   ├── Chart.yaml                    version written by the workflow, never by hand
│   ├── values.yaml                   the chart's defaults
│   ├── values.schema.json            what an environment file may contain
│   └── templates/
└── .github/workflows/build.yaml      builds two images and the chart, one version for all three

segment-builder-deploy/               the environments. Owned by operators.
├── CODEOWNERS                        operators own envs/prod.yaml
├── envs/
│   ├── dev.yaml                      version: 2.1.4   plus dev's overrides
│   ├── stage.yaml                    version: 2.1.4   plus stage's overrides
│   ├── prod.yaml                     version: 2.1.4   plus prod's overrides
│   └── branch.yaml                   the shape of a pull-request environment
└── docs/runbooks/                    this document's home, once the repository exists
```

Two rules make the rest simple. The application's `appsettings.yaml` holds every setting with
its default, and ships inside the image. An `envs/*.yaml` file holds only what differs in that
environment, and is rendered into `appsettings.<Environment>.yaml`, which .NET reads on top of
the defaults. A key that appears in both is the environment's value that wins.

---

## The feature

The example: change the estimation request stale window from fifteen minutes to thirty. No
code change, one default changes.

### 1. The developer branches and commits

In `segment-builder`:

```
git checkout -b feat/estimation-window-30m
```

Files changed, and the only files changed:

- `src/Audience.SegmentBuilder.Api/appsettings.yaml`: `RequestStaleAfter: "00:30:00"`
- `src/Audience.SegmentBuilder.Worker/appsettings.yaml`: the same

The commit message is a conventional commit, because it decides the version later:

```
git commit -am "feat(estimation): widen the request stale window to 30 minutes"
```

```
git push -u origin feat/estimation-window-30m
```

A feature that also changes the deployment's shape, a new environment variable, a sidecar, a
different port, changes `chart/` in the same commit. That is the reason the chart lives here.

### 2. The push builds, and deploys nothing

GitHub Actions runs on the branch. svu reads the last release tag, `v2.1.4`, sees one `feat`
commit, and forecasts `2.2.0`; the branch build is a pre-release of that, `2.2.0-abc1234`. It
builds and pushes both images under that tag and under `sha-abc1234`, packages `chart/` at the
same version and pushes it to Artifact Registry, and stops. No branch name appears in any
artifact, so two branches can never collide. The number is a forecast: if the pull request is
later squash-merged as a `fix`, the release is `2.1.5`, not `2.2.0`, and nothing depends on the
two matching. A branch with no pull request has no environment, so idle branches cost nothing.

### 3. The developer asks for an environment: a draft pull request

Open a pull request on `segment-builder` as a **draft**. A draft is an open pull request to
GitHub, so Argo CD's pull-request generator lists it, and it tells reviewers the work is not
ready. Nobody writes a file for this step.

Within about two minutes, the ApplicationSet `pull-requests` in `gcp-platform` creates:

- An Argo CD Application `segment-builder-pr-1051`, whose sources are the chart from
  `segment-builder` at commit `abc1234`, the values from `segment-builder-deploy`'s
  `envs/branch.yaml`, the image tag `sha-abc1234`, and the hostname
  `segment-builder-pr-1051.dev.gcp.kavoori.com`.
- The namespace `segment-builder-pr-1051`, labelled to attach routes to the shared Gateway,
  holding both Deployments on `sha-abc1234`, the Service, an HTTPRoute on the shared load
  balancer, the ConfigMap of branch overrides, the service account, and Pub/Sub topics named
  for the pull request so it cannot hear dev's messages.

Argo CD shows the Application Synced and Healthy.

If pull-request drafts turn out not to be listed by the generator, the equivalent lever is a
label, `preview`, on the pull request, which the generator has a documented filter for.

### 4. The developer tests it

```
curl -sS https://segment-builder-pr-1051.dev.gcp.kavoori.com/api/ready
```

The setting itself, read from inside the running pod:

```
kubectl --context=dev -n segment-builder-pr-1051 exec deploy/segment-builder-api -- grep -A1 RequestStaleAfter /app/appsettings.yaml
```

Expect `00:30:00`. Then whatever exercises the estimation cache.

Another commit on the branch builds `sha-def5678`; the generator sees the new head commit,
updates the Application, and Argo CD rolls the pods. Still nothing outside `src/` is touched.

### 5. Review and merge

The developer marks the pull request ready for review. A reviewer approves. Squash-merge, so
`main` receives one commit with the one conventional message.

### 6. The merge releases

GitHub Actions runs on `main`. svu produces `2.2.0`. It pushes `segment-builder-api:2.2.0`,
`segment-builder-worker:2.2.0`, chart `2.2.0`, and the git tag `v2.2.0`. Its last step commits
one line to `segment-builder-deploy`:

- `envs/dev.yaml`: `version: 2.1.4` becomes `version: 2.2.0`, message `chore(dev): version 2.2.0`

That commit is made by the workflow's GitHub App identity, not by a person. Argo CD's dev
Application sees it, renders chart `2.2.0` with `envs/dev.yaml`, and rolls the pods. Dev runs
2.2.0; its estimation window is thirty minutes.

The pull request closed on merge, so the generator's list no longer has it. Application
`segment-builder-pr-1051` is deleted, and with it its namespace, pods, route and topics.

### 7. Promotion to stage and production

`envs/stage.yaml` and `envs/prod.yaml` still say `version: 2.1.4`. Promotion is one line in one
file per environment:

- `envs/stage.yaml`: `version: 2.2.0`
- later, `envs/prod.yaml`: `version: 2.2.0`

Kargo writes those lines: it watches the registry, sees chart and images `2.2.0` arrive
together, and promotes them as one unit from dev to stage to prod, each promotion a commit
Argo CD applies. Until Kargo is installed, an operator makes the same one-line commit, through
a pull request that `CODEOWNERS` routes to operators for `envs/prod.yaml`.

Chart and images cannot drift apart between environments, because there is one number.

---

## The other path: a value that differs per environment

If the requirement had been thirty minutes in dev only, and fifteen elsewhere, no code changes.
An operator adds to `envs/dev.yaml`:

```yaml
Estimation:
  RequestStaleAfter: "00:30:00"
```

Argo CD applies it. The ConfigMap that becomes `appsettings.Development.yaml` changes, the
fingerprint annotation on the pod template changes with it, the pods roll, and dev reads thirty
minutes. No image is built. The developer's branch is not involved, because it is not a code
change.

---

## Rollback

Two tools, one surgical and one blunt. Both are one commit to `segment-builder-deploy`, both
are operators' to make, neither needs a developer or an image.

### Override one setting

The setting is wrong, everything else in the release is fine. Add the old value to the
environment's file, `envs/prod.yaml`:

```yaml
Estimation:
  RequestStaleAfter: "00:15:00"
```

Argo CD applies it within seconds of the push. The override wins over the image's default, the pods roll,
production reads fifteen minutes. Reverting the rollback is deleting those lines.

### Roll the version back

The release is wrong. Change the one line, `envs/prod.yaml`: `version: 2.2.0` becomes
`version: 2.1.4`. Argo CD renders the previous chart with the previous image and rolls the pods.
Everything that was in 2.2.0 leaves production together, which is more than a single setting
and is sometimes exactly what is wanted.

Do not use Argo CD's rollback button for either. It switches off automatic sync for that
Application, and the next commit to git is then not applied until someone notices. The commit
to git is the rollback.

### Verify

```
kubectl --context=prod -n segment-builder exec deploy/segment-builder-api -- grep -A1 RequestStaleAfter /app/appsettings.Production.yaml
```

For an override, expect the overridden value in that file. For a version rollback:

```
kubectl --context=prod -n segment-builder get deploy segment-builder-api -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Expect the image tag you rolled back to.

---

## The night-time change

Devops is asked at 2 a.m. to change the window from thirty minutes back to fifteen in
production, and no engineer is awake.

1. An operator opens a pull request on `segment-builder-deploy` adding the override to
   `envs/prod.yaml`, as in "Override one setting" above.
2. `CODEOWNERS` requires an operator's approval. The incident rule says which operators may
   approve at night and whether one person may approve their own change during an incident.
   That rule is written before the first night, not during it.
3. Merge. Argo CD applies it. The pods roll. Production reads fifteen minutes.
4. Verify, as above.
5. Open a ticket for the morning: the image's default still says thirty. The engineer sets the
   default back in `appsettings.yaml` and ships it; the operator then deletes the override.

Step 5 is the one that gets skipped, and skipping it is how a production file fills with
overrides nobody remembers. The rule: an override is either temporary, with a ticket to remove
it, or it is the environment's real value, with a comment saying why.

---

## What makes this work, decided ahead of time

- Every setting has its default in `appsettings.yaml`, inside the image. The deploy repository
  holds differences, never a second copy of the defaults.
- The chart renders the environment's file from a free-form map, so an operator can override a
  setting the chart's author never named.
- The environment files mirror the application's own settings file: same sections, same keys.
  An operator copies the path from `appsettings.yaml` and changes the value. The schema file
  rejects a typo at render time.
- Every values change reaches the pods, because the chart stamps a fingerprint of the ConfigMap
  on the pod template. Without that, a changed ConfigMap would sit unread until a restart.
- Operators can merge to the deploy repository and cannot merge to the source repository.
  That separation is what lets production be changed at 2 a.m. without touching code.
- The rollback is a commit, never a button.
