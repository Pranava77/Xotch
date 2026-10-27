# Site design

How the Xotch site (`docs/index.html`, `docs/compare/`, `docs/404.html`) is designed, so later
changes stay consistent. Written with the `/awwwards` workflow; the app's own design lives in
`ENGINEERING.md`.

## Brief

- **Subject:** Xotch, a native Mac app that lives in the notch: an AI that acts after you click
  Allow, push-to-talk dictation that stays on the Mac, the day's modules one hover away, live
  "ears" beside the camera, and a page mascot that watches the pointer.
- **Audience:** Mac users who already know notch apps (NotchNook, Alcove, Boring Notch) and
  developers who run Claude Code. They compare before they install.
- **The site's job:** get beta invite requests, and win the comparison honestly.
- **Assets:** real screenshots (`images/`), the twelve page-mascot sheets (MIT, Kamran Ahmed),
  the app icon. No photography, no invented numbers: every figure on the page is from
  `PERFORMANCE.md` or a vendor's own page.
- **Constraints:** static files served from `docs/` (GitHub Pages or any static host), no build
  step. Light enough to match an app that idles at 0.3% CPU.
- **Assumptions to replace:** the site address `https://xotch.app/` and the invite address
  `hello@xotch.app`. Neither resolves yet. Both are marked with comments in the HTML, and the
  address also lives in `robots.txt` and `sitemap.xml`.

## Concepts

| | Idea | Anchor | Signature | O / F / Fe / P |
|---|---|---|---|---|
| **A. The product's material** | The page lives in the notch: everything opens out of the black notch at the top of the screen and tucks back into it, and its ears narrate what's live | Xotch exists only in the notch; when closed, its "ears" show what's live | The notch opens into the hero and closes as you scroll; after that its ears show the section you're reading, the way the app's ears show music or a timer | 4 / 5 / 5 / 1 |
| B. The name | *Notch* also means a mark cut to keep count: the page is a tally of a day, each section a notch cut along the top edge | the word "notch" | Notches cut into the top of the viewport as you scroll | 4 / 3 / 3 / 2 |
| C. How it works | "Nothing changes until you click Allow": every section arrives as a pending action card that the visitor allows | the app's permission cards | Sections wait as cards, then resolve with a check | 4 / 4 / 4 / 2 |

**Pick A.** It can't be moved to another product (swap in any app that isn't a notch app and
the sentence stops making sense), it gives a rule for layout, motion, type and copy, and it is
cheap to build well. **From C:** the primary button's press reads like the Allow card resolving,
and the beta section's request is phrased as an action you approve.

## Concept card

```
Idea:        Xotch lives in your Mac's notch, so the site does too: things open out of the
             black notch at the top of the screen and tuck back into it.
Metaphor:    the top of a Mac screen: the camera notch, the menu bar, Control Center's dark material.
Signature:   the notch opens into the hero on load and closes as you scroll; from then on its
             ears show the section you're in (an icon left, something live right), with the
             app's own mascot watching the pointer from the left ear at the top.
Emotion:     recognition. "That's the top of my Mac." Calm, exact, a little playful.
Motion verb: drop out of the notch, tuck back in. Things arrive downward from the top edge on
             the app's spring, and leave upward.
Screenshot:  the open notch hanging from the top of the page over the headline.
```

## Driver

One variable carries the concept: **the section in view** (`data-ear` on each section, read by
one IntersectionObserver). It sets the ears, the current nav link, and the nav's state. Scroll
progress over the first 320 px closes the hero notch (a CSS scroll timeline). The pointer feeds
the mascots (they turn toward it, as in the app). Idle: the live item in the ear keeps moving
(level bars, thinking dots, a pulsing beta dot), the mascots breathe and blink, and the
closed-notch demo takes turns between its live activities, as the app does. All of it stops
under reduced motion.

**One clock:** there is no GSAP or Lenis here. Everything that moves is a CSS animation or
transition on `transform`, `opacity` or `clip-path`, so the browser's compositor is the one
clock. JavaScript only flips states: one IntersectionObserver, one pointer listener (coalesced
to one frame, active only while mascots are on screen), and a 4 s timer for the ears demo that
pauses off screen, on hover and on focus. Scrolling stays native: the page is a product page,
and native scroll is part of feeling like the Mac.

