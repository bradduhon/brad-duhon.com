# Lab Entry Generator

Generate a new lab entry. Uses the author's voice profile if one exists. Prompts for a title and source material (inline description or a path to a markdown file), then writes the entry and opens it.

## Instructions

### Step 1: Load voice profile

Check if `.claude/voice-profile.md` exists.

- If it exists: read it. The "Writing directive" section is the primary persona instruction. Hold it in context for the entire generation step.
- If it does not exist: note to the user that no voice profile was found and generation will proceed without one. Suggest they run `/lab-profile` first to get a personalized result.

---

### Step 2: Gather inputs

Ask the user for the following. Collect both before proceeding:

1. **Title** -- the working title for the entry. This will be used to derive the slug.
2. **Source material** -- one of:
   - A free-text description, outline, or brain dump of what the article should cover
   - A file path to a markdown document that contains notes, a draft, or structured content to build from

If the user provides a file path, read the file before proceeding.

---

### Step 3: Generate the entry

Using the title, source material, and voice profile (if present), write the full article body.

Rules:
- Do not use em dashes anywhere in the output. Use a regular hyphen (-) instead.
- Do not use Google Fonts references or inline style imports.
- Do not hardcode any email addresses. If contact info is needed, omit it.
- `draft: true` must be set in frontmatter -- the author decides when to publish.
- Tags should be inferred from the content. Use lowercase, hyphen-separated slugs (e.g., `aws-iam`, `terraform`). Aim for 4-8 relevant tags.
- The description should be one sentence, under 200 characters, written in the author's voice.
- Date should be today's date in `YYYY-MM-DD` format.
- Do not add a copyright header to `.md` content files -- only code files get those.
- Write the body in the author's voice. If a voice profile exists, the "Writing directive" is the law. If not, default to clear, direct, first-person technical prose.

Frontmatter format:
```
---
title: "<title>"
date: <YYYY-MM-DD>
tags: [<tags>]
description: "<one-sentence description>"
draft: true
---
```

---

### Step 4: Derive slug and write file

Derive the slug from the title:
- Lowercase
- Replace spaces and special characters with hyphens
- Strip leading/trailing hyphens
- Example: "Post-mortem: The IAM Disaster" -> `postmortem-the-iam-disaster`

Write the file to:
```
apps/lab/src/content/entries/<slug>.md
```

Confirm the file path to the user after writing.

---

### Step 5: Open the file

Open the file in the editor so the user can review and refine it immediately.

---

## Adaptation note for other projects

To use this skill in a different project:
- Change the output path (currently `apps/lab/src/content/entries/`) to wherever your content lives.
- Change the frontmatter schema if your content collection uses different fields -- match it to your `config.ts` or equivalent schema definition.
- The voice profile path (`.claude/voice-profile.md`) can be changed to any local path -- just keep it consistent with what `/lab-profile` writes.
- The no-em-dash and other content rules are project-specific -- move or remove them as needed.
