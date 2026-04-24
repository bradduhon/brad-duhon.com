---
title: "Post-mortem: the Terraform IAM circular dependency that one line of HCL uncovered"
date: 2026-04-23
tags: [terraform, aws, iam, cicd, infrastructure, security, postmortem]
description: "A one-line CloudFront change triggered a cascade of IAM permission failures, exposed an architectural design flaw in how CI/CD roles were managed, and required a full workspace refactor to resolve correctly. This is the honest account of what went wrong, what was tried, and what the right answer actually is."
draft: false
---

A one-line Terraform change - switching `X-Frame-Options` from `DENY` to `SAMEORIGIN` - should have been a ten-minute operation. Commit, push, done, go do something else. Instead it triggered a cascade of IAM permission failures, exposed a fundamental architectural mistake, and required a full workspace refactor to resolve correctly.

This is the honest account of what went wrong, what was tried, and why the right answer was obvious in retrospect (it always is).

---

## The trigger

The lab site embeds static HTML visuals in article pages using iframes. The visual was not rendering. Investigation pointed to CloudFront sending `X-Frame-Options: DENY` on every response - including the visual HTML file being loaded _inside_ the iframe. The browser sees `DENY` and refuses regardless of origin. Classic.

The fix is a one-line change in `infrastructure/cloudfront_shared.tf`:

```hcl
frame_options {
  frame_option = "SAMEORIGIN"  # was DENY
  override     = true
}
```

`SAMEORIGIN` still blocks external sites from framing your pages. It just allows same-origin iframes, which is exactly what these visuals are. `terraform apply`, ship it.

That is not what happened.

---

## The cascade

The apply failed immediately:

```
Error: reading S3 Bucket (brad-duhon-site-main) ACL: operation error S3: GetBucketAcl
  AccessDenied: ...brad-duhon-terraform-apply... is not authorized to perform: s3:GetBucketAcl
```

A missing IAM permission. Fine. `s3:GetBucketAcl` added, commit, apply again.

```
Error: reading DynamoDB Table (brad-duhon-terraform-locks): DescribeTable AccessDenied
Error: reading KMS Alias (alias/brad-duhon-terraform-state): ListAliases AccessDenied
Error: reading CloudFront Function (brad-duhon-url-rewrite): DescribeFunction AccessDenied
Error: reading KMS Key (...): DescribeKey AccessDenied
```

Four more. All at once, because Terraform only got far enough on the first run to hit the S3 error. Fix the first permission and it runs further into the refresh phase before hitting the next wall.

This is the IAM whack-a-mole problem. Each apply exposes exactly one error at a time - the first one in the resource graph - so fixing permissions iteratively means triggering a new workflow run per error. And each run fails at a different point before applying any changes.

The `kms:DescribeKey` error was its own special detour. The role policy used `kms:RequestAlias` as a condition to scope KMS access by alias name. This condition is only set when the API call itself specifies a key by alias. Terraform accesses keys by ARN from state. So the condition was _never_ present, and every KMS API call was denied regardless of which key was being accessed. More on this in the lessons section.

Each of the above errors required a commit, a `workflow_dispatch` trigger, and a wait for the runner. After three cycles with no net progress, it was clear that fixing permissions one at a time was not going to work.

---

## The root cause

The `infrastructure/` main workspace managed the GitHub Actions IAM roles (`terraform-plan`, `terraform-apply`, `site-deploy`) alongside the site infrastructure it was also responsible for deploying. When the apply role was missing a permission, Terraform needed that permission to refresh existing resources before it could apply the policy change that would grant the permission.

```
terraform apply
  -> refresh aws_s3_bucket      (needs s3:GetBucketAcl)
  -> FAIL: AccessDenied
  -> never reaches the IAM policy update that would add s3:GetBucketAcl
```

You cannot escape this loop with incremental fixes. Every attempt to apply the fix requires the permissions you are trying to grant. The workspace is locked out of fixing itself.

