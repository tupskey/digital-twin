param(
    [Parameter(Mandatory=$false)]
    [string]$Environment = "dev",  # Fix: Default to dev
    [string]$ProjectName = "digital-twin" # Match your deploy.ps1 default
)

$ErrorActionPreference = "Stop"

function Get-TerraformExe {
    $cmd = Get-Command terraform -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }
    $homeRoot = if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { $env:HOME } else { $env:USERPROFILE }
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\terraform\terraform.exe")
    }
    $candidates += @(
        "C:\Program Files\Terraform\terraform.exe",
        (Join-Path $homeRoot ".local/bin/terraform"),
        "/usr/local/bin/terraform"
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

# Validate environment parameter
if ($Environment -notmatch '^(dev|test|prod)$') {
    Write-Host "Error: Invalid environment '$Environment'" -ForegroundColor Red
    Write-Host "Available environments: dev, test, prod" -ForegroundColor Yellow
    exit 1
}

Write-Host "Preparing to destroy $ProjectName-$Environment infrastructure..." -ForegroundColor Red

# 1. Setup Environment & Paths
$ProjectRoot = Split-Path $PSScriptRoot -Parent
Set-Location (Join-Path $ProjectRoot "terraform")

# Load .env for variable bridging (needed for TF validation)
$dotenvPath = Join-Path $ProjectRoot ".env"
if (Test-Path $dotenvPath) {
    Get-Content $dotenvPath | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { return }
        $eq = $line.IndexOf("=")
        if ($eq -lt 1) { return }
        $name = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim()
        if ($val.Length -ge 2 -and (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'")))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        if ($name) { [Environment]::SetEnvironmentVariable($name, $val, "Process") }
    }
}

# Bridge API Key (Terraform needs this to pass variable validation)
if (-not [string]::IsNullOrWhiteSpace($env:OPENROUTER_API_KEY)) {
    $env:TF_VAR_openrouter_api_key = $env:OPENROUTER_API_KEY.Trim()
}

# 2. AWS Identity & Backend
$awsAccountId = (aws sts get-caller-identity '--query' 'Account' '--output' 'text').Trim()
$awsRegion = if (-not [string]::IsNullOrWhiteSpace($env:DEFAULT_AWS_REGION)) {
    $env:DEFAULT_AWS_REGION.Trim()
} else {
    "eu-west-2"
}

$tf = Get-TerraformExe
if (-not $tf) {
    Write-Error "Terraform is not on PATH and was not found in common install locations. Install Terraform and retry."
    exit 1
}

# Ensure backend exists before init
& (Join-Path $PSScriptRoot "ensure-terraform-backend.ps1") -AccountId $awsAccountId -Region $awsRegion

Write-Host "Initializing Terraform..." -ForegroundColor Yellow
$initArgs = @(
    'init', '-input=false',
    "-backend-config=bucket=twin-terraform-state-$awsAccountId",
    "-backend-config=key=$Environment/terraform.tfstate",
    "-backend-config=region=$awsRegion",
    '-backend-config=use_lockfile=true',
    '-backend-config=encrypt=true'
)
& $tf @initArgs

# 3. Workspace Selection (Fix: Match deploy.ps1 logic)
$currentWorkspaces = & $tf @('workspace', 'list')
if ($currentWorkspaces -match "\b$Environment\b") {
    & $tf @('workspace', 'select', $Environment)
} else {
    Write-Warning "Workspace '$Environment' not found. Nothing to destroy."
    exit 0
}

# 4. Empty S3 Buckets (Fix: Aligned with Terraform locals)
# local.name_prefix = "${var.project_name}-${var.environment}"
$Prefix = "$ProjectName-$Environment"
$FrontendBucket = "$Prefix-frontend-$awsAccountId"
$MemoryBucket = "$Prefix-memory-$awsAccountId"

Write-Host "Emptying S3 buckets to allow destruction..." -ForegroundColor Yellow

foreach ($Bucket in @($FrontendBucket, $MemoryBucket)) {
    Write-Host "  Checking $Bucket..." -ForegroundColor Gray
    # Check if bucket exists before trying to empty it (stderr must not stop the script)
    $headOk = $false
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $null = aws s3api head-bucket '--bucket' $Bucket 2>$null
        $headOk = ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    if ($headOk) {
        Write-Host "  Emptying $Bucket..." -ForegroundColor Gray
        aws s3 rm "s3://$Bucket" '--recursive'
    }
}

# 5. Destroy
# Terraform still evaluates aws_lambda_function.filename / source_code_hash during destroy; ensure zip exists.
$lambdaZip = Join-Path $ProjectRoot "backend/lambda-deployment.zip"
if (-not (Test-Path -LiteralPath $lambdaZip)) {
    Write-Host "Creating minimal stub lambda-deployment.zip for Terraform (destroy-only)..." -ForegroundColor Yellow
    $zipDir = Split-Path -Parent $lambdaZip
    if (-not (Test-Path -LiteralPath $zipDir)) {
        New-Item -ItemType Directory -Path $zipDir -Force | Out-Null
    }
    $emptyZip = [byte[]](
        0x50, 0x4b, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    )
    [System.IO.File]::WriteAllBytes($lambdaZip, $emptyZip)
}

Write-Host "Running terraform destroy..." -ForegroundColor Red

$destroyArgs = @('destroy', '-var', "project_name=$ProjectName", '-var', "environment=$Environment", '-auto-approve')
if ($Environment -eq "prod" -and (Test-Path "prod.tfvars")) {
    $destroyArgs = @('destroy', '-var-file', 'prod.tfvars', '-var', "project_name=$ProjectName", '-var', "environment=$Environment", '-auto-approve')
}

& $tf @destroyArgs

Write-Host "Infrastructure for $Environment has been destroyed!" -ForegroundColor Green
Write-Host ""
Write-Host "To clean up the workspace state from S3, run:" -ForegroundColor Cyan
Write-Host "  terraform workspace select default  # from the terraform/ directory"
Write-Host "  terraform workspace delete $Environment"