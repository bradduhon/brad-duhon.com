---
title: "Bootstrapping my dev environment in WSL2 Ubuntu (WebDev)"
date: 2026-04-18
tags: [wsl, ubuntu, shell, devtools, terraform, aws, claude-code, github-actions, astro, security]
description: "End-to-end walkthrough of setting up a full dev environment inside WSL2 - from bare shell through ZSH, Claude Code, Git, Terraform, AWS credentials, and deploying brad-duhon.com as an Astro monorepo on AWS."
draft: false
---

This documents the full setup sequence for a professional development environment inside WSL2 Ubuntu, starting from a bare shell. It covers shell customization, Claude Code, Git and GitHub CLI, Terraform, AWS credential management, and the infrastructure bootstrap and deploy pipeline for this site.

The work happened in several distinct phases:

1. Shell environment (ZSH + oh-my-zsh)
2. System dependencies
3. Claude Code installation
4. Claude Code configuration and rules
5. Git global config and GitHub CLI
6. Version-controlling the `.claude` configuration
7. Toolchain additions (Terraform, Node.js, markdownlint)
8. AWS credential export for Terraform bootstrap
9. Infrastructure bootstrap
10. GitHub secrets for CI/CD
11. Astro monorepo build and deploy

---

## Phase 1 - Shell Environment (ZSH + oh-my-zsh)

The first thing to do on a fresh WSL Ubuntu install is replace `bash` with ZSH and layer oh-my-zsh on top for productivity. Syntax highlighting, git-aware prompts, plugin support, and tab completion that bash can't match for daily work.

**Install ZSH:**

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install zsh -y
```

**Install oh-my-zsh:**

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
```

**Set ZSH as the default shell:**

```bash
chsh -s $(which zsh)
```

> After running `chsh`, close and reopen your WSL terminal for the change to take effect. From this point forward, all shell configuration lives in `~/.zshrc`.

---

## Phase 2 - System Dependencies

**Install build dependencies:**

```bash
sudo apt update
sudo apt install -y make build-essential libssl-dev zlib1g-dev \
libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev
```

---

## Phase 3 - Claude Code Installation

Claude Code is Anthropic's agentic coding CLI. It runs in the terminal and can read, write, and reason about code in your project with full filesystem context. The install is a single curl command, but in a WSL environment there can be path and shell sourcing quirks that require a reload after install.

**Install Claude Code:**

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

> If `claude` is not found immediately after install, the installer added it to your PATH in `~/.zshrc` but the current session hasn't picked it up yet.

**Reload your shell and verify:**

```bash
source ~/.zshrc
which claude
claude
```

---

## Phase 4 - Claude Code Configuration and Rules

Out of the box, Claude Code works, but its real power comes from custom rules - markdown files in `~/.claude/rules/` that provide persistent behavioral context: code standards, IAM review checklists, Git workflow expectations, WSL-specific notes, and more. These are global rules that apply across all projects.

Because this WSL environment is a secondary machine (the primary `.claude` config lives on the Windows side), the existing config was copied from the Windows profile into the WSL home directory rather than starting from scratch.

**Copy existing `.claude` config from Windows profile into WSL:**

```bash
cp -r /mnt/c/Users/bradd/.claude /home/bduhon
```

**Inspect the directory layout:**

```bash
tree ~/.claude
```

**Create and manage rule files:**

```bash
# IAM review checklist
vim ~/.claude/rules/iam-review.md

# Copyright / licensing reminder
vim ~/.claude/rules/copywrite.md

# Code review standards
vim ~/.claude/rules/code-review.md

# WSL-specific bridge notes (Windows paths, interop behavior, etc.)
vim ~/.claude/rules/wsl-bridge.md
```

**Housekeeping - rename and remove rules:**

```bash
# Remove redundant Windows-specific rule now covered by wsl-bridge.md
rm ~/.claude/rules/windows.md

# Normalize filenames
mv ~/.claude/rules/git-workflow.md ~/.claude/rules/git.md
mv ~/.claude/rules/code-quality.md ~/.claude/rules/engineering.md
```

