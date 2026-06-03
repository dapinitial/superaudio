# SuperAudio — House Style

> The rules that keep every strategic HTML doc visually and rhetorically coherent.

This file is for the human (or future-me, or a contractor) writing the next strategic HTML artifact. It documents the system that emerged across `index.html`, `CASE_STUDY.html`, `COMPETITIVE_LANDSCAPE.html`, `PRICING.html`, `POSITIONING.html`, and `RISK_REGISTER.html` — what palette, what typography, which components to reuse, when to bend the rules.

The shared CSS lives at [`website/_shared.css`](../website/_shared.css). New docs link it in their `<head>`:

```html
<link rel="stylesheet" href="_shared.css">
```

…then add page-specific overrides in an inline `<style>` block after the link.

---

## Palette

Dark-first. Orange/amber gradient is the brand signature. Cyan is the secondary callout color. Greens/ambers/reds form a severity triad used consistently across risk, verdict, and pricing-position tables.

| Var | Hex | Role |
|---|---|---|
| `--bg` | `#0a0a0f` | Page background. Always dark; never invert. |
| `--bg-card` | `#14141c` | First-tier card background (most cards) |
| `--bg-card-2` | `#1a1a24` | Second-tier card / hover state / nested callout |
| `--border` | `#23232e` | Default border |
| `--border-bright` | `#2e2e3c` | Hover border |
| `--text` | `#ececf1` | Primary text |
| `--text-muted` | `#8a8a96` | Secondary text (lede, body, table cells) |
| `--text-dim` | `#5a5a66` | Tertiary (metadata, footer, captions) |
| `--accent` | `#ff6a3d` | Primary orange. Brand signature. |
| `--accent-2` | `#ffba6d` | Amber. Always paired with `--accent` in a gradient. |
| `--good` | `#4ade80` | Green — positive verdict, low risk |
| `--warn` | `#fbbf24` | Amber — neutral/middle, medium risk |
| `--bad` | `#f87171` | Red — negative verdict, high risk |
| `--cyan` | `#67e8f9` | Info callout, "defense" against a risk, secondary highlight |
| `--violet` | `#a78bfa` | Reserved, used sparingly |
| `--pink` | `#f472b6` | Reserved for the "wedge" closing gradient |

**Signature gradient** — `linear-gradient(135deg, var(--accent) 0%, var(--accent-2) 100%)` — appears on:
- Wordmark in topnav (`.topnav .brand`)
- Featured stats (`.stat .num`)
- Headline emphasis spans (`<h1><em>like this</em></h1>` and `<h2 .num em>`)
- Page-specific hero ::before glows (with `rgba(255,106,61,0.10)` radial fade)

---

## Typography

System font stack only. Zero load time, feels native on macOS/iOS, signals indie.

```css
font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif;
```

| Element | Size | Weight | Letter-spacing |
|---|---|---|---|
| `h1` (hero) | `clamp(40px, 6vw, 68px)` | 800 | -0.025em |
| `h2` (section) | 36px | 800 | -0.02em |
| `h3` | 22px | 700 | -0.01em |
| `h4` (kicker) | 14px UPPERCASE | 600 | 0.08em |
| Body | 16px | 400 | normal |
| `.subhead` | 16px | 400 | normal (in `--text-muted`) |
| `.lede` | 20px | 400 | normal (in `--text-muted`) |
| Code | 13px SF Mono | 400 | — |

Body line-height is `1.65`. Heading line-height is tight (`1.05`–`1.15`).

---

## Page anatomy

Every strategic HTML doc follows the same skeleton:

```
<nav class="topnav">     ← sticky brand bar with nav-links + .tag
<header class="hero">    ← eyebrow + h1 + lede + meta + (optional) .stats
<section> (numbered h2)  ← repeated, each starts with h2 + subhead
…
<section> (closing)      ← ends with .wedge for the strategic conclusion
<footer>                 ← date + author + cross-links
```

The `<section class="num">` pattern: `<h2><span class="num">1</span>Section title</h2>` for visually-numbered sections. Skip the `.num` span when titles aren't sequential.

---

## Reusable components

Defined in `_shared.css`. Reach for these before writing new CSS.

### `.stats` — hero metric strip

4-column grid of `.stat`s with gradient `num` and muted `label`. Goes immediately under the lede in the hero. Below 720px width, collapses to 2 columns.

```html
<div class="stats">
  <div class="stat">
    <div class="num">$19</div>
    <div class="label">Mac app base price</div>
  </div>
  …
</div>
```

### `.table-wrap` + `table` — comparison tables

The workhorse. Use for any structured comparison (competitors, prices, capabilities, risks). Add `tr.us-row` to highlight a SuperAudio row inside a competitor table.

### `.v` — verdict badges

Inline badges. Variants: `.good` `.warn` `.bad` `.info` `.us`. Same color triad as the risk register; use them consistently so green always means "good" across all docs.

