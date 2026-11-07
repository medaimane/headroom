# Headroom brand

Internal notes for the logo and visual style. Not linked from the website.

The mark is three usage bars that all stop below a ceiling. The space between the bars and the ceiling is the headroom: what you have left to work with.

## Files

All in [`docs/assets/`](docs/assets/), because the website uses them.

| File | Use it for |
|---|---|
| `icon.svg` | App icon source (macOS grid, 1024 px canvas). `make icon` renders it to `Resources/AppIcon.icns`. |
| `mark.svg` | Favicon, avatars, small placements. Full-bleed tile. |
| `mark-mono.svg` | One-colour mark (`currentColor`) for print, menu bar templates and tiny sizes. |
| `logo.svg` | Mark with wordmark, on light backgrounds. The wordmark uses the system font. |

## Colours

| Name | Hex | Use |
|---|---|---|
| Night | `#0A111F` | Icon background (bottom), dark site background |
| Dusk | `#1C2B47` | Icon background (top) |
| Headroom mint | `#3DDC97` | Accent on dark |
| Mint on light | `#12A571` | Accent on light, primary buttons |
| Bar gradient | `#14A673` → `#5CF0B2` | The three bars in the mark |
| Sky | `#7DD3FC` | The glow under the ceiling, focus rings |
| Ceiling | `#E8F1FF` | The ceiling line |
| Warning | `#F5B53D` | Status only |
| Critical | `#F0605D` | Status only |

## Type and voice

- **Type:** the system font (SF Pro on Apple platforms), bold and slightly tight for headings. SF Mono for code.
- **Voice:** plain, calm and specific. Say what happens, how big it is and how to undo it. No scare words, no "boost" or "optimize".
- **Mark usage:** keep clear space of a quarter of the mark's width around it. Don't recolour the bars red or amber; status colours belong to the app's indicators, not the logo.
