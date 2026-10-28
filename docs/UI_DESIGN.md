# Interface design

Version 1.5.17 integrates the approved visual study into the existing application.
It keeps the graphite, amber and green identity while reducing navigation,
heading, table and form padding. The working 1.5.16 package remains the rollback
baseline; this release is a separate complete source package.

## Presentation layer

`public/assets/css/refresh.css` is loaded last by the styles partial. It centralizes
the refreshed palette and spacing, then styles the existing shell, tables,
editor, engine controls, hardware cards, dialogs and Chat. Existing structural
styles remain in their original files. There is no theme selector, theme
configuration or new preference format.

Use the shared CSS tokens for visual constants. Keep form labels, controls,
descriptions and inline errors together. Task sections use dividers rather than
a separate border around every field. Keep explicit action hierarchy and clear
disabled states. New Chat selectors remain scoped to `#chatView`.

The splash template, dedicated splash CSS, assets and motion logic are retained.
The refresh keeps its inherited base font unchanged and leaves the splash
keyframes and reduced-motion behavior under the existing rules.

## Mounted controls and state

The real controls, IDs and handlers are retained. The external native-JSON
import panel is moved to a presentation mount above model identity; the same
file input and inspection handler are reused. Static component paths now place
their existing Browse buttons alongside their existing inputs.

Save, live catalog updates and loaded processes retain their existing boundaries.
The refresh does not alter engine definitions, provisioning, compatibility probes,
GPU identity/planning, process ownership or Chat request defaults.

## Dashboard data

The new per-device panel consumes the already collected GPU/system sample.
It reports each device independently and displays unavailable values explicitly.
It does not combine AMD/Intel shared-memory pools or assert physical placement.
The Dashboard's saved GPU selection comes from the preset snapshot; it is not
a live placement report. Load/unload continues through the existing handlers.

The visual study used illustrative performance charts. This release does not
invent those readings: existing Model Stats and hardware views retain their
actual data sources and histories.

## Validation

Run the documented development checks. `tests/visual_refresh.js` additionally
checks the declared stylesheet cascade, Dashboard structure, numeric zero versus
unavailable telemetry, escaped device names, import-first control mounting,
label/help ownership, action hierarchy and navigation through every real view.
Existing regressions cover native/external editing, import, clone, saving,
validation dialogs, Router actions, model-default Chat behavior and splash motion.

These are syntax, HTTP and DOM checks with synthetic data. They do not establish
pixel fit, browser-specific rendering, Windows execution or hardware inference.
Review the application at 1920 × 1080 and smaller widths, especially long model
names/paths, expanded engine groups, the model inspector, nested dialogs and Chat.

## Upgrade or rollback

Use the documented application-file replacement procedure, retaining `presets/`
and `logs/`. This refresh introduces no saved-format changes. To roll back the
presentation, restore the complete 1.5.16 application files while retaining those
same data directories. Keep the running application stopped during replacement.

## 1.5.18 refinements

Dashboard action buttons retain their full labels; the table scrolls horizontally when needed and stacks on narrow screens. GPU lists normalize comma spacing only for display. General controls use word-boundary wrapping rather than inheriting arbitrary cell breaks.

GPU metrics use shared label/value/chart rows with CSS subgrid, and a flex fallback. Cards stretch to their grid row and keep the metric block at the bottom. This does not change samples or physical identity semantics. Model identity now links directly to the existing unified engine/build manager. Model Stats resolves external build IDs to registered aliases without rewriting history.
