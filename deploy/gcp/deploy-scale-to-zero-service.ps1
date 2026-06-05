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

  [string] $AppSecretSecret = "APP_SECRET",

  [string] $ServiceAccountEmail = ""
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
  throw "gcloud is not installed or not on PATH. Install the Google Cloud SDK or run this from Cloud Shell."
}

function Invoke-Gcloud {
  & gcloud @args
  if ($LASTEXITCODE -ne 0) {
    throw "gcloud command failed with exit code ${LASTEXITCODE}: gcloud $($args -join ' ')"
  }
}

Invoke-Gcloud config set project $ProjectId

if ([string]::IsNullOrWhiteSpace($ServiceAccountEmail)) {
  $projectNumber = gcloud projects describe $ProjectId --format="value(projectNumber)"
  $ServiceAccountEmail = "$projectNumber-compute@developer.gserviceaccount.com"
}

$deployNonce = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

$serviceYaml = @"
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: $ServiceName
  labels:
    cloud.googleapis.com/location: $Region
  annotations:
    run.googleapis.com/ingress: all
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/minScale: '0'
        autoscaling.knative.dev/maxScale: '1'
        run.googleapis.com/execution-environment: gen2
        run.googleapis.com/startup-cpu-boost: 'true'
        run.googleapis.com/container-dependencies: '{"twenty-app":["redis-sidecar","cloud-sql-proxy"]}'
        deploy.gcp.twenty/nonce: '$deployNonce'
    spec:
      containerConcurrency: 10
      serviceAccountName: $ServiceAccountEmail
      timeoutSeconds: 300
      containers:
      - name: redis-sidecar
        image: redis:7-alpine
        resources:
          limits:
            cpu: 500m
            memory: 256Mi
        startupProbe:
          failureThreshold: 12
          periodSeconds: 5
          timeoutSeconds: 5
          tcpSocket:
            port: 6379
      - name: cloud-sql-proxy
        image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2
        args:
        - --address=0.0.0.0
        - --port=5432
        - $CloudSqlInstance
        resources:
          limits:
            cpu: 500m
            memory: 256Mi
        startupProbe:
          failureThreshold: 12
          periodSeconds: 5
          timeoutSeconds: 5
          tcpSocket:
            port: 5432
      - name: twenty-app
        image: $ImageUrl
        ports:
        - name: http1
          containerPort: 3000
        env:
        - name: NODE_PORT
          value: '3000'
        - name: SERVER_URL
          value: $ServerUrl
        - name: REDIS_URL
          value: redis://localhost:6379
        - name: DISABLE_DB_MIGRATIONS
          value: 'false'
        - name: DISABLE_CRON_JOBS_REGISTRATION
          value: 'false'
        - name: APP_VERSION
          value: '0.0.0'
        - name: PG_DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: $PgDatabaseUrlSecret
              key: latest
        - name: ENCRYPTION_KEY
          valueFrom:
            secretKeyRef:
              name: $EncryptionKeySecret
              key: latest
        - name: APP_SECRET
          valueFrom:
            secretKeyRef:
              name: $AppSecretSecret
              key: latest
        resources:
          limits:
            cpu: '1'
            memory: 2Gi
        startupProbe:
          failureThreshold: 60
          periodSeconds: 10
          timeoutSeconds: 5
          tcpSocket:
            port: 3000
  traffic:
  - percent: 100
    latestRevision: true
"@

$tempYamlPath = Join-Path ([System.IO.Path]::GetTempPath()) "$ServiceName-cloud-run.yaml"
Set-Content -Path $tempYamlPath -Value $serviceYaml -Encoding utf8

Invoke-Gcloud run services replace $tempYamlPath `
  --project=$ProjectId `
  --region=$Region

try {
  Invoke-Gcloud run services add-iam-policy-binding $ServiceName `
    --project=$ProjectId `
    --region=$Region `
    --member=allUsers `
    --role=roles/run.invoker `
    --quiet
}
catch {
  Write-Warning "Cloud Run deployed, but public allUsers invoker binding failed. This usually means an organization policy blocks public services. Error: $($_.Exception.Message)"
}
