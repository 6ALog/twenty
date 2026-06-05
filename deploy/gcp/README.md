# GCP Artifact Registry Pipeline

This fork is the source of truth for custom Twenty CRM changes. The deployment
pattern is:

1. Edit the fork locally.
2. Push to GitHub.
3. Cloud Build builds `packages/twenty-docker/twenty/Dockerfile`.
4. Cloud Build pushes the image to Artifact Registry.
5. Cloud Run server and worker deployments consume that image.

The current local checkout is a shallow clone of `winzealot/twenty` with
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

Use this before wiring an automatic trigger. From PowerShell:

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

## Automatic GitHub Trigger

Create the trigger in Google Cloud Console under Cloud Build -> Triggers after
connecting the GitHub fork, or use `gcloud` once the GitHub connection is
available:

```powershell
gcloud builds triggers create github `
  --name=twenty-artifact-main `
  --repo-owner=winzealot `
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
