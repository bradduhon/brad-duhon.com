---
title: "Engram: A 3-Day Build Narrative"
date: 2026-05-10
tags: [aws, lambda, mcp, bedrock, mtls, python, ai, terraform]
description: "How I built a personal memory layer for Claude Code in a weekend - the architecture decisions, the wrong turns, and what the collaboration actually looked like."
draft: false
---

Claude Code has no memory between sessions. Preferences, architectural decisions, project context, debugging history - all of it evaporates when the context window closes. Compaction makes it worse: the model prunes its own context without any durable record of what was decided.

I wanted to fix that for my own workflow. The goal was a personal memory layer: store something once, recall it by meaning - not keyword - in any future session, in any project. The constraint was that I wanted it on my own infrastructure. No third-party data egress. No API keys I don't control.

The result is [Engram](https://github.com/bradduhon/engram). Three days, Friday evening through Sunday. This is the honest account.

## The Architecture

The stack: Python 3.12 Lambda, S3 Vectors for semantic search, Bedrock Titan Embed v2 for embeddings, API Gateway with mTLS, Terraform throughout. The MCP server runs locally as a Claude Code child process and talks to the API over mTLS HTTPS.

A few decisions that shaped everything downstream:

**Serverless, not persistent.** Memory operations are infrequent. A persistent server costs money around the clock for a personal tool. Cold starts are acceptable at session boundaries.

**S3 Vectors, not Pinecone or OpenSearch.** AWS-native, no third-party data egress. Vectors stay in the same account. The downside: the Terraform provider only supported S3 Vectors in `~> 6.0`. The project started on `~> 5.0` and had to upgrade mid-session.

**mTLS, not API keys or IAM.** The TLS handshake rejects unauthorized callers before any HTTP is established. An unauthenticated `curl` returns `000` - connection reset - not `403`. That is stronger than a status code. The local private key is age-encrypted on disk; plaintext exists only in a kernel pipe buffer via process substitution, never as a named file.

**Lambda in VPC with no internet.** S3 Vectors, Bedrock, and Secrets Manager all accessed over VPC endpoints. The bucket policy denies any request not sourced from the S3 Gateway Endpoint. Correct in design. The painful part: missing VPC endpoints are silent timeouts, not clear errors.

## Day 1 - Friday

Opus 4.6 did the design pass. Eight phase documents, project conventions in `CLAUDE.md`, scaffolding. Around 4,500 lines of spec across 13 files. Nothing deployed yet. The explicit intent was Opus for design, Sonnet for implementation. That handoff worked exactly as intended.

## Day 2 - Saturday

About 10 hours of active build. This is where it got interesting.

The first real obstacle was the provider version. No `aws_s3vectors_*` resources in `~> 5.0`. Upgraded, continued. The first architecture error surfaced immediately after: the vector index was created with 1536 dimensions, copied from OpenAI's number. Titan Embed v2 supports 256, 512, and 1024 only. The index had to be destroyed and recreated before the first Lambda invocation.

Certificate work took from 02:40 to 04:30. The model kept adding Route53 record creation to the Terraform module. My pushback: "What are you talking about... think larger, others who adopt this may have ANY type of account and hosted zone setup." DNS records removed. That same Route53 assumption resurfaced four separate times across context window boundaries. Each time, I corrected it in conversation. None of those corrections made it back into the spec - which is exactly why it kept coming back.

Lambda phase had five distinct failures in sequence:

1. Vendor script evolved to `null_resource` with `local-exec` evolved to a managed Powertools layer. I asked "why do we need a script?" twice. Eventually the answer was "we don't."
2. Relative imports (`from .config import Config`) would fail in Lambda without package context. Fixed to absolute.
3. `PutFunctionConcurrency` failed - personal account below minimum unreserved concurrency. Reserved concurrency removed.
4. AWS CLI v2 treats `--payload` as base64 by default. Four failed smoke test attempts before `--cli-binary-format raw-in-base64-out` surfaced.
5. First actual invocation: `bucketName` vs `vectorBucketName` typo in the handler.

S3 Vectors had no VPC endpoint configured. Timeout. Endpoint added. Still timing out - the S3 Vectors endpoint domain is `s3vectors.us-east-1.api.aws`, not the standard `amazonaws.com` pattern. boto3's bundled botocore didn't know the service. Fix: explicit endpoint URL via environment variable.

mTLS debugging ran from around 16:00 to 23:00. Three rounds of truststore failure:

- Round 1: truststore = leaf cert only. API Gateway: "couldn't build a unique path to a root certificate."
- Round 2: truststore = chain from ACM export, including cross-signed Amazon Root CA 1. Still failed.
- Round 3: truststore = Amazon RSA 2048 M04 intermediate + self-signed Amazon Root CA 1, fetched directly from Amazon Trust Services. Worked.

Two other issues surfaced during the same window. Lambda couldn't reach Secrets Manager for cert pinning - missing VPC Interface Endpoint, silent timeout. And the handler was reading the client cert from the wrong location: payload format 2.0 puts it in `requestContext.authentication.clientCert.clientCertPem`, not the `x-amzn-mtls-clientcert` header (that is format 1.0 behavior, and it is not prominent in the docs).

Near midnight: the summarize endpoint. Zero-vector ANN query to fetch all memories for summarization - S3 Vectors rejected it. Fix: `list_vectors` API. Then the Haiku model ID was wrong, which required a cross-region inference profile, which required a Bedrock control plane VPC endpoint, which required IAM changes for both the inference profile ARN and the foundation model ARN. Four distinct failures, each one exposing the next.

The MCP config was in the wrong file. The setup instructions said `~/.claude/mcp_servers.json`. Claude Code reads `~/.claude.json`. Tools were silently absent until I noticed.

Day 2 ended with a working system. `store`, `recall`, and `summarize` all functional over mTLS. 62 unit tests passing.

## Day 3 - Sunday

Cleanup and a nasty packaging bug.

`Engram.md` was created as the behavior spec - defining when Claude calls each tool automatically without prompting. First draft was too wordy. My note: "reduce the token cost." Second draft was around 364 words with a field reference table and explicit triggers. That is the version that shipped.

The significant bug: engram-memory loaded correctly in the engram project but not in any other project. Two problems in `pyproject.toml`:

1. Invalid build backend: `setuptools.backends._legacy` - nonexistent.
2. No package discovery config: setuptools auto-detected the `src/` layout and only added `src/` to the editable install's `.pth` file. `mcp_server/` at the repo root was never on `sys.path` outside the engram directory.

The `cwd` field in `~/.claude.json` masked both problems in the engram project. In every other project, the server failed silently.

Fix: build backend corrected, `[tool.setuptools.packages.find] where = [".", "src"]` added, `cwd` removed from `~/.claude.json`. Both bugs would have been caught by a single `pip install -e` test run from outside the repo. That is now in the setup docs.

## What Worked

The Opus-for-design, Sonnet-for-implementation model hierarchy. Phase documents gave Sonnet a contract. Decisions made upfront did not have to be re-litigated during implementation.

The age encryption with process substitution worked exactly as designed. Plaintext private key never touched disk as a named file.

IaC discipline stayed clean throughout. Every fix went through `terraform apply`. State never diverged.

The mTLS is genuinely two-layer. API Gateway validates the client cert chain against the truststore. Lambda compares the presented leaf cert byte-for-byte against the specific ACM cert stored in Secrets Manager. Two independent validation layers. An unauthenticated request returns `000`, not `403`.

## What Didn't

The 1536-dimension vector index was the first real mistake - caught quickly, but it required a destroy and recreate.

The Route53 assumption resurfaced four times because the correction lived only in conversation, not in the spec. That pattern is the main lesson from this build: anything corrected verbally and not written back into a reference document will resurface at the next context boundary.

The mTLS truststore took three iterations. The original spec said leaf-cert only. That was wrong, and the spec was not updated to reflect it.

The missing VPC endpoints were the most time-consuming debugging surface. Silent timeouts with no clear error. The right approach is to plan endpoint coverage upfront - every AWS service the Lambda touches requires a VPC endpoint.

## The Collaboration Dynamic

Terse feedback from me was signal-dense. "1", "sure", "yes" meant correct, proceed. "Why are you..." meant stop and reconsider from the top. That pattern worked.

Where the model over-engineered: vendor scripts that became `null_resource` that became managed layers, CN validation that was redundant with cert pinning and got reintroduced across a context boundary, and a first draft of `Engram.md` that was twice as long as it needed to be.

Where it self-corrected without prompting: all three mTLS truststore iterations, the `requestContext` vs header location, the Bedrock inference profile chain of failures. Each layer diagnosed as the error surfaced.

The cert rotator redesign is the clearest example of the collaboration working. I asked Claude to explain the purpose of a specific function. It did. Then I said: "you say it triggers when the expiration date is close but it has no understanding of when the certificate was renewed." Claude redesigned it. I said "Sure." That exchange took maybe three minutes.

The context window is still the fundamental limit. The main build session ran across multiple compactions. Every compaction summary had to re-establish: Route53 is in another account, leaf-cert truststore was abandoned, `expected_client_cn` was removed. The system works despite context limits. Engram is, in part, an attempt to address that.

## Lessons

**S3 Vectors may need an explicit endpoint URL env var.** boto3's bundled botocore may not know `s3vectors.<region>.api.aws`.

**API Gateway mTLS with payload format 2.0 puts the client cert in `requestContext`, not a header.** The docs bury this.

**Cross-region Bedrock inference profiles require:** Bedrock control plane VPC endpoint + `bedrock:GetInferenceProfile` IAM + both the inference profile ARN and the foundation model ARN in the policy. Each of those is a separate failure.

**Missing VPC endpoints are silent timeouts.** Plan endpoint coverage upfront.

**Test `pip install -e` from outside the repo** before declaring an MCP server globally available.

**Omit `cwd` from MCP config.** Rely on the editable install. `cwd` masks import failures and causes per-project behavior differences.

**Corrections made only in conversation will not survive context window boundaries.** Write them into the spec.
