param(
    [string]$Environment = "dev",   # dev | test | prod
    [string]$ProjectName = "twin"
)
$ErrorActionPreference = "Stop"

Write-Host "Deploying $ProjectName to $Environment ..." -ForegroundColor Green

# 1. Build Lambda package
Set-Location (Split-Path $PSScriptRoot -Parent)   # project root
Write-Host "Building Lambda package..." -ForegroundColor Yellow
Set-Location backend
uv run deploy.py
Set-Location ..

# 2. Terraform workspace & apply
Set-Location terraform
$awsAccountId = aws sts get-caller-identity --query Account --output text
$awsRegion = if ($env:DEFAULT_AWS_REGION) { $env:DEFAULT_AWS_REGION } else { "us-east-1" }
terraform init -input=false `
  -backend-config="bucket=twin-terraform-state-$awsAccountId" `
  -backend-config="key=$Environment/terraform.tfstate" `
  -backend-config="region=$awsRegion" `
  -backend-config="dynamodb_table=twin-terraform-locks" `
  -backend-config="encrypt=true"

if (-not (terraform workspace list | Select-String $Environment)) {
    terraform workspace new $Environment
} else {
    terraform workspace select $Environment
}

if ($Environment -eq "prod") {
    terraform apply -var-file="prod.tfvars" -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
} else {
    terraform apply -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
}

$ApiUrl        = terraform output -raw api_gateway_url
$FrontendBucket = terraform output -raw s3_frontend_bucket
try { $CustomUrl = terraform output -raw custom_domain_url } catch { $CustomUrl = "" }

# 3. Build + deploy frontend
Set-Location ..\frontend

npm install
npm run build

Write-Host "Checking export output..." -ForegroundColor Yellow

if (-Not (Test-Path ".\out\index.html")) {
    Write-Host "❌ ERROR: out/index.html not found" -ForegroundColor Red
    Write-Host "Contents of frontend:" -ForegroundColor Yellow
    Get-ChildItem -Recurse
    exit 1
}

Write-Host "Uploading to S3..." -ForegroundColor Green

aws s3 sync .\out "s3://$FrontendBucket/" --delete
Set-Location ..

# 4. Final summary
$CfUrl = terraform -chdir=terraform output -raw cloudfront_url
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "CloudFront URL : $CfUrl" -ForegroundColor Cyan
if ($CustomUrl) {
    Write-Host "Custom domain  : $CustomUrl" -ForegroundColor Cyan
}
Write-Host "API Gateway    : $ApiUrl" -ForegroundColor Cyan
