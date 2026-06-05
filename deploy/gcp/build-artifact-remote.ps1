param(
  [Parameter(Mandatory = $true)]
  [string] $ProjectId,

  [string] $Region = "us-central1",

  [string] $ArtifactRepository = "twenty",

  [string] $ImageName = "twenty",

  [string] $ChannelTag = "dev",

  [string] $DockerTarget = "twenty",

  [string] $RepoUrl = "https://github.com/6ALog/twenty.git",

  [string] $GitRef = "gcp-artifact-pipeline"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "../..")
$cloudBuildFile = Join-Path $repoRoot "cloudbuild.remote.yaml"

if (-not (Test-Path -LiteralPath $cloudBuildFile)) {
  throw "Could not find cloudbuild.remote.yaml at $cloudBuildFile"
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
  "_DOCKER_TARGET=$DockerTarget",
  "_REPO_URL=$RepoUrl",
  "_GIT_REF=$GitRef"
) -join ","

gcloud builds submit `
  --no-source `
  --config="$cloudBuildFile" `
  --substitutions="$substitutions"
