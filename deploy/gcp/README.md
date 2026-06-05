# GCP Artifact Registry Pipeline

This fork is the source of truth for custom Twenty CRM changes. The deployment
pattern is:

1. Edit the fork locally.
2. Push to GitHub.
3. Cloud Build builds `packages/twenty-docker/twenty/Dockerfile`.
4. Cloud Build pushes the image to Artifact Registry.
5. Cloud Run server and worker deployments consume that image.

The current local checkout is a shallow clone of `6ALog/twenty` with
`upstream` pointing at `twentyhq/twenty`.

## Branch Workflow

Use short-lived customization branches:

```powershell
git checkout main
git fetch upstream
git merge upstream/main
git push origin main

git checkout -b customize/my-change
# edit, test, commit
git push -u origin customize/my-change
```

For production, merge reviewed customization branches back to `main`. Configure
the Cloud Build trigger against `main` when you are ready for automatic builds.

## One-Time GCP Setup

Install the Google Cloud SDK locally or run these commands in Cloud Shell.

```powershell
$env:PROJECT_ID = "your-gcp-project-id"
$env:REGION = "us-central1"
$env:ARTIFACT_REPOSITORY = "twenty"
$env:IMAGE_NAME = "twenty"

gcloud config set project $env:PROJECT_ID

gcloud services enable `
  artifactregistry.googleapis.com `
  cloudbuild.googleapis.com `
  run.googleapis.com `
  secretmanager.googleapis.com `
  sqladmin.googleapis.com `
  redis.googleapis.com `
  vpcaccess.googleapis.com

gcloud artifacts repositories create $env:ARTIFACT_REPOSITORY `
  --repository-format=docker `
  --location=$env:REGION `
  --description="Twenty CRM container images"
```

## Manual Image Build

Use this before wiring an automatic trigger. If you are on a slow or metered
connection, prefer the remote builder. It uploads only the tiny build config;
Cloud Build clones GitHub inside Google's network:

```powershell
.\deploy\gcp\build-artifact-remote.ps1 `
  -ProjectId "your-gcp-project-id" `
  -Region "us-central1" `
  -ArtifactRepository "twenty" `
  -ImageName "twenty" `
  -ChannelTag "dev" `
  -GitRef "gcp-artifact-pipeline"
```

The local-source builder below uploads the full repo from your machine. Use it
only on a stable connection or when you need to build unpushed local changes:

```powershell
.\deploy\gcp\build-artifact.ps1 `
  -ProjectId "your-gcp-project-id" `
  -Region "us-central1" `
  -ArtifactRepository "twenty" `
  -ImageName "twenty" `
  -ChannelTag "dev"
```

Or call Cloud Build directly:

```powershell
gcloud builds submit `
  --config=cloudbuild.yaml `
  --substitutions=_REGION=$env:REGION,_ARTIFACT_REPOSITORY=$env:ARTIFACT_REPOSITORY,_IMAGE_NAME=$env:IMAGE_NAME,_CHANNEL_TAG=dev
```

The build publishes:

- `$REGION-docker.pkg.dev/$PROJECT_ID/$ARTIFACT_REPOSITORY/$IMAGE_NAME:$BUILD_ID`
- `$REGION-docker.pkg.dev/$PROJECT_ID/$ARTIFACT_REPOSITORY/$IMAGE_NAME:dev`

Use the immutable build ID tag for stable deployments. Use `dev` for quick test
deployments.

The image URL you pass to Cloud Run is the Artifact Registry URL, not the GitHub
URL:

```text
us-central1-docker.pkg.dev/PROJECT_ID/twenty/twenty:dev
```

GitHub stores the source. Cloud Build reads GitHub and writes this container
image to Artifact Registry. Cloud Run deploys the Artifact Registry image.

## Automatic GitHub Trigger

Create the trigger in Google Cloud Console under Cloud Build -> Triggers after
connecting the GitHub fork, or use `gcloud` once the GitHub connection is
available:

```powershell
gcloud builds triggers create github `
  --name=twenty-artifact-main `
  --repo-owner=6ALog `
  --repo-name=twenty `
  --branch-pattern="^main$" `
  --build-config=cloudbuild.yaml `
  --substitutions=_REGION=$env:REGION,_ARTIFACT_REPOSITORY=$env:ARTIFACT_REPOSITORY,_IMAGE_NAME=$env:IMAGE_NAME,_CHANNEL_TAG=dev
