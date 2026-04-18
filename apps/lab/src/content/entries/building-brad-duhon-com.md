---
title: "Building brad-duhon.com: design decisions, wrong turns, and the reasoning behind the stack"
date: 2026-04-17
tags: [astro, terraform, aws, security, oidc, tailwind, d3, preact, meta]
description: "A complete walkthrough of building this site in a single session with Claude - infrastructure, accessibility gotchas, the knowledge graph, and an honest accounting of what the AI got wrong."
draft: false
---

This site started as a conversation with Claude and a PDF. The PDF was a project plan I had worked through in advance - two sites, one brand, amber accents, a physics-based knowledge graph for the lab. The conversation was the build. This article is the honest account of what happened between those two things, including Phase 4: the graph you're likely looking at right now.

## The two-site architecture

The plan was always two separate sites sharing one brand:

- **brad-duhon.com** - a living resume. Projects lead, credentials trail. Gets the point across in 30 seconds for a recruiter.
- **lab.brad-duhon.com** - a digital garden. No categories, no rigid structure. Tags do the organizational work. The homepage is a knowledge graph, not a blog index.

Both live in a single monorepo. `apps/main`, `apps/lab`, `packages/shared-ui` for shared Tailwind tokens. Two CloudFront distributions, two S3 buckets, one Route 53 hosted zone.

## React vs Preact

The original plan said "Astro island with D3-force for the knowledge graph" and implied React from the `.tsx` file extensions in the repo structure. Before writing a line of code, I stopped and asked: do I actually need React?

For a single interactive island (the knowledge graph) with no external React component library dependencies, the answer was no. Preact is a drop-in with the same API and ships at roughly 3KB vs React's 45KB. The Astro integration is identical. The only practical difference is that Preact's devtools are less polished than React's - not a concern for a personal site.

The switch cost nothing. The bundle size difference was real.

## Terraform structure evolution

The first pass at infrastructure put everything in flat `.tf` files at the root. Before any code was reviewed, the question came up: why not use the standard `modules/` structure?

The `environments/` pattern didn't apply - there's only one environment (production). But `modules/` was missing and should have been there from the start.

The refactor produced `infrastructure/modules/static-site/` - a reusable module encapsulating S3, CloudFront, OAC, ACM, and Route 53 records for a single site. Called twice at the root level: once for main, once for lab. The duplication that existed in the flat files became two clean module calls with different inputs.

A second structural issue: `iam.tf` was growing. The GitHub OIDC provider, the site deploy role, and two new Terraform CI/CD roles (plan and apply) all belonged together conceptually. The file became `cicd.tf`, with all CI/CD IAM resources in one place.

## The circular dependency

The KMS key policy for site bucket encryption needed to allow CloudFront to decrypt objects. It also needed to allow the deploy role to encrypt on upload.

First attempt: list the deploy role ARN directly in the KMS key policy. Problem: the KMS key is defined before the IAM role in the dependency graph, and the IAM role policy references the KMS key ARN. Terraform can't resolve the circular dependency.

The fix: remove the deploy role from the KMS key policy entirely. The `EnableRootAccess` statement in any KMS key policy allows IAM policies to delegate access through the account root. The deploy role's IAM policy granting `kms:GenerateDataKey` and `kms:Decrypt` on the key ARN is sufficient.

The KMS key policy ended up with two statements: root account access, and CloudFront service principal access scoped by `aws:SourceAccount`. The S3 bucket policy in the module adds the per-distribution `aws:SourceArn` condition as a second layer.

## CI/CD IAM: three roles, three trust boundaries

- **site-deploy** - trusts `ref:refs/heads/main` only. Narrow S3 + CloudFront + KMS permissions scoped to the two site buckets.
- **terraform-plan** - trusts `pull_request` and `ref:refs/heads/main`. Read-only on all managed resource types. Posts plan output as a PR comment.
- **terraform-apply** - trusts `ref:refs/heads/main` only, `workflow_dispatch` trigger. Full write permissions scoped by project name prefix. Requires typing `apply` as a confirmation input.

No long-lived AWS keys stored anywhere. The OIDC trust is the credential.

