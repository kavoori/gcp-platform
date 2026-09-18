# 0001. The Helm chart lives with the application; environments live in a deploy repository

- **Status:** Accepted
- **Date:** 2026-09-18

## Context

An application is deployed from three things that change on different schedules: the image,
built from the code; the chart, the templates that turn an image and some settings into
Kubernetes objects; and the per-environment values, which say what runs where. Each needs a home
in git, and where the lines are drawn decides how many pull requests a change takes.

Two principles were agreed before any layout was chosen, and both survive this decision:

- Configuration is injected at deploy time. A configuration change never requires building an
  image.
- Environment configuration and the record of what version runs where do not live in the
  application's repository. Bombora's current layout puts per-environment values, deploy
  scripts and the pipeline definition inside each application repository, and that is what
  the new layout must not repeat.

An earlier draft of this design put the chart in the deploy repository, next to the values, so
that the application repository held code only. It was withdrawn after checking what the
GitOps projects themselves document:

- Argo CD's best-practices page recommends separating *config* from *source*, and gives five
  reasons: manifest-only changes should not trigger builds; a cleaner audit log; one
  application built from several repositories but deployed as one; the people who push to
  production may not be the developers; and config changes triggering CI causes loops. Every
  reason concerns environment configuration and deployment state. None concerns templates.
  <https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/>
- Argo CD's pull-request generator documentation, the reference for preview environments,
  takes the manifests from the application source repository at the pull request's commit in
  both of its examples: `targetRevision: '{{.head_sha}}'`, `path: kubernetes/`. Argo CD's
  authors assume the deployment templates live next to the code.
  <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Pull-Request/>
- Flux's repository-structure guide: "It is common to use the same repository to store both
  the application source code and its deployment manifests." Its config repositories then
  consume the application's chart as a published, versioned artifact.
  <https://fluxcd.io/flux/guides/repository-structure/>
- Kargo promotes "freight", "a set of multiple artifacts that must make the journey together
  from one end of the pipeline to the other", which presumes an image and its chart are
  versioned together.
  <https://docs.kargo.io/user-guide/core-concepts/>
- The Codefresh/Octopus environment-modelling guide keeps per-environment values in a
  dedicated GitOps repository, one folder per environment, and says nothing of templates
  living there.
  <https://octopus.com/blog/how-to-model-your-gitops-environments>

With the chart in a separate repository, a feature that changes both code and templates is two
pull requests in a required order, and a pull-request environment cannot render the branch's
templates without a convention naming which chart branch to use. With the chart next to the
code, the same feature is one pull request, and the pull-request environment renders the
templates from the same commit as the image.

## Decision

The chart lives in the application repository, under `chart/`, versioned with the application.
The workflow that builds the images packages the chart at the same version and pushes it to
Artifact Registry as an OCI artifact. There is one version number per release, shared by the
images and the chart.

The deploy repository, `<application>-deploy`, holds only per-environment values: one file per
environment naming the version to run and the settings that differ in that environment. It
holds no templates.

## Alternatives considered

- **Chart and values together in the deploy repository, code alone in the application
  repository.** The earlier draft. Rejected because templates change with code, so every
  coupled change becomes two pull requests, and preview environments need a convention to find
  the matching chart branch. None of the reference documents above separates templates from
  code.
- **Everything in the application repository: code, chart, and per-environment values.**
  Bombora's current layout. Rejected because it violates the second principle: operators must
  be able to change what runs in production without touching the code repository, and the
  record of what runs where must not be mixed into the application's history.
- **A shared base chart consumed by every application, with a thin per-application chart.**
  Bombora's current layout again, and a real option at three hundred applications. Not chosen
  now because there is one application and a base chart designed for one caller is a guess.
  When a second application exists, the shared parts of the two charts become a library chart,
  published and versioned on its own, and each application's `chart/` depends on it. This
  decision does not prevent that; it decides where the application's own chart lives.

## Consequences

Easier:

- A feature that changes code and deployment shape is one pull request, tested in one
  pull-request environment that renders the branch's templates with the branch's image.
- One version number. "Which chart version goes with image 2.2.0" has no answer to look up,
  because it is 2.2.0. Promotion moves one number per environment.
- Preview environments follow Argo CD's own documented pattern with no adaptation.

Harder, or now required:

- A template-only change produces a new application version and a new image with identical
  contents, because there is one version. Accepted: template changes are rare, and a version
  that means "this code with these templates" is worth more than a saved build.
- A setting whose value must differ per environment still takes a second, one-line pull
  request in the deploy repository, by whoever owns that environment's settings. This is
  correct rather than a cost: choosing production's value is an operational decision, not part
  of a developer's feature.
- The deploy repository's values file must be able to override any setting the application
  has, so the chart renders a free-form map into the environment's settings file rather than
  naming specific keys. Otherwise an operator cannot change a setting nobody anticipated.
- The application's `appsettings.yaml` is the source of every default. A new setting is added
  there, with its default, in the same commit as the code that reads it. The deploy repository
  is for differences, not for a second copy of the defaults.
