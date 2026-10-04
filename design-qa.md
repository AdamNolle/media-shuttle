# Windows UI verification — 2026-10-03

final result: passed

## Accepted target

The user approved the current application body, then requested the original integrated Windows title bar, themed Settings and other in-app overlays, and square toggle switches. This review preserves that approved body. It does not claim pixel identity across operating systems or certify that every possible bug has been eliminated.

Source screenshot: `C:/Users/adamm/AppData/Local/Temp/codex-clipboard-0b787ac6-15ff-4097-a0e2-037a5fa09eea.png` (also supplied in `docs/screenshot.png`).

Implementation: the Debug WinUI application launched with `--screenshot`, on the secondary display. The preview uses temporary state, does not start the card watcher, and cannot transfer or erase files. Its confirmation dialog can be inspected, but the destructive action stays disabled even after entering the phrase and checking the acknowledgement.

## Evidence and normalization

Evidence directory: `C:/Users/adamm/Desktop/Code/Media Shuttle/artifacts/ui-qa/` (local, ignored build artifacts).

| Evidence | Purpose |
| --- | --- |
| `body-dark.png` | Approved body, integrated header and native caption controls |
| `reference-1x.png` | Reference downsampled from 2120 × 1060 to 1060 × 530 |
| `comparison.png` | Source and rendered application together at normalized density |
| `details.png` | Paired source/rendered crops of banner, metrics/footer and source summary |
| `settings-dark.png` | Themed Settings, square on/off switch geometry |
| `settings-light.png` | Theme inheritance and square geometry after switching to Light |
| `confirmation-dark.png` | Themed confirmation panel, field, buttons and disabled destructive action |

Windows evidence is 898 × 833 physical pixels; Computer Use displays a logical viewport of approximately 898 × 834. This is a native application, so CSS viewport and browser deviceScaleFactor do not apply. The reference is treated as a 2× capture; the Windows capture is reviewed at 1×. The reference and live window have different aspect ratios. The extra vertical space and the anchored erase panel reflect the taller secondary display, not a new body layout. No pixel-difference score was used.

Full-view and focused comparisons were inspected after the title-bar repair. The full comparison checks region hierarchy and the focused comparison checks small type, progress segments, buttons and card artwork at normalized density. Pointer highlights visible in some captures come from the Computer Use helper.

## Findings and comparison history

1. Removed the macOS traffic-light controls. The intermediate separate native title strip was rejected by the user. The final capture shows the original integrated header architecture with native Windows minimize, maximize and close controls on the right.
2. Settings originally retained WinUI's rounded gray flyout and larger typography. The revised flyout uses the app's panel palette, monospace labels, square hairline borders and compact buttons. Nested theme options inherit the palette and red selection accent.
3. Rounded switch tracks and knobs were replaced with square geometry at the user's request. Native Windows toggle behavior, automation peers, dragging and state animations are retained. The on-state uses the app's red palette in Dark and Light.
4. WinUI replaced the confirmation dialog's default Cancel button style with its blue accent style. The final dialog restores the app's secondary-button appearance after opening, while keeping Cancel as the default action. Dialog content uses the app's panel palette, typography and red confirmation-field accent.

No actionable P0/P1/P2 visual findings remain within this accepted scope.

## Fidelity surfaces

- **Typography:** Cascadia Mono provides the compact Windows counterpart to the reference's monospace font. Windows rasterization differs from macOS; font metrics and antialiasing are not pixel-identical. The user accepted the body. Settings labels and controls now follow its type hierarchy.
- **Spacing/layout:** Approved body dimensions and breakpoints were preserved. Settings is a compact 280-unit content column. Its controls remain visible in the observed viewport. Windows header height and caption placement intentionally follow the original Windows architecture.
- **Colors/tokens:** Dark panels, muted foregrounds, thin separators, green verification and red destructive/on-state accents follow the app palette. Settings and its theme submenu also follow Light mode.
- **Artwork:** Existing screenshot-derived logo and card assets remain unchanged. Their crops and opaque dark backgrounds were retained after body approval.
- **Copy/content:** The preview reproduces the reference's sample session values. Its macOS-style paths are sample display strings only; production still uses Windows paths. Existing settings and confirmation copy remains functional.

## Verification and residual gaps

- Debug and Release x64 builds succeeded with zero warnings and errors, using `MSBuildEnableWorkloadResolver=false` for this machine's SDK environment.
- All 83 core assertions passed: classification, settings, card arrivals, selected folders, verified copy, date folders, duplicates, collisions, links, cancellation, erase eligibility and post-erase verification.
- `git diff --check` passed.
- Live preview checks covered Settings opening, theme selection in Dark and Light, square switch rendering, mouse and Space-key activation, activity visibility, banner dismissal, confirmation text entry, acknowledgement, disabled preview erase and Cancel dismissal.
- Obsolete hidden hero/continuous-progress controls, their handlers, and unused artwork/style resources were removed. Existing local commits and user `.codex/` content were preserved.
- The repository was already current when pulled. No commit, push, installer replacement or deployment was performed.
- Native caption controls were visually verified; a complete minimize/maximize/restore exercise was not performed. Physical camera-card transfers/erase and a running macOS app were not exercised in this Windows session. OS-owned folder pickers and the native system-tray menu retain Windows styling. Those limits prevent an exhaustive feature-parity or zero-bug guarantee.

## Implementation checklist

- [x] Preserve the approved body.
- [x] Restore integrated native Windows chrome.
- [x] Theme Settings, nested appearance options and in-app confirmation.
- [x] Square toggle tracks and knobs; verify on/off and keyboard behavior.
- [x] Remove unused UI implementation and verify builds/core tests.
- [x] Leave the safe preview available for review.
