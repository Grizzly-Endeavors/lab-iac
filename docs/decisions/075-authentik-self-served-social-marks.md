# ADR-075: Serve Our Own Social Provider Marks on the Authentik Login Page

**Date:** 2026-09-05
**Status:** accepted

## Context

The Discord/GitHub/Google buttons on the `sso.grizzly-endeavors.com` login page rendered washed out — Discord as a dull olive glyph, GitHub and Google as near-invisible pale shapes on a pale chip.

The cause is an interaction between three things, only the last of which is a real defect:

1. authentik ships flat monochrome marks for GitHub and Google (single-path SVGs with no fill, so they render black). Only Discord's bundled mark carries brand colour.
2. Because those marks are dark, the cyber-bear theme put them on a near-white chip (`#eef4f8`) so they would read against the dark login card.
3. authentik's flow stylesheet inverts every source icon under its dark theme, on the assumption they sit on a dark card:

   ```css
   :host([theme="dark"]), ak-stage-identification[theme="dark"].style-scope {
     & fieldset[name="login-sources"] .pf-c-button__icon {
       & img, & .pf-c-button__icon .fas { filter: invert(1); }
     }
   }
   ```

   On a light chip that invert runs backwards: black marks become white-on-white, and Discord's blurple `#5865F2` becomes olive `#A79A0D`.

The brand's `ui_theme` is `automatic`, so the invert fires for any visitor whose OS is in dark mode and not for anyone else — the same page looked correct or broken depending on who opened it, which is why the fault survived the review that introduced the light chip.

A second, independent defect was distorting the marks: authentik sets `& .pf-c-button__icon img { height: var(--pf-global--FontSize--2xl) }`. Both that rule and the invert are CSS-nested, so `&` carries the parent selector's specificity and an unprefixed override in `branding_custom_css` cannot outrank either. The theme set only `width`, so every mark rendered 22×24 — stretched off its own aspect ratio.

## Decision

**Serve our own provider marks, drawn for a dark chip, and make their rendering unconditional.**

- Three SVGs are added to the existing `authentik-brand-assets` nginx deployment that already serves the logo and favicon: white Discord and GitHub marks, and the full-colour Google G. Each is normalised to a square 24×24 viewBox so the three land at the same optical weight.
- Each OAuth source's `icon` field points at its mark by https URL. Like the brand image fields, `icon` accepts a built-in `/static` path, an uploaded media file, or an external http(s) URL through the passthrough file backend — but not a data URI, which the upload-filename validator rejects. That constraint is what put the logo and favicon behind nginx in the first place, and it applies here unchanged.
- The chip becomes a dark navy panel with a cyan hairline, matching the login card, rather than a light cut-out pasted onto it.
- The theme neutralises the invert with `filter: none !important` and pins both icon axes with `height: … !important` plus `object-fit: contain`. `!important` is the only lever that outranks a nested vendor rule; both declarations are annotated in place with the rule they override and why.

**Google's mark stays full-colour** while the other two are flattened to white. Google's brand guidelines forbid recolouring the G, and there is no white variant we are entitled to substitute. Discord and GitHub both publish white-on-dark treatments, so those are used as-is.

Neutralising the invert unconditionally — rather than only under the light theme — is deliberate. The flow page is forced dark for every visitor regardless of their OS colour scheme, so a scheme-dependent icon treatment can only ever be wrong in one of its two states. Removing the conditional removes the class of bug, not just this instance of it.

## Alternatives Considered

- **Keep the light chip and fix only the invert.** Smallest diff, but it preserves the mismatch that caused the bug: a light chip inside a theme that tells authentik it is dark. Every future authentik release that touches source-icon styling gets another chance to invert something onto a background it was not drawn for.
- **Recolour authentik's bundled marks with CSS filters.** `filter: invert()`/`brightness()` can turn the black GitHub and Google paths white without new assets, but it cannot produce Google's four colours, and applying it to Discord's already-coloured mark destroys the blurple. Serving real assets is both fewer moving parts and the only route to a correct Google G.
- **Use authentik's `icon_themed_urls` (separate light/dark marks).** Solves nothing here — the page has exactly one appearance — and doubles the assets to maintain.
- **Promote the sources to full labelled buttons (`promoted: true`).** authentik renders "Continue with X" rows instead of icon chips, which is more legible than three unlabelled icons. That is a layout change rather than a fix for this defect; it stays available if the icon row proves unclear in use.

## Consequences

- The login page renders identically for every visitor. A future authentik upgrade that changes source-icon styling can still regress this, and the `!important` declarations are the tripwire: if they stop being needed, the annotated comments say exactly which upstream rules to re-check.
- Three brand assets are now ours to maintain. They are static marks that change on the order of years, and they live beside the logo and favicon that were already on the same footing.
- The provider marks are pinned in git rather than tracking whatever authentik ships, so a provider rebrand is our change to make rather than one that arrives with a chart bump.