**Move a project-local rule from global to repo-local:**

```bash
mv ~/.claude/rules/code-review.md .claude/rules/
```

**Verify configuration:**

```bash
claude config list
claude mcp list
```

---

## Phase 5 - Git Global Config and GitHub CLI

Before committing anything, Git needs a global identity. The GitHub CLI (`gh`) enables authenticated GitHub operations - repo creation, secret management, auth status - without managing personal access tokens manually.

**Configure Git identity:**

```bash
git config --global user.name "Brad Duhon"
git config --global user.email "your@email.com"
```

**Install GitHub CLI (`gh`):**

```bash
sudo apt update && sudo apt install curl gpg -y
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null

sudo apt update && sudo apt install gh -y
```

**Authenticate:**

```bash
gh auth login
gh auth status
```

---

## Phase 6 - Version-Control the `.claude` Configuration

Claude Code rules and config are valuable - they encode your workflow, standards, and context preferences. Versioning `~/.claude` in GitHub means it's portable, recoverable, and auditable. A `.gitignore` was set up first to ensure no credentials, tokens, or sensitive auth files are accidentally committed.

**Initialize the repo:**

```bash
cd ~/.claude
git init
git branch -M main
```

**Create a security-conscious `.gitignore`:**

```bash
cat > ~/.claude/.gitignore << 'EOF'
# Credentials and secrets
*credentials*
*secret*
*token*
*.key
*.pem
*.env
.env*

# Any JSON that might be auth-related
*auth*.json
*service-account*.json

# OS noise
.DS_Store
Thumbs.db
EOF
```

**Add the GitHub remote and sync:**

```bash
git remote add origin https://github.com/<your-username>/.claude.git
git branch --set-upstream-to=origin/main main
git pull --rebase origin main
```

---

## Phase 7 - Toolchain: Terraform, Node.js, markdownlint

Three additions: Terraform for infrastructure-as-code, Node.js for the Astro site build, and `markdownlint-cli` to enforce markdown quality in documentation and Claude rules.

**Install Terraform (HashiCorp apt source):**

```bash
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common curl

curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt-get update && sudo apt-get install terraform
```

**Install Node.js 22.x via NodeSource (avoids the outdated apt default):**

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version
```

**Install pnpm (used by the Astro monorepo):**

```bash
sudo npm install -g pnpm
```

**Install markdownlint-cli:**

```bash
sudo npm install -g markdownlint-cli
markdownlint --version
```

---

## Phase 8 - AWS Credentials for Terraform Bootstrap

To run `terraform init && terraform apply` against AWS, temporary credentials were exported into the shell session. These are short-lived STS-issued credentials (note the `AWS_SESSION_TOKEN`), appropriate for one-time bootstrap operations.

**Export temporary STS credentials into your shell session:**

```bash
export AWS_ACCESS_KEY_ID="ASIA********************"
export AWS_SECRET_ACCESS_KEY="************************************"
export AWS_SESSION_TOKEN="<STS session token>"
```

> **Security note:** These are temporary STS credentials with a built-in expiry. For recurring use, prefer AWS SSO / IAM Identity Center with `aws sso login` rather than exporting static or session credentials into your shell history. Consider adding `export AWS_*` patterns to your shell history exclusions (`HISTIGNORE` in ZSH). Credentials should never be committed to source control.

---

## Phase 9 - Infrastructure Bootstrap

With credentials active, Terraform was used to bootstrap the AWS infrastructure backing the site. A two-stage Terraform workflow was run: first a `bootstrap` module (which creates the S3 state backend and initial IAM roles), then the root infrastructure module.

**Clone the site repo:**

```bash
cd MyProjects
git clone https://github.com/<your-username>/brad-duhon.com.git
cd brad-duhon.com
```

**Bootstrap (remote state + IAM roles):**

```bash
cd infrastructure/bootstrap
terraform init && terraform apply
```

**Deploy root infrastructure:**

```bash
cd ../
terraform init && terraform apply
```

---

## Phase 10 - GitHub Secrets for CI/CD

With infrastructure deployed, the GitHub Actions deployment pipeline needed access to AWS IAM roles and resource identifiers without embedding them in the codebase. The `gh secret set` command pushes each value directly from the CLI into the repo's GitHub Actions secrets.

```bash
# IAM roles for Terraform plan and apply (OIDC trust)
gh secret set TF_PLAN_ROLE_ARN \
  --body "arn:aws:iam::<ACCOUNT_ID>:role/<project>-terraform-plan" \
  --repo <username>/<repo>

