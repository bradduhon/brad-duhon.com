---
title: "Building brad-duhon.com: design decisions, wrong turns, and the reasoning behind the stack"
date: 2026-04-17
tags: [astro, terraform, aws, security, oidc, tailwind, meta]
description: "A walkthrough of the decisions, pivots, and gotchas that went into building this site - from infrastructure to accessibility to why we ended up with Preact instead of React."
draft: false
---

This site started as a conversation with Claude and a PDF. The PDF was a project plan I had worked through in advance - two sites, one brand, amber accents, a physics-based knowledge graph for the lab. The conversation was the build. This article is the honest account of what happened between those two things.

## The two-site architecture

The plan was always two separate sites sharing one brand:

- **brad-duhon.com** - a living resume. Projects lead, credentials trail. Gets the point across in 30 seconds for a recruiter.
- **lab.brad-duhon.com** - a digital garden. No categories, no rigid structure. Tags do the organizational work. The homepage is a knowledge graph, not a blog index.

Both live in a single monorepo. `apps/main`, `apps/lab`, `packages/shared-ui` for shared Tailwind tokens. Two CloudFront distributions, two S3 buckets, one Route 53 hosted zone.

## React vs Preact

The original plan said "Astro island with D3-force for the knowledge graph" and implied React from the `.tsx` file extensions in the repo structure. Before writing a line of code, I stopped and asked: do I actually need React?

For a single interactive island (the knowledge graph) with no external React component library dependencies, the answer was no. Preact is a drop-in with the same API and ships at roughly 3KB vs React's 45KB. The Astro integration is identical. The only practical difference is that Preact's devtools are less polished than React's - not a concern for a personal site.

Preact also ships `@preact/signals` for fine-grained reactivity. For the graph, where hover state, center node, and preview card visibility all need to update specific SVG nodes without re-rendering the whole canvas, signals are the right primitive.

The switch cost nothing. The bundle size difference was real.

## Terraform structure evolution

The first pass at infrastructure put everything in flat `.tf` files at the root. Before any code was reviewed, the question came up: why not use the standard `modules/` structure?

The `environments/` pattern didn't apply - there's only one environment (production). But `modules/` was missing and should have been there from the start.

The refactor produced `infrastructure/modules/static-site/` - a reusable module encapsulating S3, CloudFront, OAC, ACM, and Route 53 records for a single site. Called twice at the root level: once for main, once for lab. The duplication that existed in the flat files became two clean module calls with different inputs.

A second structural issue: `iam.tf` was growing. The GitHub OIDC provider, the site deploy role, and two new Terraform CI/CD roles (plan and apply) all belonged together conceptually but were spread across files by accident. The file became `cicd.tf`, with all CI/CD IAM resources in one place.

## The circular dependency

The KMS key policy for site bucket encryption needed to allow CloudFront to decrypt objects. It also needed to allow the deploy role to encrypt on upload.

First attempt: list the deploy role ARN directly in the KMS key policy. Problem: the KMS key is defined before the IAM role in the dependency graph, and the IAM role policy references the KMS key ARN. Terraform can't resolve the circular dependency.

The fix: remove the deploy role from the KMS key policy entirely. The `EnableRootAccess` statement in any KMS key policy allows IAM policies to delegate access through the account root. The deploy role's IAM policy granting `kms:GenerateDataKey` and `kms:Decrypt` on the key ARN is sufficient - it works through the root account statement without needing the role explicitly named in the key policy.

The KMS key policy ended up with two statements: root account access, and CloudFront service principal access scoped by `aws:SourceAccount`. The S3 bucket policy in the module adds the per-distribution `aws:SourceArn` condition as a second layer.

## CI/CD IAM: three roles, three trust boundaries

The deploy setup ended up with three distinct IAM roles, each with a different OIDC trust scope:

- **site-deploy** - trusts `ref:refs/heads/main` only. Fires on push to main when app code changes. Narrow S3 + CloudFront + KMS permissions scoped to the two site buckets.
- **terraform-plan** - trusts `pull_request` and `ref:refs/heads/main`. Read-only on all managed resource types plus state backend lock access. Used by PR checks to post plan output as a comment.
- **terraform-apply** - trusts `ref:refs/heads/main` only, `workflow_dispatch` trigger. Full write permissions on all managed resource types, scoped by project name prefix where possible.

The apply workflow requires typing `apply` as a confirmation input before it runs. There's a commented-out `environment:` block for GitHub Environments with required reviewers if that gate is needed later.

No long-lived AWS keys stored anywhere. The OIDC trust is the credential.

## Lighthouse and the amber contrast problem

The color palette was designed around warm amber - `#D97706` as the primary accent. It looks right. It passes no accessibility checks as text.

`#D97706` on `#FAFAF9` (warm white) produces a contrast ratio of approximately 2.84:1. WCAG AA requires 4.5:1 for normal text. The amber primary was used as text in several places: company names in the experience section, the GitHub link on project cards, the lab nav button, the 404 page labels.

The fix was to use `#92400E` (amber-dark) for all rendered text, keeping `#D97706` for decorative elements - borders, backgrounds, hover states. Amber-dark on warm white clears 6.2:1.

A second issue: opacity-based Tailwind utilities like `text-site-text/60` don't produce a fixed color - they produce a color that depends on what's behind the element. Lighthouse evaluates the composited color, which at 60% opacity on warm white came out around 2.5:1. The fix was a dedicated `muted` token (`#5C5754`, 6.5:1 on warm white) in the shared Tailwind config, replacing all opacity-based text utilities.

After both fixes: 100 across Performance, Accessibility, Best Practices, and SEO.

## The knowledge graph

Not built yet. Phase 4.

The plan is D3-force for physics layout, custom SVG for the envelope (article) and price tag (tag) node shapes, and a hover-to-shift interaction where hovering any non-center node for 600ms makes it the new center and the graph reorganizes around it. The graph is generated at build time from content frontmatter - you write a post, add tags, push. No manual configuration.

The list view you're reading this on is the Phase 3 fallback. It becomes the toggle target in Phase 4.

## What this site is actually for

Three audiences:

1. **Recruiters** - projects lead, skills follow, experience cards are condensed. Get the picture in 30 seconds.
2. **Security peers** - real writeups, honest gotchas, a knowledge graph worth bookmarking.
3. **Future me** - searchable, connected reference. TILs, architecture decisions, what broke and why.

This article is for all three.
