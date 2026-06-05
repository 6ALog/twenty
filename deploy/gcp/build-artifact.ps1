param(
  [Parameter(Mandatory = $true)]
  [string] $ProjectId,

  [string] $Region = "us-central1",

  [string] $ArtifactRepository = "twenty",

  [string] $ImageName = "twenty",

  [string] $ChannelTag = "dev",

  [string] $DockerTarget = "twenty"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "../..")
$cloudBuildFile = Join-Path $repoRoot "cloudbuild.yaml"

if (-not (Test-Path -LiteralPath $cloudBuildFile)) {
  throw "Could not find cloudbuild.yaml at $cloudBuildFile"
}

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
  throw "gcloud is not installed or not on PATH. Install the Google Cloud SDK or run this from Cloud Shell."
}

gcloud config set project $ProjectId

$substitutions = @(
  "_REGION=$Region",
  "_ARTIFACT_REPOSITORY=$ArtifactRepository",
  "_IMAGE_NAME=$ImageName",
  "_CHANNEL_TAG=$ChannelTag",
  "_DOCKER_TARGET=$DockerTarget"
) -join ","

Push-Location $repoRoot
try {
  gcloud builds submit `
    --config="$cloudBuildFile" `
    --substitutions="$substitutions"
}
finally {
  Pop-Location
}
