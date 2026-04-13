param(
    [Parameter(Mandatory=$false)]
    [string]$Environment = "dev",  #Defaults to 'dev' if no value provided
    [string]$ProjectName = "digital-twin"
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

function Get-UvExe {
    $cmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }
    $homeRoot = if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { $env:HOME } else { $env:USERPROFILE }
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($homeRoot)) {
        $candidates += @(
            (Join-Path $homeRoot ".local/bin/uv"),
            (Join-Path $homeRoot ".local\bin\uv.exe"),
            (Join-Path $homeRoot ".cargo/bin/uv"),
            (Join-Path $homeRoot ".cargo\bin\uv.exe")
        )
    }
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Invoke-BackendDeployPackage {
    $uv = Get-UvExe
    if ($uv) {
        & $uv run deploy.py
        if ($LASTEXITCODE -ne 0) { throw "uv run deploy.py failed (exit $LASTEXITCODE)." }
        return
    }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if ($py) {
        Write-Host "uv not found; running deploy.py with $($py.Name)." -ForegroundColor Yellow
        & $py.Path deploy.py
        if ($LASTEXITCODE -ne 0) { throw "python deploy.py failed (exit $LASTEXITCODE)." }
        return
    }
    Write-Error "Neither 'uv' nor 'python' was found. Install uv (https://docs.astral.sh/uv/getting-started/installation/) or Python 3.12+."
    exit 1
}

Write-Host "Deploying $ProjectName to $Environment ..." -ForegroundColor Green

# 1. Build Lambda package
$ProjectRoot = Split-Path $PSScriptRoot -Parent
Set-Location $ProjectRoot

# Load .env variables into the Process environment
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

# --- Fix: Robust OpenRouter Key Bridging ---
# Ensure TF_VAR_openrouter_api_key is set only if a non-empty key exists
if (-not [string]::IsNullOrWhiteSpace($env:OPENROUTER_API_KEY)) {
    $env:TF_VAR_openrouter_api_key = $env:OPENROUTER_API_KEY.Trim()
}

if (-not [string]::IsNullOrWhiteSpace($env:TF_VAR_openrouter_api_key)) {
    $maskedKey = $env:TF_VAR_openrouter_api_key.Substring(0, 10) + "..."
    Write-Host "Using OpenRouter Key: $maskedKey" -ForegroundColor Gray
} else {
    Write-Warning "No OpenRouter API Key found in environment variables."
}

if ($env:GITHUB_ACTIONS -eq "true") {
    if (-not [string]::IsNullOrWhiteSpace($env:TF_VAR_openrouter_api_key)) {
        Write-Host "GitHub Actions: API Key verified." -ForegroundColor Cyan
    } else {
        Write-Warning "GitHub Actions: API Key is MISSING."
    }
}

Write-Host "Building Lambda package..." -ForegroundColor Yellow
Set-Location backend
Invoke-BackendDeployPackage
Set-Location ..

# 2. Terraform workspace & apply
Set-Location terraform
# Inside (...), PowerShell parses '--query' as the '--' operator; quote AWS flags.
$awsAccountId = (aws sts get-caller-identity '--query' 'Account' '--output' 'text').Trim()
$tf = Get-TerraformExe
if (-not $tf) {
    Write-Error "Terraform is not on PATH and was not found in common install locations. Install Terraform and retry."
    exit 1
}
$awsRegion = if (-not [string]::IsNullOrWhiteSpace($env:DEFAULT_AWS_REGION)) {
    $env:DEFAULT_AWS_REGION.Trim()
} else {
    "eu-west-2"
}

# Ensure S3 Backend exists (Fix for LocationConstraint handled inside this script)
& (Join-Path $PSScriptRoot "ensure-terraform-backend.ps1") -AccountId $awsAccountId -Region $awsRegion

# Splat args so pwsh never treats "--" / continuation lines as operators (fixes GHA / Linux).
$initArgs = @(
    'init', '-input=false',
    "-backend-config=bucket=twin-terraform-state-$awsAccountId",
    "-backend-config=key=$Environment/terraform.tfstate",
    "-backend-config=region=$awsRegion",
    '-backend-config=use_lockfile=true',
    '-backend-config=encrypt=true'
)
& $tf @initArgs

# --- Fix: Workspace Selection Logic ---
$currentWorkspaces = & $tf @('workspace', 'list')
# Use regex boundary \b to ensure we don't match 'dev' inside 'dev-test'
if ($currentWorkspaces -match "\b$Environment\b") {
    Write-Host "Selecting workspace: $Environment" -ForegroundColor Gray
    & $tf @('workspace', 'select', $Environment)
} else {
    Write-Host "Creating new workspace: $Environment" -ForegroundColor Yellow
    & $tf @('workspace', 'new', $Environment)
}

if ($Environment -eq "prod") {
    & $tf @(
        'apply', '-var-file=prod.tfvars',
        "-var=project_name=$ProjectName", "-var=environment=$Environment", '-auto-approve'
    )
} else {
    & $tf @('apply', "-var=project_name=$ProjectName", "-var=environment=$Environment", '-auto-approve')
}

# ... after terraform apply ...

Write-Host "Fetching outputs..." -ForegroundColor Yellow

# Use -json and parse it to be more robust, or stay with -raw but add a check
$FrontendBucket = & $tf @('output', '-raw', 's3_frontend_bucket')
$ApiUrl         = & $tf @('output', '-raw', 'api_gateway_url')

# VALIDATION: Stop early if outputs are missing
if ([string]::IsNullOrWhiteSpace($FrontendBucket)) {
    Write-Error "CRITICAL: Frontend bucket name is empty! Check if 's3_frontend_bucket' is defined in outputs.tf"
    exit 1
}

Write-Host "Deploying to bucket: $FrontendBucket" -ForegroundColor Gray
try { $CustomUrl = & $tf @('output', '-raw', 'custom_domain_url') } catch { $CustomUrl = "" }

# 3. Build + deploy frontend
Set-Location ..\frontend

Write-Host "Setting API URL for production..." -ForegroundColor Yellow
"NEXT_PUBLIC_API_URL=$ApiUrl" | Out-File .env.production -Encoding utf8

npm install
if ($LASTEXITCODE -ne 0) { throw "npm install failed." }
npm run build
if ($LASTEXITCODE -ne 0) { throw "npm run build failed." }

$frontendOut = Join-Path (Get-Location) "out"
if (-not (Test-Path -Path $frontendOut -PathType Container)) {
    throw "Static export folder not found: $frontendOut."
}

& $tf @('output')
aws s3 sync "$frontendOut" "s3://$FrontendBucket/" '--delete'
if ($LASTEXITCODE -ne 0) { throw "aws s3 sync failed." }
Set-Location ..

# 4. Final summary
$CfUrl = & $tf @('-chdir=terraform', 'output', '-raw', 'cloudfront_url')
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "CloudFront URL : $CfUrl" -ForegroundColor Cyan
if ($CustomUrl -and $CustomUrl -notmatch "Output not found") {
    Write-Host "Custom domain  : $CustomUrl" -ForegroundColor Cyan
}
Write-Host "API Gateway    : $ApiUrl" -ForegroundColor Cyan