gh secret set TF_APPLY_ROLE_ARN \
  --body "arn:aws:iam::<ACCOUNT_ID>:role/<project>-terraform-apply" \
  --repo <username>/<repo>

# Site deployment role
gh secret set AWS_ROLE_ARN \
  --body "arn:aws:iam::<ACCOUNT_ID>:role/<project>-site-deploy" \
  --repo <username>/<repo>

# CloudFront distribution IDs
gh secret set LAB_CLOUDFRONT_ID \
  --body "<lab-distribution-id>" \
  --repo <username>/<repo>

gh secret set MAIN_CLOUDFRONT_ID \
  --body "<main-distribution-id>" \
  --repo <username>/<repo>

# S3 site buckets
gh secret set LAB_SITE_BUCKET \
  --body "<project>-site-lab" \
  --repo <username>/<repo>

gh secret set MAIN_SITE_BUCKET \
  --body "<project>-site-main" \
  --repo <username>/<repo>
```

---

## Phase 11 - Astro Monorepo Build and Deploy

The site is an Astro-based monorepo managed with pnpm workspaces. Two apps: `main` (the primary portfolio) and `lab` (content collections with Pagefind search). The build was tested locally before being pushed through the GitHub Actions pipeline.

A sensitive file (`brad-duhon-site-plan-v3.pdf`) was accidentally committed and had to be removed from Git history entirely using `git-filter-repo` before pushing.

**Local development and preview:**

```bash
pnpm dev:main
pnpm build:main && pnpm --filter @brad-duhon/main preview -- --host

# Lab app
cd apps/lab && pnpm dev
```

**Remove accidentally committed sensitive file from history:**

```bash
pip install git-filter-repo
git filter-repo --path brad-duhon-site-plan-v3.pdf --invert-paths

# Re-add remote (filter-repo removes it) and force push
git remote add origin https://github.com/<username>/<repo>.git
git push origin main --force
```

> **Security note:** `git filter-repo` rewrites history. After a force push, anyone with a clone of the repo should re-clone. If the file contained sensitive information, treat it as potentially exposed for the window between the original push and the force push - assess whether any secrets need rotation.

---

## ZSH maintenance

During setup, stale ZSH completion cache files caused warnings. These can be safely removed:

```bash
rm ~/.zcompdump-<hostname>-<version>.zwc
rm ~/.zcompdump-<hostname>-<version>
exec zsh
```

---

## Tools installed

| Tool | Install method | Purpose |
| --- | --- | --- |
| ZSH | apt | Default shell |
| oh-my-zsh | curl installer | Shell framework |
| Claude Code | claude.ai installer | Agentic coding CLI |
| GitHub CLI (`gh`) | apt (GitHub source) | GitHub auth + secrets |
| Terraform | apt (HashiCorp source) | Infrastructure as Code |
| Node.js 22.x | NodeSource | JS runtime for Astro |
| pnpm | npm global | Monorepo package manager |
| markdownlint-cli | npm global | Markdown linting |
| tree | apt | Directory visualization |
| git-filter-repo | pip | Git history rewriting |
| aws-lambda-powertools | pip | Lambda utilities |
