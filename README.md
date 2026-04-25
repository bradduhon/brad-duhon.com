# brad-duhon.com

Personal portfolio and digital garden. Two Astro sites, one monorepo, AWS-first hosting.

- **brad-duhon.com** - single-scroll portfolio: projects, skills, experience
- **lab.brad-duhon.com** - digital garden with a D3-force knowledge graph

---

## Architecture overview

```
brad-duhon.com/
├── apps/
│   ├── main/               # brad-duhon.com (Astro 4, static)
│   └── lab/                # lab.brad-duhon.com (Astro 5, static + Preact island)
├── packages/
│   └── shared-ui/          # Tailwind config + amber design tokens
├── infrastructure/
│   ├── bootstrap/          # One-time: S3 state bucket + DynamoDB + KMS
│   └── modules/
│       └── static-site/    # Reusable: S3 + CloudFront + OAC + ACM + Route 53
└── .github/workflows/      # deploy-main, deploy-lab, terraform-plan, terraform-apply
```

**Hosting:** S3 (static) + CloudFront (CDN, HTTPS) + Route 53 (DNS) + ACM (TLS)  
**Auth:** GitHub Actions → AWS via OIDC - no long-lived AWS keys stored anywhere  
**IaC:** Terraform with remote state in S3 + DynamoDB locking  
**CI/CD:** Push to `main` triggers deploy. Terraform changes require manual `workflow_dispatch`.

---

## Prerequisites

### On a new Windows machine with WSL2

Everything below runs inside WSL2 (Ubuntu) unless stated otherwise.

#### 1. WSL2

If not already installed, from PowerShell as Administrator:

```powershell
wsl --install
```

Restart when prompted. Default distribution is Ubuntu.

#### 2. Node.js 22

