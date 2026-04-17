# brad-duhon.com — Project Instructions

## Writing & Content Standards

- **No em dashes** anywhere in site content or code comments. Use a regular hyphen (-) instead.
- **No Google Fonts** — system font stack only.
- **No hardcoded email addresses** in HTML — JS obfuscation only.
- Draft lab entries use `draft: true` in frontmatter. Only commit when comfortable with it being publicly visible in source.

## Code Standards

- All new `.astro`, `.ts`, `.tsx`, `.js`, `.mjs` files get the copyright header as a comment block.
- All new `.tf` files get the Terraform copyright header.
- No em dashes in code comments either.

## Project Structure

- `apps/main` — brad-duhon.com (portfolio, single-scroll)
- `apps/lab` — lab.brad-duhon.com (digital garden, D3-force knowledge graph)
- `packages/shared-ui` — Tailwind config and amber design tokens
- `infrastructure/` — Terraform (main infra)
- `infrastructure/bootstrap/` — one-time state bucket setup
- `infrastructure/modules/static-site/` — reusable S3 + CloudFront + ACM + R53 module

## Design Tokens

- Primary accent: `#D97706` (amber-primary)
- Deep accent: `#92400E` (amber-dark)
- Highlight: `#FEF3C7` (amber-light)
- Background: `#FAFAF9` (site-bg)
- Body text: `#44403C` (site-text)
- Headings: `#1C1917` (site-heading)
