project_name             = "twin"
environment              = "dev"
bedrock_model_id         = "amazon.nova-micro-v1:0"
# Set a real key locally, or export TF_VAR_openrouter_api_key / OPENROUTER_API_KEY before deploy.ps1
openrouter_api_key       = "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"
lambda_timeout           = 60
api_throttle_burst_limit = 10
api_throttle_rate_limit  = 5
use_custom_domain        = false
root_domain              = "" 