```

## Runtime Secrets

Create these Secret Manager entries before deploying Cloud Run. The commands
below use Bash syntax, so run them in Cloud Shell, Git Bash, or WSL:

```bash
printf "postgres://USER:PASSWORD@HOST:5432/default" | gcloud secrets create twenty-pg-database-url --data-file=-
printf "redis://HOST:6379" | gcloud secrets create twenty-redis-url --data-file=-
printf "existing-or-new-encryption-key" | gcloud secrets create twenty-encryption-key --data-file=-
printf "existing-or-new-app-secret" | gcloud secrets create twenty-app-secret --data-file=-
```

If you are migrating the existing local database, keep the existing
`ENCRYPTION_KEY`. Changing it can make encrypted integration credentials
unreadable.

For file uploads, configure an S3-compatible bucket and add the corresponding
`STORAGE_S3_*` settings/secrets before treating the deployment as production.
Cloud Run's local filesystem is disposable.

## Cloud Run Server

### Scale-To-Zero Profile

If the priority is scaling everything down where Cloud Run allows it, deploy the
web app with an in-service Redis sidecar and `--min-instances=0`.

This keeps the Cloud Run service at zero instances when idle, but it has a real
tradeoff: Redis is ephemeral and local to each service instance. It is acceptable
for a single-user, low-traffic test deployment, but it is not a durable queue for
background sync. Gmail/Calendar/workflow jobs that require a continuously
running worker should be considered delayed or unreliable in this profile.

From PowerShell:

```powershell
.\deploy\gcp\deploy-scale-to-zero-service.ps1 `
  -ProjectId "twenty-crm-498520" `
  -Region "us-central1" `
  -ServiceName "twenty-crm" `
  -ImageUrl "us-central1-docker.pkg.dev/twenty-crm-498520/twenty/twenty:dev" `
  -CloudSqlInstance "twenty-crm-498520:us-central1:twenty-db" `
  -ServerUrl "https://crm.6alogic.com"
```

The helper deploys Cloud Run from a generated service YAML instead of a long
`gcloud run deploy` command. That is intentional: the scale-to-zero profile uses
three containers in one Cloud Run service:

- `twenty-app`: the public CRM web container on port `3000`.
- `redis-sidecar`: local ephemeral Redis on `localhost:6379`.
- `cloud-sql-proxy`: Cloud SQL Auth Proxy on `localhost:5432`.

Set `PG_DATABASE_URL` to the local proxy endpoint before deploying:

```text
postgres://twenty:PASSWORD@localhost:5432/twenty
```

Do not point Cloud Run at the Cloud SQL public IP for this profile. The proxy
sidecar keeps the database closed to public internet access while still allowing
the Cloud Run service to scale to zero.

`DB_TYPE=postgres` is not part of Twenty's Docker Compose contract. The setting
that matters for Twenty is `PG_DATABASE_URL`. The deploy helper also sets
`APP_VERSION=0.0.0`; Twenty validates this as semver during startup.

If `roles/run.invoker` for `allUsers` fails with an organization-policy error,
Domain Restricted Sharing is enabled on the Google Workspace organization. The
Cloud Run service can still deploy and become healthy, but normal browser access
will stay blocked until an organization/folder policy admin allows public
invocation for this project or you put an authenticated IAP/load-balancer entry
point in front of the service.

### Managed Redis And Worker Profile

```powershell
$env:IMAGE = "$env:REGION-docker.pkg.dev/$env:PROJECT_ID/$env:ARTIFACT_REPOSITORY/$env:IMAGE_NAME:dev"

gcloud run deploy twenty-server `
  --image=$env:IMAGE `
  --region=$env:REGION `
  --port=3000 `
  --allow-unauthenticated `
  --min-instances=0 `
  --max-instances=1 `
  --env-vars-file=deploy/gcp/env.example `
  --set-secrets=PG_DATABASE_URL=twenty-pg-database-url:latest,REDIS_URL=twenty-redis-url:latest,ENCRYPTION_KEY=twenty-encryption-key:latest,APP_SECRET=twenty-app-secret:latest
```

For a custom domain, map `crm.6alogic.com` or `portal.6alogic.com` to this
service and keep `SERVER_URL` exactly aligned with the public HTTPS URL.

## Cloud Run Worker

Twenty background sync depends on a worker that stays running. Do not scale this
to zero if you want Gmail, Calendar, workflow, and queue processing to run.
If strict scale-to-zero matters more than continuous sync, skip this worker and
accept delayed/unreliable background processing, or add a later scheduled worker
experiment that runs for short bursts.

```powershell
gcloud beta run worker-pools deploy twenty-worker `
  --image=$env:IMAGE `
  --region=$env:REGION `
  --scaling=1 `
  --command=yarn `
  --args=worker:prod `
  --env-vars-file=deploy/gcp/worker.env.example `
  --set-secrets=PG_DATABASE_URL=twenty-pg-database-url:latest,REDIS_URL=twenty-redis-url:latest,ENCRYPTION_KEY=twenty-encryption-key:latest,APP_SECRET=twenty-app-secret:latest
```

## Google Workspace Integration

Enable Gmail API, Google Calendar API, and People API in the same Google Cloud
project. Configure OAuth redirect URIs:

- `https://crm.6alogic.com/auth/google/redirect`
- `https://crm.6alogic.com/auth/google-apis/get-access-token`

Then set the Google auth and integration variables in Twenty's Admin Panel, or
promote them into Secret Manager and environment variables if you choose
environment-only configuration.

## Local Windows Notes

Twenty has paths long enough to fail with default Git-for-Windows settings. This
checkout has `core.longpaths=true`. If you clone elsewhere, run:

```powershell
git config --global core.longpaths true
```

There are also case-colliding website assets in upstream Twenty. Cloud Build
runs on Linux and preserves them correctly; local Windows checkouts may only
materialize one of each collided pair. That should not affect CRM server/front
customization work, but build production images in Cloud Build rather than using
Windows as the authoritative build environment.