## Lighthouse and the amber contrast problem

The color palette was designed around warm amber - `#D97706` as the primary accent. It looks right. It passes no accessibility checks as text.

`#D97706` on `#FAFAF9` (warm white) produces a contrast ratio of approximately 2.84:1. WCAG AA requires 4.5:1 for normal text. The fix: use `#92400E` (amber-dark) for all rendered text, keeping amber-primary for decorative elements only. Amber-dark on warm white clears 6.2:1.

A second issue: opacity-based Tailwind utilities like `text-site-text/60` produce a composited color that depends on what's behind the element. At 60% opacity on warm white that came out around 2.5:1. The fix: a dedicated `muted` token (`#5C5754`, 6.5:1) in the shared Tailwind config.

After both fixes: 100 across Performance, Accessibility, Best Practices, and SEO.

## The knowledge graph

This is the piece the whole lab site was designed around.

The graph is generated at build time from content frontmatter. A static endpoint at `/graph.json` reads every non-draft entry via Astro's content collections and produces:

- **Article nodes** - one per entry, with title, date, description, tags, slug
- **Tag nodes** - deduplicated across all entries
- **Tag edges** - article to each of its tags, with a `relevance` score computed by counting occurrences of the tag word in the article's full text (title + description + body). More mentions = higher relevance.
- **Semantic edges** - between articles sharing 2+ tags, with `weight` = shared tag count

The client-side Preact island fetches this JSON on load, runs a D3-force simulation, and renders the result as SVG.

### Node selection: BFS with relevance scoring

Rather than showing every node in the graph at once (which becomes unreadable at scale), the graph shows a curated neighborhood of the current center node. The selection algorithm is a BFS with decaying relevance scores:

- Hop 1 neighbors: `score = edge_strength` (relevance for tag edges, normalized weight for semantic edges)
- Hop 2 neighbors: `score = parent_score * 0.65`
- Hop 3 neighbors: `score = parent_score * 0.65^2`

All reachable nodes within 3 hops are scored and ranked. The top 15 make it into the render. Everything else is pruned. This means the graph always shows the most relevant context for the current center, and scales gracefully as the content library grows.

### Dynamic force scaling

With few nodes the graph would cluster in the center of the canvas without intervention. The simulation forces scale inversely with node count:

```
baseCharge   = -max(220, min(600, 2000 / nodeCount))
baseLinkDist =  90 + min(160, 700 / nodeCount)
```

With 8 nodes: charge ~-250, link distance ~178px. The nodes spread across the full canvas. With 15 nodes: charge ~-133, link distance ~137px. The graph self-compresses to stay legible.

A stable hash of each node's ID introduces deterministic variation in charge and link distance per node, breaking the symmetrical ring pattern that D3's equal-force defaults produce.

### Hover-to-shift

Hovering any non-center node for 600ms makes it the new center. The simulation stops, the neighborhood is recalculated, the center node is pinned to the canvas midpoint with `fx`/`fy`, and the simulation restarts with `alpha = 0.9`. Existing node positions are preserved where possible for a smooth transition.

### Tag sizing by content relevance

When an article is the current center, tag nodes scale in size based on their relevance score to that article - computed from how frequently the tag's words appear in the article's content. A tag that's mentioned repeatedly in the body renders larger than one that appears only in the tag list. When the center changes, the tag sizes update to reflect the new center's relevance profile.

### The node shape redesign

The original design used envelope shapes for articles (folded corner, amber fill) and price tag shapes for tags (notched corners). It looked illustrative - the right word is cartoony.

The redesign: articles become clean rounded rectangles (center node shows title and date on an amber-light background, neighbor articles become small circles with a thin amber ring). Tags become simple pills - no fill by default, auto-sized text, amber border only when center. Edges are thin, low-opacity stone-gray lines. The result is something that looks like a tool rather than a diagram.

### Edge clipping and preview card placement

Two smaller details that matter for polish: edges now terminate at node boundaries rather than connecting center-to-center (requires computing line intersection with rectangle or circle boundary for each endpoint), and the preview card appears adjacent to the clicked node with edge detection to flip left if it would overflow the canvas.

