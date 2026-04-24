#!/usr/bin/env bash
# =============================================================================
# RUNBOOK: Migrate CI/CD IAM resources from main workspace to cicd workspace
#
# WHAT THIS DOES
#   Moves the GitHub Actions IAM roles (site-deploy, terraform-plan,
#   terraform-apply) and the OIDC provider out of the main Terraform workspace
#   into a dedicated cicd/ workspace. After migration, the main workspace
#   manages only site infrastructure (S3, CloudFront, ACM, Route53, KMS).
#
# WHY
#   A workspace must not manage its own execution roles. Doing so creates a
#   circular dependency: if a permission is missing, Terraform cannot refresh
#   resources to apply the fix that adds the permission. The cicd/ workspace
#   is run manually with SSO credentials, so this deadlock is impossible.
#
# PREREQUISITES
#   - AWS SSO credentials active with IAM read/write access
#     (run: aws sso login --profile <your-profile>)
#   - Terraform ~> 1.9 installed
#   - Working directory: repository root (brad-duhon.com/)
#
# ORDER MATTERS
#   This runbook must be executed in section order. Do NOT skip or reorder.
#   Each section has a verification step — do not proceed until it passes.
#
# DESTRUCTIVE STEPS
#   Marked with [DESTRUCTIVE] below. Read the ramifications before running.
#
# RECOVERY
#   If anything goes wrong after section 3 but before section 5, the IAM
#   resources still exist in AWS — nothing has been deleted. You can re-import
#   them into either workspace at any time. The only unrecoverable action would
#   be running terraform destroy, which this runbook never does.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
MAIN_WS="${REPO_ROOT}/infrastructure"
CICD_WS="${REPO_ROOT}/infrastructure/cicd"

# ---------------------------------------------------------------------------
# SECTION 0 — Pre-flight checks
#
# Verify credentials are active and the expected resources exist in AWS before
# touching any Terraform state.
# ---------------------------------------------------------------------------

echo "=== SECTION 0: Pre-flight checks ==="

echo "--- Checking AWS identity ---"
aws sts get-caller-identity
# Expected: your SSO user/role ARN. If this fails, run: aws sso login

echo ""
echo "--- Checking expected IAM roles exist ---"
for role in brad-duhon-site-deploy brad-duhon-terraform-plan brad-duhon-terraform-apply; do
  aws iam get-role --role-name "${role}" --query 'Role.RoleName' --output text
  echo "  OK: ${role}"
done

echo ""
echo "--- Checking OIDC provider exists ---"
aws iam list-open-id-connect-providers \
  --query 'OpenIDConnectProviderList[?contains(Arn, `token.actions.githubusercontent.com`)].Arn' \
  --output text
# Expected: arn:aws:iam::046819497747:oidc-provider/token.actions.githubusercontent.com

echo ""
echo "--- Checking for stale bootstrap inline policy (should be empty) ---"
# This policy was added as a temporary workaround during the skip_refresh
# incident. It must be removed before migration to avoid state drift.
aws iam list-role-policies \
  --role-name brad-duhon-terraform-apply \
  --query 'PolicyNames' \
  --output text
# Expected: brad-duhon-terraform-apply  (only the one managed policy, not the bootstrap one)
# If brad-duhon-terraform-apply-bootstrap appears, run the cleanup below before continuing.

# CLEANUP (only if brad-duhon-terraform-apply-bootstrap appears above):
# aws iam delete-role-policy \
#   --role-name brad-duhon-terraform-apply \
#   --policy-name brad-duhon-terraform-apply-bootstrap

echo ""
echo "Pre-flight checks complete. Review output above before continuing."
echo "Press Enter to proceed to Section 1, or Ctrl+C to abort."
read -r

# ---------------------------------------------------------------------------
# SECTION 1 — Initialize the cicd workspace
#
# Sets up the Terraform backend for the new cicd/ workspace using the shared
# backend config. This creates a new, empty state file at key=cicd/terraform.tfstate
# in the same S3 bucket used by the main workspace.
#
# NOT DESTRUCTIVE — creates a new empty state, does not touch any existing state.
# ---------------------------------------------------------------------------

echo "=== SECTION 1: Initialize cicd workspace ==="

cd "${CICD_WS}"

terraform init \
  -backend-config=../shared/backend.hcl \
  -backend-config="key=cicd/terraform.tfstate"

echo "Init complete."
echo "Press Enter to proceed to Section 2, or Ctrl+C to abort."
read -r

