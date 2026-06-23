# Claude Status Tidbyt — design notes

## Data source

Atlassian StatusPage hosts `status.claude.com`. The public, unauthenticated JSON API exposes everything we need in a single request:

| Endpoint | What |
| --- | --- |
| `/api/v2/summary.json` | Everything in one payload: `page`, `status` (indicator + description), `components`, `incidents`, `scheduled_maintenances`. ~5–10 KB. |
| `/api/v2/status.json` | Just `status.indicator` and `description`. Tiny. |
| `/api/v2/components.json` | Just the components. |
| `/api/v2/incidents/unresolved.json` | Only currently-open incidents. |
| `/api/v2/incidents.json` | Full incident history. |

We hit `summary.json` once per render. The response carries `access-control-allow-origin: *` and `cache-control: max-age=3, public, s-maxage=10, stale-while-revalidate=20` — i.e., the CDN edge caches for 10 s. Our Pixlet `ttl_seconds=60` is a polite multiplier on top.

### Field semantics

**`status.indicator`** is one of `none` / `minor` / `major` / `critical` / `maintenance`. This drives the big-tile background color.

**`components[].status`** is one of `operational` / `under_maintenance` / `degraded_performance` / `partial_outage` / `major_outage`. Drives per-component dots in the right column.

**`components[].group`** is `true` for header rows in grouped pages. Claude's page is flat today but the API allows nesting, so we filter `group=true` out of the displayed list.

**`incidents[].impact`** is one of `none` / `maintenance` / `minor` / `major` / `critical`. We rank incidents by impact and show only the worst-impact open one on the device.

**`incidents[].status`** is the incident lifecycle: `investigating` / `identified` / `monitoring` / `resolved` / `postmortem`. We don't display this — the impact is more meaningful at a glance — but it's in the trace log for diagnosis.

**`incidents[].created_at`** is an RFC3339 timestamp with milliseconds (e.g., `2026-06-23T14:19:06.033Z`). Starlark's `time.parse_time` is strict about the format string matching exactly, so the parser slices off the fractional-second portion before parsing.

## Layout (64×32)

```
┌──────────┬───────────────────────┐
│          │ ● API                 │
│          │ ● claude.ai → Chat    │
│   OK     │ ● Code                │
│          │ ● Console → Cnsl      │
│          │ ● Cowork → Cowk       │
│          │ ● Gov                 │
└──────────┴───────────────────────┘
  28 × 32              36 × 32
```

When something is degraded, the layout is a **two-frame full-screen swap**, not just a right-column swap:

Frame 1 (~5 s) — severity tile + component grid:

```
┌──────────┬───────────────────────┐
│   5      │ ● API                 │
│          │ ● claude.ai → Chat    │
│   24m    │ ● Code                │
│          │ ● Console → Cnsl      │
│          │ ● Cowork → Cowk       │
└──────────┴───────────────────────┘
```

Frame 2 (~5 s) — full-width incident view, big tile dropped:

```
┌─────────────────────────────────────┐
│ Elevated error rate across multip…  │  ← marquee, width 62
│                                     │
│              critical               │  ← impact (colored, centered)
│                                     │
│▓ 24m ago  5 hit ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│  ← age + count, full-width colored band
└─────────────────────────────────────┘
```