## Behind the build: the numbers

This entire site - Phases 1 through 4 - was built in a single session on 2026-04-17.

**Session context:** Claude Sonnet 4.6, 1M context window. The `/context` command showed approximately 100k tokens consumed across the session, with the message history accounting for roughly 83k of those. The system prompt, tools, and memory files account for the remainder.

**Scope of work in one session:**
- Terraform bootstrap + main infrastructure (S3, CloudFront, ACM, Route 53, IAM OIDC, three CI/CD roles, Terraform plan/apply workflows)
- Astro monorepo with pnpm workspaces and Turborepo
- Main site: full single-scroll layout, real content from resume PDF, Lighthouse 100s
- Lab site: content collections, list view, Pagefind search, RSS feed
- Knowledge graph: BFS scoring, D3-force simulation, custom SVG nodes, hover-to-shift, tag relevance weighting, dynamic force scaling, edge clipping, adjacent preview cards
- Deployed and live on both domains

**Interaction breakdown (approximate):**
- ~110 user messages across the session
- ~35 substantive direction changes or design decisions
- ~20 approvals or rejections of proposed tool calls
- ~12 corrections where the initial approach was wrong
- 1 rejected tool call for a genuinely unsafe flag (`--config.unsafe-perm=true`)

## What Claude got wrong

This is the section most people skip. It's also the most useful one.

**Terraform structure.** The initial infrastructure was flat files with no module abstraction. Standard practice for any project with repeated resource patterns is a `modules/` directory. This should have been the starting point, not a refactor after the fact.

**The `--config.unsafe-perm=true` flag.** When pnpm blocked esbuild and sharp build scripts, the first suggestion was to use `--config.unsafe-perm=true`. This flag runs lifecycle scripts without dropping privileges - it's the wrong answer. The right answer is `onlyBuiltDependencies` in `package.json`, which explicitly allowlists specific packages to run build scripts. The user caught it immediately.

**GitHub Actions step ordering.** `actions/setup-node` with `cache: pnpm` must come *after* `pnpm/action-setup` - you can't cache a tool that hasn't been installed yet. The initial workflows had them in the wrong order. This caused a deploy failure on first push.

**Amber as text color.** The design system used `#D97706` everywhere including as text. This fails WCAG AA contrast requirements at 2.84:1. A security-focused personal site shouldn't ship with accessibility failures. This should have been caught in the design token definition, not discovered via Lighthouse.

**Em dashes in generated content.** The global CLAUDE.md file explicitly prohibits em dashes. They appeared in generated content anyway - in bullet points, descriptions, and comments. Required a bulk find-and-replace pass after the fact. Rules in configuration files apparently don't propagate as reliably to content generation as to code generation.

**The graph node shapes.** The original knowledge graph used envelope shapes for articles and price tag shapes for tags. Both were too stylized. The feedback was accurate: "cartoony." A knowledge graph is a tool for navigating content - it should look like one. The redesign to rounded rectangles and pills is objectively better and took one iteration to get right.

**Preview card positioning.** The initial preview card was `position: absolute; top: 16px; right: 16px` - always in the top-right corner regardless of where the node was clicked. This is fine as a first pass but misses the point of contextual UI. The fix (position adjacent to the clicked node, flip sides on overflow) took one iteration and should have been the initial design.

**SVG centering through the Astro island wrapper.** Astro wraps island components in an `<astro-island>` custom element. When the graph component used `height: 100%` to fill its container, the chain broke because `astro-island` is inline by default and doesn't pass the height through. The fix required explicitly targeting `astro-island` with `position: absolute; inset: 0` in a scoped style. This is an Astro-specific gotcha worth knowing.

## What this site is actually for

Three audiences:

1. **Recruiters** - projects lead, skills follow, experience cards are condensed. Get the picture in 30 seconds.
2. **Security peers** - real writeups, honest gotchas, a knowledge graph worth bookmarking.
3. **Future me** - searchable, connected reference. TILs, architecture decisions, what broke and why.

This article is for all three.