# ---------------------------------------------------------------------------
# SECTION 2 — Import existing AWS resources into cicd workspace state
#
# Brings the seven existing IAM resources into the cicd workspace state
# WITHOUT modifying anything in AWS. This is a state-only operation.
#
# After this section the cicd workspace state tracks all seven resources.
# The main workspace state ALSO still tracks them — this duplication is
# intentional and safe at this stage. It will be resolved in Section 3.
#
# NOT DESTRUCTIVE — import is a read-only AWS operation. Nothing is created,
# modified, or deleted in AWS. If any import fails, re-run that import line.
#
# Resource import ID formats:
#   aws_iam_openid_connect_provider  -> full ARN
#   aws_iam_role                     -> role name
#   aws_iam_role_policy              -> role_name:policy_name
# ---------------------------------------------------------------------------

echo "=== SECTION 2: Import resources into cicd workspace ==="

cd "${CICD_WS}"

echo "--- Importing OIDC provider ---"
terraform import \
  aws_iam_openid_connect_provider.github \
  "arn:aws:iam::046819497747:oidc-provider/token.actions.githubusercontent.com"

echo "--- Importing site-deploy role ---"
terraform import aws_iam_role.site_deploy brad-duhon-site-deploy

echo "--- Importing site-deploy inline policy ---"
terraform import aws_iam_role_policy.site_deploy brad-duhon-site-deploy:brad-duhon-site-deploy

echo "--- Importing terraform-plan role ---"
terraform import aws_iam_role.terraform_plan brad-duhon-terraform-plan

echo "--- Importing terraform-plan inline policy ---"
terraform import aws_iam_role_policy.terraform_plan brad-duhon-terraform-plan:brad-duhon-terraform-plan

echo "--- Importing terraform-apply role ---"
terraform import aws_iam_role.terraform_apply brad-duhon-terraform-apply

echo "--- Importing terraform-apply inline policy ---"
terraform import aws_iam_role_policy.terraform_apply brad-duhon-terraform-apply:brad-duhon-terraform-apply

echo "All imports complete."
echo "Press Enter to proceed to Section 3 (verify), or Ctrl+C to abort."
read -r

# ---------------------------------------------------------------------------
# SECTION 3 — Verify cicd workspace plan is clean
#
# Run terraform plan against the cicd workspace. The expected result is:
#   "No changes. Your infrastructure matches the configuration."
#
# If the plan shows changes it means the imported resource state does not
# match the new Terraform configuration (likely a policy difference due to
# the migration from exact ARNs to naming-convention scoping). Review the
# diff carefully:
#
#   - Policy statement ADDITIONS are expected and safe (we added missing
#     permissions like dynamodb:DescribeTable, cloudfront:DescribeFunction).
#   - Policy statement REMOVALS are expected for IAM management permissions
#     (terraform-plan and terraform-apply no longer manage IAM resources).
#   - Trust policy changes: there should be none.
#   - If roles would be DESTROYED or RECREATED, stop and investigate.
#
# DO NOT proceed to Section 4 if the plan shows role destruction.
# SEMI-DESTRUCTIVE — plan applies policy updates to the live roles. This is
# intentional and the desired end state. Review the diff before typing 'yes'.
# ---------------------------------------------------------------------------

echo "=== SECTION 3: Verify and apply cicd workspace ==="

cd "${CICD_WS}"

terraform plan

echo ""
echo "Review the plan output above."
echo "Expected: No role creation/destruction. Policy updates are expected."
echo "Press Enter to apply, or Ctrl+C to abort."
read -r

terraform apply

echo "cicd workspace apply complete."
echo "Press Enter to proceed to Section 4, or Ctrl+C to abort."
read -r

# ---------------------------------------------------------------------------
# SECTION 4 — Remove IAM resources from main workspace state
#
# [DESTRUCTIVE TO MAIN WORKSPACE STATE — NOT DESTRUCTIVE TO AWS]
#
# Removes the seven IAM resources from the main workspace's Terraform state.
# After this step, the main workspace no longer tracks these resources.
# They continue to exist in AWS (now tracked only by the cicd workspace).
#
# RAMIFICATIONS:
#   - If you ran terraform plan/apply on the main workspace with cicd.tf
#     still present AFTER this step but BEFORE Section 5 removes it,
#     Terraform would see IAM resources in code but not in state and attempt
#     to CREATE them again. This would fail because they already exist in AWS.
#     Recovery: re-run Section 2 to re-import into main workspace state,
#     then redo Section 4 after completing Section 5.
#
#   - terraform state rm does not call any AWS APIs. It only modifies the
#     local state lock/write. It is safe to re-run if interrupted.
#
# Execute Section 4 and Section 5 in the same sitting without running any
# terraform plan/apply on the main workspace between them.
# ---------------------------------------------------------------------------