## System

### Palette (macOS's own colors)

| Role | Dark | Light | Source |
|---|---|---|---|
| notch | `#000000` | `#000000` | the camera notch; never changes with the theme |
| ground | `#08090B` | `#F2F2F5` | the desktop at night / a light window |
| surface | `#101216` | `#FFFFFF` | panels |
| ink | `#F3F4F6` | `#1D1D1F` | text |
| muted | `#8A919D` | `#5E626B` | secondary text (AA on ground and surface) |
| line | `#23272E` | `#D9D9DF` | hairlines |
| accent | `#FF9F0A` | `#A35600` | macOS system orange, the dot in the notch. Used for the brand dot, the primary button and current-state markers only |
| live | `#FF453A` mic, `#30D158` allowed | | system red and green, inside the notch only |

The earlier light theme used a warm cream ground with the orange, which read as the
cream-and-terracotta default. The light ground is now a cool macOS window grey.

### Type

- **Display:** Bricolage Grotesque 700, optical size on. Headlines and the big numbers.
  Tracking -0.045em at hero size, -0.03em at section size, -0.02em at 24 px. Leading 0.95 to 1.05.
- **Text:** Hanken Grotesk 400/500/600. Body 17 px / 1.6, measure 60ch.
- **Inside the notch:** `system-ui` (San Francisco on a Mac), 12 to 14 px, tabular figures. The
  notch speaks macOS; the page speaks Xotch.
- Scale: `--t-mega clamp(56px, 13vw, 200px)`, `--t-xl clamp(44px, 6.6vw, 84px)`,
  `--t-l clamp(30px, 4vw, 48px)`, `--t-m clamp(22px, 2.2vw, 28px)`, body 17, small 14, ui 12.

### Grid and rhythm

- 12 columns, 24 px gutter, max 1200 px; 16 px side gutter on phones.
- The **centre line** is the strongest vertical: the notch hangs from it, and the hero, the ears
  demo and the finale are centred on it. Everything else starts on column 1 or column 7.
- Section spacing varies: airy (160 px) around the poster and the finale, normal (112 px)
  elsewhere, tight (56 px) between a section and its own follow-up.

### Shape

One rule: things that come out of the notch have square tops and round bottoms
(`0 0 R R`), like the notch. Everything else is a full pill (buttons, tags) or 18 px panels.

### Motion language

