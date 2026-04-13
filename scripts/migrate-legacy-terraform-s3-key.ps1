param(
    [Parameter(Mandatory = $true)]
    [string]$Bucket,
    [Parameter(Mandatory = $true)]
    [string]$Workspace
)

$ErrorActionPreference = "Stop"
$ws = $Workspace.Trim()
if ([string]::IsNullOrWhiteSpace($ws)) { return }

# Old: backend key "<ws>/terraform.tfstate" + workspace <ws> -> env:/<ws>/<ws>/terraform.tfstate
# New: key "terraform.tfstate" + workspace <ws>           -> env:/<ws>/terraform.tfstate
$legacyKey = "env:/${ws}/${ws}/terraform.tfstate"
$newKey = "env:/${ws}/terraform.tfstate"

function Test-S3ObjectExists {
    param([string]$B, [string]$K)
    $null = aws s3api head-object '--bucket' $B '--key' $K 2>&1
    return ($LASTEXITCODE -eq 0)
}

# Piping aws to Out-Null breaks $LASTEXITCODE on Linux pwsh; use a helper instead.
if (Test-S3ObjectExists -B $Bucket -K $newKey) { return }

$sourceKey = $null
if (Test-S3ObjectExists -B $Bucket -K $legacyKey) {
    $sourceKey = $legacyKey
}
else {
    $listJson = aws s3api list-objects-v2 '--bucket' $Bucket "--prefix" "env:/${ws}/" '--output' 'json' 2>&1
    if ($LASTEXITCODE -ne 0) { return }
    $list = $listJson | ConvertFrom-Json
    if (-not $list.Contents) { return }
    $re = '^env:/' + [regex]::Escape($ws) + '/' + [regex]::Escape($ws) + '/terraform\.tfstate$'
    $hit = $list.Contents | Where-Object { $_.Key -match $re } | Select-Object -First 1
    if ($hit) { $sourceKey = $hit.Key }
}

if (-not $sourceKey) { return }

Write-Host "Migrating Terraform remote state: $sourceKey -> $newKey" -ForegroundColor Yellow

$srcUri = 's3://{0}/{1}' -f $Bucket, $sourceKey
$dstUri = 's3://{0}/{1}' -f $Bucket, $newKey
aws @('s3', 'cp', $srcUri, $dstUri, '--sse', 'AES256')
if ($LASTEXITCODE -ne 0) {
    throw "Failed to copy Terraform state to the new S3 key (exit $LASTEXITCODE)."
}