The big severity tile is redundant on the incident frame — the impact word is already colored by the same scheme — so dropping it gives the marquee 62 px instead of 34, which is enough that medium-length incident titles render statically rather than scrolling. The animation runs at ~5 s per frame (`GRID_FRAMES = INCIDENT_FRAMES = 100` at pixlet's 20 fps default). When no incident is open, no animation — just the static grid.

Three tom-thumb lines on the incident frame: marquee name top-aligned, colored impact word ("minor" / "major" / "critical" / "maint") horizontally centered in the middle, and a combined `<age> ago  <N> hit` row on a full-width colored band at the bottom. The band uses the same `INDICATOR_COLORS[indicator]` (bg, fg) pair as the frame-1 big tile, so the severity color and the contrast-flipped text color carry from one frame to the other. Avoided a Row + `space_between` for impact/age earlier — at tom-thumb widths long words like "critical" and "24m ago" don't fit side by side in narrow columns and end up overlapping.

### Five-row cap

`tom-thumb` is 6 px tall and the right column is 32 px tall — six rows is 36 px, which overflows. We cap the rendered list at 5 (`MAX_COMPONENT_ROWS`). Components are sorted by (severity desc, then a `DISPLAY_PRIORITY` map). Severity always wins, so any component that's degraded shows up; the cap only drops a row when there's no degradation worth showing. The `DISPLAY_PRIORITY` order is API > Code > claude.ai > Console > Cowork > Government, so `Claude for Government` is the one that gets dropped under normal "all operational" conditions — it carries the least signal for a non-government user. The affected-count on the big tile is computed over the full component list, not the truncated visible list, so the number on the tile always reflects the true state.

If Anthropic ever adds a 7th component, it defaults to priority 0 and shows after Government among ops; any non-op severity still bubbles it to the top of the list regardless of priority.

### Component name shortening

`tom-thumb` fits ~7–8 characters across the right column's ~32 px label budget. Anthropic's component names are long ("Claude API (api.anthropic.com)"), so we apply an explicit short-name map for the six current components, with a generic-stripper fallback for any future component:

| Full name | Short |
| --- | --- |
| `claude.ai` | `Chat` |
| `Claude Console (platform.claude.com)` | `Cnsl` |
| `Claude API (api.anthropic.com)` | `API` |
| `Claude Code` | `Code` |
| `Claude Cowork` | `Cowk` |
| `Claude for Government` | `Gov` |

Fallback: strip parenthetical, strip `Claude ` / `Claude for ` prefix, truncate to 7 chars.

## Color palette

Same EPA-derived palette as the sibling Air Quality and InciWeb apps, plus blue for maintenance.

| State | Color | Hex |
| --- | --- | --- |
| operational / none | green | `#00E400` |
| degraded_performance / minor | yellow | `#FFFF00` |
| partial_outage / major | orange | `#FF7E00` |
| major_outage / critical | red | `#FF0000` |
| under_maintenance / maintenance | blue | `#0080FF` |
| unknown | grey | `#888888` |

Foreground (text/digits on the big tile) is black on the green / yellow / orange / grey backgrounds and white on red / blue, matching the AQ app's contrast rules.

## Polling and caching

- `summary.json` is fetched on every render, cached at the Pixlet layer for 60 s.
- The container loop pushes a fresh frame every 600 s (10 min) by default. With the 60 s cache and the 60 s edge cache below it, we hit StatusPage's upstream at most ~6 times/hour — well below any rate limit, and below `s-maxage=10`'s implicit limit.
- During local development (`./scripts/preview.sh`), pixlet's hot-reload may re-render many times per minute. The 60 s cache keeps us from hammering the API.

## Diagnostics

Same shape as the AQ app's diagnostic trace. Every render emits structured `print()` lines that Pixlet routes to stderr; the container's render loop captures both streams into `podman logs`. The trace lines:

- `[fetch] GET <url> ttl=60`
- `[fetch] HTTP=<status> bytes=<n>`
- `[fetch] indicator=<…> description=<…> components=<n> incidents=<n>`
- `[render] indicator=<…> affected=<n> incidents=<n> worst=<name|->`

To replay: `podman logs claudestat | grep -E '^\[(fetch|render)\]'`, slice by the bash loop's `[<iso-ts>] push ok` envelopes.

## Open questions / watch-outs

- **StatusPage itself can go down.** Rare for Atlassian, but possible. The `_error_view` falls back to a grey `STATUS ERR` tile rather than blanking out. Worth eyeballing the failure mode on first deploy.
- **Component count creep.** We cap the rendered list at 5 rows (`MAX_COMPONENT_ROWS`) to keep tom-thumb fitting in the 32 px right-column height; see "Five-row cap" above. The fallback short-namer truncates new names to 7 chars. If Anthropic ever adds enough components that the truncated list misses an important degradation, revisit the cap or move to a 2-column layout.
- **Incident-status update cadence.** During an active incident StatusPage updates the page every few minutes. Our 60 s Pixlet cache plus 10 min push interval means up to ~11 min of staleness on the device — acceptable for ambient awareness, not for incident response. If we ever wanted to use this for incident-response triage, dropping the push interval to 120 s would be reasonable.
- **Multiple incidents.** Today there are two open. We only show the worst-impact one. Could be extended to cycle through several incidents in the animation, but the marquee already needs ~3–4 s per incident to scroll a typical name, so >3 open incidents would exceed the Tidbyt's 15 s slot.
- **TOS.** Atlassian's StatusPage terms allow JSON API consumption for monitoring purposes; the endpoints are explicitly public and CORS-open.

## Stretch ideas

- **Sparkline of "components affected" over the last 24 h** — would need a separate persistence layer (StatusPage's incidents.json doesn't carry per-minute component history). Probably more work than it's worth for a personal device.
- **Different big-tile glyph in the green case** — currently shows `OK`. Could show a tiny Claude wordmark or a checkmark, but `OK` is unambiguous and reads at a glance.
- **Maintenance heads-up.** When a scheduled maintenance starts within ~6 hours, surface its name on the right column in the same way an open incident does. Requires parsing `scheduled_for` timestamps and a third animation frame.
