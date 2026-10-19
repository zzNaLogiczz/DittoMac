# DittoMac native macOS settings

Settings follow the System Settings model: a native split view, a unified toolbar
title, and grouped forms of elevated cards. AppKit controls keep their system
behavior; the custom work is limited to surfaces, color tokens and motion.

## Structure

- `NSSplitViewController` with a sidebar item (fixed 214 pt, not collapsible). The
  system supplies the sidebar material, full-height layout under the toolbar and,
  on macOS 26+, the floating Liquid Glass sidebar.
- Window: `.fullSizeContentView`, `.unified` toolbar holding only the sidebar tracking
  separator. The toolbar title is the current category; the titlebar separator
  appears only once content scrolls beneath it.
- Default content size 880 × 650 pt; minimum 800 × 580; English and Chinese text.
- Detail column is centered and capped at 660 pt so rows stay readable in wide windows.
- Each page: hero card (category tile 48 pt, title, one-line description), then groups.
- Group: 13 pt semibold title aligned with row text, card, optional footer (11 pt
  secondary) explaining the group. Explanations live in footers or row details, not
  as loose text inside cards.
- Row: 42 pt minimum, 14 pt insets, title (13 pt) plus optional detail (11 pt) on the
  leading side, one control trailing. Hairline separators inset 14 pt between rows.
- Lists sit edge-to-edge inside their card with a recessed +/− accessory bar and a
  centered empty state (symbol + one sentence).
- Preserve each page's scroll position while navigating; commit edits before hiding a page.
- Search indexes the actual localized setting labels as well as category names.
- Use native NSMenu hierarchy, responder-chain editing commands, and standard
  Settings (⌘,), Close (⌘W), and Quit (⌘Q) shortcuts.

## Appearance

- Tokens live in `SettingsPalette` (`SettingsComponents.swift`); every color resolves
  for light, dark and Increase Contrast.
  - Canvas: light #F2F2F7, dark #1E1E20 (window background matches, so the floating
    sidebar sits on one tone).
  - Card: white in light; dark is a top-lit gradient #313134 → #2B2B2E.
  - Card rim: 1 px black 8% / white 8%; 1 pt and much stronger with Increase Contrast.
  - Card shadow: 1 pt offset, 3.5 pt blur, 7% (light) / 32% (dark).
  - Wells (shortcut fields, list bars, subheaders): black 4% / white 6%.
- Category tiles: system colors (gray, blue, purple, indigo, orange, pink, green,
  graphite) graded 28% lighter at the top, white SF Symbol, faint inner rim; the hero
  tile casts a soft shadow in its own hue.
- Corner radius 10 pt (continuous) for cards; 7 pt for wells and sidebar selection.
- Boolean settings use `NSSwitch` (small); choices use pop-up buttons; free text uses
  rounded-bezel fields. Sidebar selection draws an accent pill while the list has
  focus, the neutral selection color otherwise.
- Shortcuts render as keycaps (⌃⌥⇧⌘ order, then the key) inside a recessed well;
  clearing is an inline `xmark.circle.fill` button.
- Status is never color-only: accessibility permission pairs a symbol with text.

## Interaction and motion

- Category changes: page blocks fade in and rise 10 pt, staggered 40 ms, 340 ms with a
  (0.2, 0.8, 0.2, 1) curve. Animations are presentation-only (model values never
  change), so layout, hit testing and VoiceOver frames are exact at all times.
- Any new selection cancels in-flight entrance animations immediately.
- Sidebar search filters rows with a fade instead of reloading the table.
- Shortcut recorder: hover darkens the well; recording tints it with the accent color
  and breathes an accent glow until a key is pressed or Escape cancels.
- Reduce Motion disables entrance motion, the search fade and the breathing glow
  (the recording state remains clearly visible as a static glow).
- Shortcut recorders support Tab focus, Space/Return activation, Escape cancellation,
  VoiceOver actions and native focus rings. Recording consumes menu key equivalents.
- All settings save immediately and synchronize with Quick Options changes.

## Validation

`scripts/preview-settings.sh` renders isolated AppKit fixtures in Chinese/English,
light/dark, and minimum window size. It also checks category search/navigation,
external-setting synchronization, and shortcut recording/cancellation. It does not
access the user's database, system clipboard, keychain, or desktop input.

Offscreen fixtures cannot show window-server effects: the sidebar glass/material,
vibrant controls on it (the dark search field renders as a white bar), switch accent
color of a key window, and layer shadows. Check those in the running app.

Design references: [Apple Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars),
[Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles),
[Adding a settings interface](https://developer.apple.com/documentation/foundation/adding-a-settings-interface-to-your-app),
[Reduce Motion](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion).