WSL's default apt Node is too old. Install via NodeSource:

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version  # should be v22.x.x
```

#### 3. pnpm

```bash
npm install -g pnpm --prefix ~/.local
# Add to PATH if not already present
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
pnpm --version  # should be 10.x.x
```

#### 4. Git

```bash
sudo apt-get install -y git
git config --global user.name "Your Name"
git config --global user.email "your@email.com"
git config --global pull.rebase true   # avoids divergent branch prompts
```

#### 5. Terraform

Terraform runs from the Windows side. Download the Windows AMD64 binary from
[releases.hashicorp.com/terraform](https://releases.hashicorp.com/terraform/) and extract it.
The version used by this project is pinned in `.terraform-version`:

```
1.14.8
```

From WSL, reference it via the Windows path:

```bash
/mnt/c/Users/<you>/path/to/terraform.exe version
```

To avoid typing the full path every time, add an alias in `~/.bashrc`:

```bash
alias terraform='/mnt/c/Users/<you>/path/to/terraform.exe'
```

Alternatively, install Terraform natively in WSL:

```bash
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform=1.14.8-1
```

#### 6. AWS CLI

```bash
sudo apt-get install -y awscli
aws --version
```

#### 7. git-filter-repo (optional - for scrubbing files from history)

```bash
pip install git-filter-repo
```

---

## AWS account prerequisites

These must exist before running Terraform. They are not created by this repo.

1. **AWS account** with programmatic access credentials
2. **AWS CLI configured** with a profile that has sufficient IAM permissions to create:
   S3, CloudFront, ACM, Route 53, KMS, IAM, DynamoDB resources

Configure the default profile:

```bash
aws configure
# AWS Access Key ID: ...
# AWS Secret Access Key: ...
# Default region name: us-east-1
# Default output format: json
```

Verify access:

```bash
aws sts get-caller-identity
```

---

## First-time setup

### 1. Clone the repository

```bash
git clone https://github.com/bradduhon/brad-duhon.com.git
cd brad-duhon.com
```

### 2. Install dependencies

```bash
pnpm install
```

pnpm will prompt about build scripts for `esbuild` and `sharp`. These are already approved
in `package.json` via `onlyBuiltDependencies` - the install will run them automatically.

---

## Bootstrap Terraform state (one-time, never repeat)

The bootstrap creates the S3 bucket and DynamoDB table that store all other Terraform state.
It uses local state intentionally - these resources are the backend, so they can't store their
own state remotely.

```bash
cd infrastructure/bootstrap
terraform init
terraform apply
```

Review the plan and type `yes`. Note the outputs:

```
state_bucket_name  = "brad-duhon-terraform-state"
dynamodb_table_name = "brad-duhon-terraform-locks"
kms_key_arn        = "arn:aws:kms:us-east-1:ACCOUNT:key/..."
```

These values are already hardcoded in `infrastructure/terraform.tf` backend config.
If your project name differs, update them there before proceeding.

---

## Deploy infrastructure

### 1. Initialize the main Terraform config

```bash
cd infrastructure
terraform init
```

This connects to the remote S3 backend created in bootstrap. If it fails, the bootstrap
state bucket may not exist yet or credentials may be insufficient.

### 2. Plan and apply

```bash
terraform plan
terraform apply
```

Type `yes` when prompted. This creates:
- Route 53 hosted zone
- Two S3 buckets (main + lab sites)
- Two CloudFront distributions with OAC
- Two ACM certificates (DNS-validated)
- Three IAM roles (site-deploy, terraform-plan, terraform-apply)
- GitHub Actions OIDC provider

**Important:** `terraform apply` will block on ACM certificate validation. It waits up to
75 minutes for DNS validation to succeed. DNS validation requires the NS records to be
delegated at your registrar first (see next section). If apply times out, complete NS
delegation then re-run `terraform apply`.

### 3. Note the outputs

```bash
terraform output
```

Save these values - you will need them for DNS delegation and GitHub secrets:

| Output | Used for |
|--------|----------|
| `route53_nameservers` | DNS delegation at registrar |
| `site_deploy_role_arn` | GitHub secret: `AWS_ROLE_ARN` |
| `terraform_plan_role_arn` | GitHub secret: `TF_PLAN_ROLE_ARN` |
| `terraform_apply_role_arn` | GitHub secret: `TF_APPLY_ROLE_ARN` |
| `main_site_bucket` | GitHub secret: `MAIN_SITE_BUCKET` |
| `lab_site_bucket` | GitHub secret: `LAB_SITE_BUCKET` |
| `main_cloudfront_id` | GitHub secret: `MAIN_CLOUDFRONT_ID` |
| `lab_cloudfront_id` | GitHub secret: `LAB_CLOUDFRONT_ID` |

---

## DNS delegation

1. Log in to your domain registrar (wherever `brad-duhon.com` is registered)
2. Find the NS records for the domain
3. Replace all existing NS records with the four values from `route53_nameservers` output
4. Save

Propagation is typically fast (minutes) with most registrars but can take up to 48 hours.

Verify delegation:

```bash
dig brad-duhon.com NS +short
# Should return the four Route 53 nameservers
```

ACM will automatically validate the certificates once DNS resolves through Route 53.

---

## GitHub repository setup

### 1. Create the repository

If the repo doesn't exist yet on GitHub, create it and push:

```bash
git remote add origin https://github.com/bradduhon/brad-duhon.com.git
git push -u origin main
```

### 2. Set repository secrets

In the GitHub repository: **Settings > Secrets and variables > Actions > New repository secret**

Add each of these secrets using the values from `terraform output`:

| Secret name | Value source |
|-------------|-------------|
| `AWS_ROLE_ARN` | `site_deploy_role_arn` output |
| `MAIN_SITE_BUCKET` | `main_site_bucket` output |
| `LAB_SITE_BUCKET` | `lab_site_bucket` output |
| `MAIN_CLOUDFRONT_ID` | `main_cloudfront_id` output |
| `LAB_CLOUDFRONT_ID` | `lab_cloudfront_id` output |
| `TF_PLAN_ROLE_ARN` | `terraform_plan_role_arn` output |
| `TF_APPLY_ROLE_ARN` | `terraform_apply_role_arn` output |

### 3. Verify security headers

Before proceeding, both domains must score A+ at:

- https://securityheaders.com/?q=brad-duhon.com
- https://securityheaders.com/?q=lab.brad-duhon.com

This is the Phase 1 gate. CloudFront response headers are applied to all responses including
error pages, so even empty buckets will show headers. If either domain fails, check the
CloudFront response headers policy in `infrastructure/cloudfront_shared.tf`.

---

## Local development

### Run the main site

```bash
pnpm dev:main
```

The dev server binds to all interfaces (`--host` is baked into the script). The output will
show a network URL - use that from your Windows browser. `localhost` may not resolve
correctly from WSL2 depending on your Windows version and WSL networking configuration.

If the terminal shows no URL after 15 seconds, check which port is listening:

```bash
ss -tlnp | grep "432[0-9]"
```

Then open `http://<WSL-IP>:<port>` in your browser. Find the WSL IP:

```bash
ip addr show eth0 | grep "inet " | awk '{print $2}' | cut -d/ -f1
```

### Run the lab site

```bash
pnpm dev:lab
```

Same networking behavior as above. The lab site requires a production build for Pagefind
search to work - search will not function in dev mode.

### Build for production

```bash
# Main site only
pnpm build:main

# Lab site only (includes Pagefind indexing)
pnpm --filter @brad-duhon/lab build

# Both (via Turborepo)
pnpm build
```

### Preview production build locally

```bash
cd apps/main && pnpm preview --host
# or
cd apps/lab && pnpm preview --host
```

### Run Lighthouse

Build and preview first, then in Chrome:

1. Open the preview URL
2. DevTools (`F12`) > Lighthouse tab
3. Mode: Navigation, Device: Desktop
4. Analyze page load

Required scores before merging any content or layout changes:
- Performance: 95+
- Accessibility: 100
- Best Practices: 100
- SEO: 100

---

## Adding lab content

### Using the VS Code snippet

In any markdown file under `apps/lab/src/content/entries/`, type `entry` and press Tab.
The snippet expands to:

```markdown
---
title: ""
date: YYYY-MM-DD    # auto-stamped with today's date
tags: []
description: ""
draft: true
---
```

Fill in the frontmatter. Write content below the closing `---`. Leave `draft: true` while
writing - entries with `draft: true` are excluded from the built site, the graph, search,
and RSS feed.

When ready to publish, set `draft: false` and push to `main`.

### Frontmatter reference

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `title` | string | yes | Shown in graph center node and list view |
| `date` | YYYY-MM-DD | yes | Used for sorting; most recent is initial graph center |
| `tags` | string[] | yes | No categories - tags do all the organizational work |
| `description` | string | yes | Shown in list cards, preview cards, RSS, OG meta |
| `draft` | boolean | yes | `true` = built but never public |

### Updating "From the Lab" on the main site

The main site's "From the Lab" section (`apps/main/src/components/FromTheLab.astro`) is
manually curated. When you publish a new lab entry worth featuring, update the `entries`
array in that component to reference it.

---

## Deploying changes

### Site content and code

Any push to `main` triggers the relevant deploy workflow:

| Changed path | Workflow triggered |
|---|---|
| `apps/main/**` or `packages/shared-ui/**` | `deploy-main.yml` |
| `apps/lab/**` or `packages/shared-ui/**` | `deploy-lab.yml` |

The workflow: checkout → install pnpm → install Node 22 → build → sync to S3 → invalidate CloudFront. Live in approximately 90 seconds.

### Infrastructure changes

Terraform changes use a separate flow:

**On pull request** (automatic): `terraform-plan.yml` runs `terraform plan` and posts output
as a PR comment. Read it before merging.

**To apply** (manual): Go to GitHub Actions > Terraform - Apply > Run workflow. When
prompted for confirmation, type `apply`. The workflow runs `terraform plan` then
`terraform apply` sequentially.

Never run `terraform apply` from local without first checking that CI has the same view of
state. If local and remote state diverge, `terraform refresh` before applying.

### Scrubbing files from git history

If a file is accidentally committed that shouldn't be in history (credentials, large
binaries, sensitive docs):

```bash
pip install git-filter-repo   # if not already installed

git filter-repo --path <filename> --invert-paths --force

# Re-add origin (filter-repo removes it as a safety measure)
git remote add origin https://github.com/bradduhon/brad-duhon.com.git

git push origin main --force
```

Anyone who cloned the repo before the force push will still have the file in their local
history. For a solo repo this is acceptable.

---

## Troubleshooting

### `pnpm dev:main` spins with no output

The server is running but output isn't being flushed to the terminal. Check if a port is
actually listening:

```bash
ss -tlnp | grep "432[0-9]"
```

If a port shows `*:432X` (bound to all interfaces), the server started correctly. Open that
port in your Windows browser using the WSL network IP.

### ACM certificate stuck validating

The certificate validation CNAME records are in Route 53, but Route 53 isn't authoritative
for the domain yet. Check NS delegation:

```bash
dig brad-duhon.com NS +short
```

If this returns your registrar's NS records (not Route 53's), delegation isn't complete.
Update NS records at your registrar and wait for propagation.

### `terraform init` fails with backend error

The state bucket from bootstrap doesn't exist or credentials lack access to it. Verify:

```bash
aws s3 ls s3://brad-duhon-terraform-state
aws sts get-caller-identity
```

### GitHub Actions: `Unable to locate executable file: pnpm`

The `pnpm/action-setup` step must run before `actions/setup-node` when using `cache: pnpm`.
Check that the step order in the workflow file matches:

```yaml
- uses: pnpm/action-setup@v4   # FIRST
- uses: actions/setup-node@v4   # SECOND (with cache: pnpm)
```

### OIDC authentication fails in GitHub Actions

Verify:
1. The `id-token: write` permission is set in the workflow
2. The IAM role trust policy references the correct GitHub org/repo/branch
3. The role ARN in the GitHub secret matches what Terraform created

```bash
terraform output site_deploy_role_arn
```

---

## Design system reference

| Token | Color | Hex | Usage |
|-------|-------|-----|-------|
| `amber-primary` | Warm Amber | `#D97706` | Borders, backgrounds, decorative accents |
| `amber-dark` | Amber Dark | `#92400E` | All rendered text using amber |
| `amber-light` | Amber Light | `#FEF3C7` | Callouts, tag backgrounds |
| `site-bg` | Warm White | `#FAFAF9` | Page background |
| `site-text` | Warm Gray | `#44403C` | Body text |
| `site-heading` | Near Black | `#1C1917` | Headings |
| `site-muted` | Stone | `#5C5754` | Secondary text (replaces opacity variants) |

**Rule:** `amber-primary` must never be used as text color - it fails WCAG AA at 2.84:1
contrast on the warm white background. Use `amber-dark` for any amber text.

**No em dashes** anywhere in content or comments. Use a regular hyphen instead.

**No Google Fonts.** System font stack only.