echo "=== SECTION 4: Remove IAM resources from main workspace state ==="

cd "${MAIN_WS}"

echo "--- Removing OIDC provider from main state ---"
terraform state rm aws_iam_openid_connect_provider.github

echo "--- Removing site-deploy role and policy from main state ---"
terraform state rm aws_iam_role.site_deploy
terraform state rm aws_iam_role_policy.site_deploy

echo "--- Removing terraform-plan role and policy from main state ---"
terraform state rm aws_iam_role.terraform_plan
terraform state rm aws_iam_role_policy.terraform_plan

echo "--- Removing terraform-apply role and policy from main state ---"
terraform state rm aws_iam_role.terraform_apply
terraform state rm aws_iam_role_policy.terraform_apply

echo "State rm complete. Proceeding immediately to Section 5."
echo "Press Enter to continue. Do NOT run terraform plan/apply on the main workspace before Section 5 completes."
read -r

# ---------------------------------------------------------------------------
# SECTION 5 — Remove cicd.tf from main workspace and verify
#
# Deletes infrastructure/cicd.tf, which contains the IAM resource definitions
# that have now been migrated. Also removes the dangling data source and locals
# that were only used by those resources.
#
# After deletion, terraform plan on the main workspace should show:
#   "No changes. Your infrastructure matches the configuration."
#
# If it shows changes, review carefully. Unexpected deletes of non-IAM
# resources would indicate a problem — abort and investigate.
#
# DESTRUCTIVE TO CODE — cicd.tf is deleted. It is recoverable from git
# history if needed, but should not be needed after this migration.
# ---------------------------------------------------------------------------

echo "=== SECTION 5: Remove cicd.tf from main workspace ==="

cd "${MAIN_WS}"

echo "--- Deleting infrastructure/cicd.tf ---"
rm -f "${MAIN_WS}/cicd.tf"

echo "--- Running plan on main workspace to verify clean state ---"
terraform plan

echo ""
echo "Expected: No changes."
echo "If plan shows changes, review before applying. Do not apply destructive changes."
echo "Press Enter to confirm plan is clean and run apply, or Ctrl+C to abort."
read -r

terraform apply

echo "Main workspace apply complete."

# ---------------------------------------------------------------------------
# SECTION 6 — Final cleanup and commit
#
# Post-migration cleanup steps. None of these are destructive.
# ---------------------------------------------------------------------------

echo "=== SECTION 6: Final cleanup ==="

cd "${REPO_ROOT}"

echo "--- Verifying cicd workspace outputs ---"
cd "${CICD_WS}"
terraform output
# Confirm the three role ARNs match what is in your GitHub repository secrets:
#   AWS_ROLE_ARN       -> site_deploy_role_arn
#   TF_PLAN_ROLE_ARN   -> terraform_plan_role_arn
#   TF_APPLY_ROLE_ARN  -> terraform_apply_role_arn

echo ""
echo "--- Verifying main workspace state no longer contains IAM resources ---"
cd "${MAIN_WS}"
terraform state list | grep -E "aws_iam|oidc" && echo "WARNING: IAM resources still in main state" || echo "OK: No IAM resources in main state"

echo ""
echo "--- Commit the migration ---"
cd "${REPO_ROOT}"
git add infrastructure/cicd/ infrastructure/shared/ infrastructure/MIGRATION_RUNBOOK.sh
git rm infrastructure/cicd.tf
# Review staged changes before committing
git diff --staged --stat
echo ""
echo "Review the staged diff above, then commit:"
echo "  git commit -m 'Migrate CI/CD IAM roles to dedicated cicd workspace'"
echo "  git push origin main"
echo ""
echo "--- Post-migration: remove skip_refresh from terraform-apply.yml ---"
echo "The skip_refresh workflow option was a workaround for the IAM deadlock."
echo "The cicd/ workspace eliminates the condition that made it necessary."
echo "Remove it from .github/workflows/terraform-apply.yml once you have"
echo "confirmed the main workspace runs cleanly for one full cycle."

echo ""
echo "=== MIGRATION COMPLETE ==="
echo "Future IAM changes: cd infrastructure/cicd && terraform plan && terraform apply"
