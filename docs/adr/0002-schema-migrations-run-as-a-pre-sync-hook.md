# 0002. Schema migrations run as an Argo CD pre-sync hook, under their own identity

- **Status:** Accepted
- **Date:** 2026-09-18

## Context

Applications deployed here own a database schema and change it over time with versioned
migration files. segment-builder's are Flyway files in its `sql/` directory. Nothing in that
application applies them: at its previous home the build server ran the Flyway command-line
tool against the database as a step of the deploy, immediately before rolling the pods, from
inside the network.

Here, build and deploy are separate. GitHub Actions builds an image and publishes a chart.
The deploy happens later and elsewhere: a commit to a deploy repository, or a promotion by
Kargo, which Argo CD then applies. The build has no way to know when that is, or which
environment or branch database it is for. GitHub's hosted runners also cannot reach a Cloud SQL
instance on a private address. So the migration cannot be a build step any more.

Somebody still has to run it, at the moment the version that needs it is deployed, against the
database that version will use. Two constraints decide who:

- The application's own logic is not changed to do it. Adding a migration library to a .NET
  service that has never carried one is application code.
- Rule 3 of `terraform-gcp`: grant at the narrowest scope that works. An identity that serves
  requests all day should not be able to drop tables.

A precedent exists in this organisation. bombora-audiences, a Java service, runs Flyway inside
the process at startup under the application's own database user, and its ADR-004 sets the
policy that ephemeral environments rebuild their database on every deploy while persistent
environments are forward-only with backward-compatible changes.

## Decision

The application's chart contains a Kubernetes Job that runs the migrations, annotated as an
Argo CD pre-sync hook. Argo CD runs it to completion before applying anything else in that
sync, and a failed Job fails the sync with the running pods untouched.

The Job's container is the application image, which carries the migration files. The Job runs
as its own Kubernetes service account, tied to its own Google service account, the migrator.
That identity may alter the schema. The application's identity may only read and write rows.

The migrations grant the application's database user its rights, so that tables created by
the migrator are usable by the application. One repeatable migration does this after every
run.

## Alternatives considered

- **The application runs migrations at startup, in-process.** How bombora-audiences does it,
  and the simplest arrangement. Not chosen because it needs application code that does not
  exist, and because it gives the application's runtime identity the right to alter the
  schema. That second point applies to the Java service too and is worth revisiting there.
- **An init container in the application's pod runs Flyway.** Same ownership as the startup
  option without touching application code, and the closest fit to the precedent. It was the
  first proposal. Not chosen because a pod has one identity, so the application's identity
  would still need schema rights. It also runs on every pod start, a few seconds each, though
  that was not the deciding factor.
- **The build pipeline runs it, as before.** Not possible: the build is not the deploy, does
  not know when the deploy happens or for which database, and cannot reach the database.
- **A step in the Kargo promotion.** Kargo would then hold database access and knowledge of
  the application's internals. Kargo's job is to move a version pin; the chart's job is to
  describe the version. This puts a deploy concern in the promotion tool.

The init-container option was close. The identity separation is what decided it.

## Consequences

Easier:

- The schema is always migrated by the version about to run, because the Job and the
  Deployments are in one chart at one version. Rolling back to an older chart runs that older
  chart's Job, which finds nothing to do.
- Branch environments need nothing extra. The branch's database is created empty, the first
  sync's Job runs every migration into it, and the database goes with the branch.
- The application cannot alter its own schema, in any environment.
- A migration failure is visible where deploys are watched: the Application shows a failed
  sync, and the previous version keeps serving.

Harder, or now required:

- Two database users per application instead of one, and one more Google service account
  with its Workload Identity binding and its Cloud SQL login grant. The chart creates them.
- Tables belong to the migrator, so the migrations must grant the application user its rights.
  Forgetting the grant breaks the application on first query, not at migration time.
- The Job's pod needs the Cloud SQL proxy beside it, as a native sidecar, so the proxy exits
  when the migration finishes. Flyway speaks JDBC, which cannot use a unix socket, so the
  proxy listens on the pod's loopback address for this Job.
- The Job runs on every sync, including ones that change only configuration. When there is
  nothing to migrate it connects, compares, and exits. A few seconds per sync.
- The Job's previous run has to be deleted before the next, or its name has to change per
  sync. Argo CD's hook deletion policy handles this; the chart states it.
- Persistent environments are forward-only. A schema change must work with the previous
  application version, so that the application can be rolled back without the schema. Adding
  a nullable column, a table or an index is fine. Dropping or renaming needs two releases:
  first the code that no longer needs the thing, then the migration that removes it.
- Creating the database itself, and the two users, is not a migration and does not happen
  here. That is Config Connector's or Terraform's, before the first sync.
- Argo CD knows nothing of this beyond one annotation on one Job. It never reads the migration
  files, never holds a database credential, and has no configuration about migrations. The
  line to hold: the SQL stays in the image, the ordering stays in the chart, and the deploy
  repository holds only the version and values.