### `.pullquote` — orange-left-bordered emphasis block

For the one or two sentences per section that should land hardest. Wrap the key phrase in `<strong>`. Avoid having more than one pullquote per section.

### `.card-grid` + `.card` — generic tile grid

Auto-fill grid of cards. Use `.card.featured` for the "us" or "recommended" tile (gets accent border + subtle gradient background).

### `.risk` — severity-tiered callout

Two-column callout with a severity badge on the left and title+body+defense on the right. Variants: `.high` `.medium` `.low`. Used in both `COMPETITIVE_LANDSCAPE.html` (patents) and `RISK_REGISTER.html` (risks).

### `.wedge` — closing strategic statement

The final card of every doc. Orange-to-pink gradient background, title with italic emphasis, 1–3 short paragraphs that restate the strategic conclusion. Drop the doc's name here.

---

## When to bend the rules

Inline `<style>` overrides are fine — every doc has them. The signal that you've drifted too far: when the page no longer "feels" like part of the set. The smoke alarms:

- A new background color outside the dark palette.
- A non-system font (especially serif or display).
- A non-orange gradient as primary emphasis.
- Cards without the dark fill + border + radius treatment.
- Tables with vertical borders or zebra striping (we use horizontal-only).

Page-specific components ARE fine — `PRICING.html` invents `.ruler` and `.sku-grid`, `POSITIONING.html` invents `.pitch-stack` and `.anti-grid`, `RISK_REGISTER.html` invents `.watch` and `.risk-table`. These belong in the file, not in `_shared.css` — they're page-specific shapes, not house style.

Move a component into `_shared.css` only when **two or more docs use it**. The current shared library reflects that threshold; everything in there appears across multiple docs.

---

## Voice and copy rules

Voice rules live in [`website/POSITIONING.html`](../website/POSITIONING.html) — that document is binding for marketing surfaces. The HTML strategy docs (case study, landscape, pricing, risk register) follow a slightly more analytic tone than the public-facing site, but still:

- **Be specific.** Real numbers, real product names, real prices.
- **Lead with the conclusion.** Then defend it.
- **No hype words.** "Revolutionary," "game-changer," "next-gen," "AI" all banned.
- **No emoji** in body copy. Reserve for flag icons in international tables (🇺🇸 🇬🇧 etc.) and the occasional ✅ / 🟡 in roadmap-style progress lists.
- **Lower-case section numbers when in prose** ("see section 3 below"), capitalize only when standing alone ("Section 3 covers…").
- **Em-dashes are fine** — they're a feature of the voice. Use sparingly.

---

## When to create a new HTML doc

Default answer: don't. Each new doc dilutes the existing set and risks repeating content that's already somewhere. Before writing, answer:

1. **What question does this doc answer that no existing doc does?** If you can't name the question in one sentence, the doc isn't needed yet.
2. **Is the question still going to be asked in six months?** Ephemeral analysis (e.g., this-quarter's results) belongs in `docs/DECISIONS.md` as an append-only entry, not a standalone HTML.
3. **Could this be a section in an existing doc instead?** If the new doc is &lt;15KB or covers a single section's worth of content, it belongs inside `CASE_STUDY.html` or `COMPETITIVE_LANDSCAPE.html`.

When the answer to all three is "yes, new doc is warranted," follow the page-anatomy skeleton, link `_shared.css`, add topnav links in all existing docs to keep navigation bidirectional, and update [`README.md`](../README.md) doc map.

---

## Maintenance

- **Sunset stale docs.** If a doc's truth has migrated elsewhere (e.g., roadmap detail now in `ROADMAP.md`), strip the doc to a one-liner pointer rather than letting it rot.
- **Bidirectional links.** When adding a new HTML doc, update topnav `.nav-links` in every other doc. Tedious but load-bearing for navigation.
- **Update timestamps.** Every doc footer has a date. Update it when the doc is meaningfully revised, not on cosmetic edits.
- **CSS migration.** Existing HTML files (`CASE_STUDY.html`, `index.html`, `REACTIVE_DISCOVERY.html`) predate `_shared.css` and still use inline CSS. They're visually consistent because the inline CSS happened to match. **Don't migrate them unless visual fidelity can be verified**; the new docs (`PRICING`, `POSITIONING`, `RISK_REGISTER`, `COMPETITIVE_LANDSCAPE`) link `_shared.css` and are the canonical examples.

---

## How this style emerged

The dark/orange aesthetic wasn't designed — it emerged. The first strategic doc (CASE_STUDY.html) needed to feel like a real product brief, not a startup pitch deck or a corporate sales page. The constraints were: looks expensive but built in one sitting, reads on any device, no dependencies, printable. Dark + system fonts + one signature gradient + structured callouts hit all of them.

Subsequent docs reinforced the system because deviating felt worse than conforming. The shared CSS is the formal capture of that emergence.

If the system stops serving a doc's needs, change the system — and update this file. Don't hack around it.
