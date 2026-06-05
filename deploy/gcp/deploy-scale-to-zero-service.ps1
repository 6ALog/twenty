param(
  [Parameter(Mandatory = $true)]
  [string] $ProjectId,

  [Parameter(Mandatory = $true)]
  [string] $ImageUrl,

  [Parameter(Mandatory = $true)]
  [string] $CloudSqlInstance,

  [string] $Region = "us-central1",

  [string] $ServiceName = "twenty-crm",

  [string] $ServerUrl = "https://crm.6alogic.com",

  [string] $PgDatabaseUrlSecret = "PG_DATABASE_URL",

  [string] $EncryptionKeySecret = "ENCRYPTION_KEY",

  [string] $AppSecretSecret = "APP_SECRET"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
  throw "gcloud is not installed or not on PATH. Install the Google Cloud SDK or run this from Cloud Shell."
}

gcloud config set project $ProjectId

$twentyEnvVars = @(
  "NODE_PORT=3000",
  "SERVER_URL=$ServerUrl",
  "REDIS_URL=redis://localhost:6379",
  "DISABLE_DB_MIGRATIONS=false",
  "DISABLE_CRON_JOBS_REGISTRATION=false"
) -join ","

$twentySecrets = @(
  "PG_DATABASE_URL=$PgDatabaseUrlSecret`:latest",
  "ENCRYPTION_KEY=$EncryptionKeySecret`:latest",
  "APP_SECRET=$AppSecretSecret`:latest"
) -join ","

gcloud run deploy $ServiceName `
  --project=$ProjectId `
  --region=$Region `
  --platform=managed `
  --execution-environment=gen2 `
  --ingress=all `
  --allow-unauthenticated `
  --add-cloudsql-instances=$CloudSqlInstance `
  --min-instances=0 `
  --max-instances=1 `
  --container=redis-sidecar `
  --image=redis:7-alpine `
  --memory=256Mi `
  --container=twenty-app `
  --depends-on=redis-sidecar `
  --image=$ImageUrl `
  --port=3000 `
  --memory=2Gi `
  --cpu=1 `
  --set-env-vars=$twentyEnvVars `
  --set-secrets=$twentySecrets
