param(
    [Parameter(Mandatory = $true)]
    [string]$AccountId,
    [Parameter(Mandatory = $true)]
    [string]$Region
)

$ErrorActionPreference = "Stop"

function Test-AwsCommand {
    param([scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        return (& $Command)
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

$AccountId = $AccountId.Trim()
if ([string]::IsNullOrWhiteSpace($AccountId)) {
    throw "AccountId is empty after trim; check 'aws sts get-caller-identity'."
}

$Region = $Region.Trim()
$bucketName = "twin-terraform-state-$AccountId"

$headRc = Test-AwsCommand { aws s3api head-bucket '--bucket' $bucketName 2>$null; $LASTEXITCODE }
if ($headRc -ne 0) {
    Write-Host "Creating S3 bucket for Terraform state: $bucketName ($Region) ..." -ForegroundColor Yellow
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($Region -eq "us-east-1") {
            $createOut = aws @('s3api', 'create-bucket', '--bucket', $bucketName, '--region', $Region) 2>&1
        }
        else {
            $cfg = "LocationConstraint=$Region"
            $createOut = aws @(
                's3api', 'create-bucket', '--bucket', $bucketName, '--region', $Region,
                '--create-bucket-configuration', $cfg
            ) 2>&1
        }
        if ($LASTEXITCODE -ne 0 -and "$createOut" -notmatch 'BucketAlreadyOwnedByYou') {
            throw "create-bucket failed ($LASTEXITCODE): $createOut"
        }

        $verOut = aws @(
            's3api', 'put-bucket-versioning', '--bucket', $bucketName,
            '--versioning-configuration', 'Status=Enabled'
        ) 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "put-bucket-versioning failed ($LASTEXITCODE): $verOut"
        }

        $encJson = '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
        # Linux runners often have no $env:TEMP; Join-Path $null throws "Cannot bind argument to parameter 'Path'".
        $encFile = Join-Path ([System.IO.Path]::GetTempPath()) ("twin-tf-s3-enc-{0}.json" -f [Guid]::NewGuid())
        try {
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($encFile, $encJson, $utf8NoBom)
            $encUri = "file:///" + (($encFile -replace '\\', '/') -replace '^/', '')
            $encOut = aws @(
                's3api', 'put-bucket-encryption', '--bucket', $bucketName,
                '--server-side-encryption-configuration', $encUri
            ) 2>&1
            $encRc = $LASTEXITCODE
            if ($encRc -ne 0) {
                throw "put-bucket-encryption failed ($encRc): $encOut"
            }
        }
        finally {
            Remove-Item -LiteralPath $encFile -Force -ErrorAction SilentlyContinue
        }

        $pabCfg = 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
        $pabOut = aws @(
            's3api', 'put-public-access-block', '--bucket', $bucketName,
            '--public-access-block-configuration', $pabCfg
        ) 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "put-public-access-block failed ($LASTEXITCODE): $pabOut"
        }
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
}
else {
    Write-Host "Terraform state bucket already exists: $bucketName" -ForegroundColor DarkGray
}

# Terraform S3 backend with use_lockfile stores locks in the bucket; no DynamoDB table required.