This is not a subtle edge case or a misconfiguration that can be patched. It is a structural property of the design. The moment any required permission is absent, the system cannot self-repair without external intervention. It was only a matter of time before a permission gap surfaced it.

---

## What was tried first (the wrong answers)

**Incremental permission additions.** Add the missing permission, commit, apply, fail on the next one, repeat. Four failed apply cycles, zero forward progress. Not a strategy.

**Manual console edits.** Add the missing permissions directly in the AWS IAM console so Terraform has enough access to run. This technically works but it creates drift between actual IAM state and the Terraform source, and it requires a human with console access to intervene in what is supposed to be a fully automated pipeline. It also does not feel good.

**AWS CLI injection.** Use `aws iam put-role-policy` from a local terminal with personal SSO credentials to attach a temporary supplementary policy, run apply, then delete the temporary policy. This also works but it is the same problem with extra steps: a human with elevated credentials manually intervening in CI/CD. Good workaround, wrong architecture.

**`-refresh=false` workflow flag.** A `skip_refresh` boolean input was added to `terraform-apply.yml`. When enabled, Terraform skips the resource refresh phase and applies using cached state instead of making live API calls. This broke the deadlock - apply succeeded with `skip_refresh=true` - but it is a workaround for a problem that should not exist. Skipping refresh means Terraform is not verifying that actual infrastructure matches declared state before applying changes. It worked here only because nothing had changed outside of Terraform. It is not a general solution, and committing an escape hatch to a workflow is how normal process gets bypassed later.

Every one of these approaches treated the symptom rather than the cause.

---

## The architectural mistake

The structure that caused this:

```
infrastructure/
  bootstrap/     <- state bucket, lock table
  modules/
  cicd.tf        <- IAM roles embedded in the main workspace
  *.tf           <- site infrastructure
```

A previous project had the correct structure - and it had been explicitly proposed during initial setup and dismissed. The reasoning was that a single workspace was simpler and the circular dependency was unlikely to surface.

Both of those claims were wrong.

The correct structure:

```
infrastructure/
  bootstrap/     <- state bucket, lock table (run once at project start)
  cicd/          <- IAM roles (run manually with SSO credentials)
  *.tf           <- site infrastructure (run by GitHub Actions)
```

The dedicated `cicd/` workspace exists precisely because IAM role changes are infrequent, require elevated credentials, and benefit from a human explicitly in the loop. That is not a workflow to route through the same pipeline the roles enable.

---

## The proper fix

Three workspaces, clear ownership:

```
infrastructure/
  bootstrap/       owns: S3 state bucket, DynamoDB lock table
                   run: once at project start, rarely after
                   credentials: admin SSO

  cicd/            owns: OIDC provider, terraform-plan role,
                         terraform-apply role, site-deploy role
                   run: manually when IAM changes are needed
                   credentials: SSO with IAM read/write

  <main>/          owns: S3 site buckets, CloudFront, ACM,
                         Route53, KMS site key
                   run: automated via GitHub Actions
                   credentials: terraform-apply role (OIDC)
```

The main workspace has no IAM permissions at all. It cannot modify its own execution role. This eliminates the deadlock and removes a privilege escalation vector - a compromised apply workflow cannot grant itself additional permissions.

The main workspace reads the IAM role ARNs it needs (for documentation and outputs) from the `cicd/` workspace state via a remote state data source, rather than managing the roles directly:

```hcl
data "terraform_remote_state" "cicd" {
  backend = "s3"
  config = {
    bucket     = "brad-duhon-terraform-state"
    key        = "cicd/terraform.tfstate"
    region     = "us-east-1"
    encrypt    = true
    kms_key_id = "alias/brad-duhon-terraform-state"
  }
}

output "site_deploy_role_arn" {
  value = data.terraform_remote_state.cicd.outputs.site_deploy_role_arn
}
```

The `cicd/` workspace policies use project naming conventions instead of exact ARNs from the main workspace state:

```hcl
# S3 site buckets - scoped by naming convention
resources = ["arn:aws:s3:::brad-duhon-site-*"]

# KMS site key - scoped by alias, not key ARN
condition {
  test     = "ForAnyValue:StringLike"
  variable = "kms:ResourceAliases"
  values   = ["alias/brad-duhon-site"]
}
```

This removes the cross-workspace dependency entirely. The `cicd/` workspace does not need to read the main workspace state to write correct IAM policies.

---

## The migration

Moving seven IAM resources (`aws_iam_openid_connect_provider`, three `aws_iam_role`, three `aws_iam_role_policy`) from the main workspace state to the `cicd/` workspace state without modifying or recreating anything in AWS:

```bash
# 1. Initialize the new cicd workspace
cd infrastructure/cicd
terraform init \
  -backend-config=../shared/backend.hcl \
  -backend-config="key=cicd/terraform.tfstate"

# 2. Import existing resources into cicd state (read-only AWS operations)
terraform import aws_iam_openid_connect_provider.github \
  "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
terraform import aws_iam_role.terraform_apply brad-duhon-terraform-apply
terraform import aws_iam_role_policy.terraform_apply \
  brad-duhon-terraform-apply:brad-duhon-terraform-apply
# ... repeat for plan and site-deploy roles

# 3. Verify plan shows no destructive changes, apply policy updates
terraform plan   # review before applying - role destruction means stop
terraform apply

# 4. Remove from main workspace state (state only, not AWS)
cd ../
terraform state rm aws_iam_openid_connect_provider.github
terraform state rm aws_iam_role.terraform_apply
# ... repeat for remaining resources

# 5. Delete cicd.tf from main workspace, verify plan is clean
rm cicd.tf
terraform plan   # must show: No changes
```

The critical constraint on steps 4 and 5: do not run `terraform plan` or `terraform apply` on the main workspace between them. After the `state rm` operations the IAM resources are out of main state but the code in `cicd.tf` still references them. If Terraform ran between steps 4 and 5, it would see resources declared in code with no corresponding state entries and attempt to create new ones - which would fail because they already exist in AWS. Execute 4 and 5 in the same sitting.

---

## What this cost

A one-line change required:
- Six failed apply attempts across multiple days
- Three approaches that required manual credential intervention
- A `skip_refresh` workaround committed to the workflow (and later removed)
- A full workspace refactor and state migration
- Updating IAM policies across both workspaces to remove all self-referential permissions

The immediate cost was time. The larger cost was that `skip_refresh` existed in the workflow at all - an escape hatch that had no reason to exist once the architecture was corrected. It has been removed in the same PR that completed the migration.

If this is familiar, it is because infrastructure incidents often follow this pattern: something small triggers something that should have been fixed at design time but wasn't because the risk was deemed unlikely. The risk is always unlikely right up until it isn't.

---

## The lessons

**A workspace must not manage its own execution roles.** Not a performance concern. Not a best-practice nicety. A correctness constraint. The moment any permission is missing the workspace cannot fix itself without external intervention - and that external intervention is either manual (breaking the CI/CD contract) or a workaround (breaking the infrastructure-as-code contract). Build the `cicd/` workspace first.

**When a working pattern is proposed and dismissed, the burden is on the dismissal.** The correct structure was known, had been used before, and was proposed. It was overruled in favor of simplicity. Every dismissed architectural pattern that resurfaces in an incident report was dismissed for the same reason: it seemed like more work than the risk warranted. It usually is more work. It is also usually less work than the incident.

**`kms:RequestAlias` is the wrong condition for KMS policies in Terraform.** The condition is only set when the API call itself specifies a key by alias. Terraform accesses keys by ARN from state. The condition is therefore never present, and the policy always denies. Use `kms:ResourceAliases` instead - it evaluates based on the key's configured aliases, not how the request was made.

**`dynamodb:DescribeTable` and `kms:ListAliases` do not belong in a Terraform apply role that uses data sources.** Both are eliminated by replacing data sources with computed ARNs. `"arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/project-name"` requires no API call and does not drift as long as the naming convention holds. Fewer permissions is always better.
