# Theme invariants

| Id | Level | Invariant | Seam | Owner test | Source |
| --- | --- | --- | --- | --- | --- |
| THM-1 | Module | Palette roles resolve to their specified cloth colours in both modes. | `background`, `text`, `thread` | `THM-1 palette roles retain their cloth colours` | `src/theme.zig` |
| THM-2 | Module | Indexed roles use the nearest xterm colours except the explicit accessible, distinguishable surface and ink choices. | `background`, `text`, `thread`, `nearestIndex`, `xtermRgb` | `THM-2 indexed colours use nearest xterm entries with accessible distinct surfaces` | `src/theme.zig` |
| THM-3 | Module | Ground, tint, selection and hover are distinct in each colour depth, and the message tint differs from ground. | `background` | `THM-3 surfaces preserve action distinction and message tint` | `docs/contracts/session-ui.md`, mouse and keyboard choice parity |
| THM-4 | Module | Readable ink meets a 4.5:1 contrast floor on its layout surfaces in both modes and colour depths. | `text`, `background`, `xtermRgb`, `relativeLuminance` | `THM-4 readable text meets WCAG contrast on its layout backgrounds` | `src/theme.zig` |
| THM-5 | Module | The Devanagari wordmark appears only for UTF-8 on known terminals. | `wordmark` | `THM-5 wordmark requires a known terminal and UTF-8` | `src/theme.zig` |
