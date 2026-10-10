# README banner design contract

Scope: `docs/assets/banner.png` only (a static 1600x800 README hero, no interaction).

## 0. Research log

- Layer B reference: `vercel.md` (developer infrastructure, mono precision,
  shadow-as-border, a colour-coded workflow pipeline). Shortlist was vercel,
  warp, linear; vercel won because its "Develop -> Preview -> Ship" pipeline maps
  directly onto Forge's plan -> build -> QA -> ship.
- Lazyweb, StyleGallery and imagen lanes skipped: this is one static image, not
  a product screen.

## 1. Direction

Gallery-white engineering chrome, so the only colourful, lit object is the
real kaiju render produced by Forge. The thing to remember: one sentence on the
left becomes a real game screenshot on the right.

## 2. Tokens

- Canvas `#ffffff` with a faint pastel wash behind the screenshot (vercel hero gradient).
- Ink `#171717`; secondary `#4d4d4d`; tertiary `#808080`; hairline `#ebebeb`.
- Pipeline accents, used only on the pipeline: plan `#0a72ef`, build `#de1d8d`, ship `#ff5b4f`.
- Type: Geist 600 display at -2.88px tracking, Geist 400 body, Geist Mono 500 uppercase labels.
- Elevation: card stack `0 0 0 1px rgba(0,0,0,.08), 0 2px 2px rgba(0,0,0,.04), 0 8px 8px -8px rgba(0,0,0,.04)`; screenshot gets an extra soft ambient lift.
- Radius: 8px cards, 12px screenshot, 9999px badges only.

## 3. Rules

- No emoji, no gradient text, no coloured accent borders on rounded surfaces.
- Borders come from the shadow ring, never from CSS `border`.
