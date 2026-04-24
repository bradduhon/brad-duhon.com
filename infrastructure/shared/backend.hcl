# Shared S3 backend connection details for all workspaces in this project.
# Each workspace passes this file via:
#   terraform init -backend-config=../shared/backend.hcl -backend-config="key=<workspace>/terraform.tfstate"
#
# The key is intentionally omitted here so each workspace supplies its own.

bucket         = "brad-duhon-terraform-state"
region         = "us-east-1"
dynamodb_table = "brad-duhon-terraform-locks"
encrypt        = true
kms_key_id     = "alias/brad-duhon-terraform-state"
