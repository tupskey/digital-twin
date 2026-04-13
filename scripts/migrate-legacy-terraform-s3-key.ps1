param(
    [Parameter(Mandatory = $true)]
    [string]$Bucket,
    [Parameter(Mandatory = $true)]
    [string]$Workspace
)

$ErrorActionPreference = "Stop"
$ws = $Workspace.Trim()
if ([string]::IsNullOrWhiteSpace($ws)) { return }

# Old layout: backend key was "<ws>/terraform.tfstate" with a workspace named <ws>
# -> S3 object "env:/<ws>/<ws>/terraform.tfstate". New layout uses key "terraform.tfstate"
# -> "env:/<ws>/terraform.tfstate".
$legacyKey = "env:/${ws}/${ws}/terraform.tfstate"
$newKey = "env:/${ws}/terraform.tfstate"

aws s3api head-object '--bucket' $Bucket '--key' $newKey 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { return }

aws s3api head-object '--bucket' $Bucket '--key' $legacyKey 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { return }

Write-Host "Migrating Terraform remote state: $legacyKey -> $newKey" -ForegroundColor Yellow
$enc = [uri]::EscapeDataString($legacyKey)
$copySource = "${Bucket}/${enc}"
aws s3api copy-object `
    '--bucket' $Bucket `
    '--copy-source' $copySource `
    '--key' $newKey `
    '--server-side-encryption' 'AES256'
if ($LASTEXITCODE -ne 0) {
    throw "Failed to copy Terraform state to the new S3 key (exit $LASTEXITCODE)."
}
