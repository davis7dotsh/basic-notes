# Basic Notes icon

A floating charcoal note panel on an ivory tile, with a blue insertion caret. The portrait silhouette reflects the app's single floating editor. White and grey strokes suggest a heading and text; the open lower half keeps the mark quiet.

- `icon.svg`: scalable logo, with transparent margins on the macOS icon grid.
- `icon.png`: 1024px export.
- `../scripts/make-icon.swift`: geometry and generator for the SVG, PNG, app icon family, Raycast icon and monochrome menu-bar template. Run `swift scripts/make-icon.swift` after changing the design.
- At 64px and below the panel widens and the text simplifies to one line, keeping the caret readable.

The concept was explored with OpenAI image generation and reviewed with Claude Opus 5.5. Production assets use clean vector geometry instead of tracing generated raster edges. Palette: ivory `#FAF9F6`–`#EAE7E1`, charcoal `#202124`, grey `#939497`, blue `#4DABF7`.

Concept prompt: “A refined macOS app icon for Basic Notes. A single floating charcoal portrait note panel on a warm ivory rounded-square tile, subtle depth and soft shadows. Inside upper-left: one short white heading stroke, beneath a longer muted grey body stroke, beneath one bright blue #4DABF7 vertical insertion caret. Clearly a fresh note ready for writing, portrait proportions and generous whitespace. Restrained white/black/blue, crisp geometric vector-friendly shapes. No pencil, folded corner, letters, terminal chevrons or glossy shine. Transparent outside tile and shadow.”