- **Spring** `cubic-bezier(.32, 1.28, .44, 1)` for small UI (pills, ears, menu), 0.35 to 0.55 s.
- **Out** `cubic-bezier(.2, .7, .2, 1)` for big things (the hero copy, images), 0.7 to 1.2 s.
- Arrivals come downward from the top edge (`translate: 0 -14px` → 0); departures go up.
- Stagger 70 ms.
- Page changes: the notch drops down over the page you're leaving (0.42 s, out), and the next
  page opens back out of it (0.6 s, out). `site.js` plays the first half and leaves a flag in
  `sessionStorage`; the next page's head script adds `arriving` before first paint. The nav
  notch stays on top throughout. Skipped under reduced motion, for new tabs and modified clicks.
  (Cross-document view transitions were tried first; they don't run everywhere, and the change
  read as a hard cut where they didn't.)
- Past the hero, a translucent menu bar fills in behind the notch, as on a Mac, so body text
  never shows beside the notch while it scrolls under.

### Interaction treatments (one per role)

| Role | Treatment |
|---|---|
| Nav links (in the notch) | a pill opens behind the link on the spring; the current section gets an orange dot |
| Primary and secondary buttons | a black notch drops into the pill from its top edge and the label turns system orange; press squashes to 0.97 |
| Module rows (Your day) | one notch marker slides to the row on the spring, the row's text steps 16 px right, the preview swaps, and the right ear names the module |
| Mascots | they turn toward the pointer; a click boops (blink, then heart, sparkle, delight; four quick boops make it dizzy), as in the app |
| Inline links | underlined at rest; the line thickens on hover |
| Utility links (footer, sources) | colour only |

## Composition plan

Each section uses a different layout family.

```
HERO (scene)                      STATEMENT
        [■■■ open notch ■■■]       ┌────────────────────────────────┐
                                   │ Press ⌘⇧Space and ask; [AI] … │  t-m, cols 1–10,
The notch that     lede            │ Hold Fn and talk [Dictation] …│  inline chips link
does the work      [Join] [Compare]│ …one hover away [Your day] …  │  to the sections
                   tags            └────────────────────────────────┘

AI (asymmetric pair)              DICTATION (poster)
┌──────────── ai-tools ──┐ text    HOLD FN.
│  cols 1–8              │ 9–12    SPEAK.                 ┌ module ┐
└────────────────────────┘         LET GO.  (t-mega)      └ ears ──┘
      ┌──── ai-reply ── cols 5–12 ┐  three short facts in columns

YOUR DAY (index list + sticky preview)        EARS (full-bleed demo)
To-dos        ───────────  ┌──────────────┐    ┌──── one closed notch ────┐
Calendar      ───────────  │  preview of  │    │  ears take turns, 4 s     │
Focus         ───────────  │  active row  │    └───────────────────────────┘
Now Playing  ●───────────  └──────────────┘     Music · Claude · Focus · Rec
…(9 rows)                  (sticky)

MAKE IT YOURS (gallery wall)     PRIVACY (data)              COMPARE (table slice)
 🦊 🐱 🐰 🐻 🐸 🦖                 ~0.3%  29 MB  ~30 ms  0%     Where Xotch stands   → full comparison
 🐹 🦌 🧑‍🚀 ⚙ 👨‍🍳 📺  text + palette   Stays │ Leaves (ledger)     4 rows: Xotch vs the other seven

FAQ (two column)                 BETA + FOOTER (finale)
Good to     ┌ details ┐                 [ closed notch, ears: mascot · Beta ]
know        ├ details ┤                      Try it before it ships
            └ details ┘                 [Ask for an invite]  three steps
                                        small print
```

**Compare page** (`compare/`): poster title with jump links, the full matrix (its header stays
under the menu bar while the table is on screen; on a phone every answer carries its app's name and
rows where all eight agree collapse to one line), then the verdicts as an index list (each app's
name in a notch tab hanging from the row's rule, best-for and pros/cons on the right), then sources.
**404:** a closed notch with nothing live, the mascot looking around in the ear, and two ways
out.

### Phone (390 px)

The open notch uses a narrower crop (music and mascot tiles) under a black strip that holds the
nav. The nav collapses to Xotch, Beta, theme and a menu button; the menu drops out of the notch.
The module index shows each preview inline under its row; the mascot wall is 4 × 3; numbers stack
2 × 2; the poster type re-tunes to 22vw.

## Genericness test

A generic model given "a landing page for a Mac notch app" lands on: a centred hero over a
gradient with the app screenshot below, four feature cards with icons, eyebrows above every
heading, a 3 × 3 card grid of features, a stats strip, and an FAQ. The first version of this
site was close to that. Changed:

- The hero is the open notch itself, hanging from the top edge, not a screenshot in a frame.
- The four feature cards became one paragraph with inline links.
- The 3 × 3 module grid became an index with one large preview, like the app's tab bar.
- The four ears cards became one closed notch that takes turns, which is what the app does.
- Eyebrows are gone except where they carry information (the beta status).
- The mascot is shown working (watching your pointer) instead of being described.
- The cream ground is gone.

## Decisions

- **Dark and light** are both designed; the toggle in the notch remembers a choice, otherwise the
  system decides. The notch is black in both.
- **No loader.** It's a product page; the open-notch intro is the arrival.
- **A quiet first screen at rest.** After the intro, what moves on the first screen is small on
  purpose: the fox in the left ear breathes, blinks and follows the pointer, and the right ear's
  two live things (a music wave, Claude Code "Editing") take turns every 4 s. That is how the
  real notch behaves, and the notch is meant to be ambient, so it stays below what `shoot.mjs`
  counts as idle motion (`idleMotion: false`). Larger idle motion lives further down: the ears
  demo takes turns and the twelve mascots breathe and watch the pointer.
- **Smooth scrolling only for in-page links.** A global `scroll-behavior: smooth` also slowed
  focus moves and find-in-page, so `site.js` turns it on just for the click that follows a link.
- **404 paths** use root-absolute URLs (`/site.css`), which assumes the site is served from a
  domain root. Change them if it's served from a subpath like `/Xotch/`.
