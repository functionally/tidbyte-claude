# Claude Status — Tidbyt app

A Pixlet/Starlark Tidbyt app that polls [status.claude.com](https://status.claude.com) and renders an at-a-glance overview of Claude's overall status, per-component health, and any open incident.

- **Left tile (28×32):** big "OK" (when everything is green) or the count of affected components with the age of the worst-impact open incident below. Tile background is the StatusPage overall `status.indicator` color (green / yellow / orange / red / blue).
- **Right column (36×32):** up to five rows of (colored dot + short component label). Capped at five because `tom-thumb` × 6 rows overflows the 32 px height; the dropped row is the lowest-priority operational component (`Claude for Government` under current conditions), but any degraded component is always shown regardless of priority.
- **When an incident is open:** the whole display alternates between the layout above (~5 s) and a full-width incident view (~5 s) — marquee'd incident name, the colored impact word, age, and affected-component count. The big severity tile is dropped on the incident frame since the impact word is already colored by the same scheme; the full 64 px of width lets the marquee breathe.

Data source: `GET https://status.claude.com/api/v2/summary.json` (Atlassian StatusPage, public, unauthenticated, CORS open). Cached at the Pixlet layer for 60 s.

## Quickstart

```bash
nix develop                                # drops you into the dev shell
cp config-example.yaml config.yaml         # fill in Tidbyt creds
./scripts/check.sh                         # verify upstream + creds
./scripts/preview.sh                       # browser preview at http://localhost:8080
./scripts/render.sh                        # writes out.webp
./scripts/deploy.sh                        # one-shot push to your Tidbyt
```

For the always-on push daemon:

```bash
./scripts/build-container.sh               # builds the OCI image and loads it into podman
./scripts/run-container.sh -d              # detached, restarts forever
# or
podman kube play --replace claudestat.yaml
```

## Configuration

`config.yaml` carries only Tidbyt push creds — there is no upstream API key, since StatusPage's summary endpoint is public.

| Field | What |
| --- | --- |
| `tidbyt_api_key` | From `pixlet auth` or the Tidbyt account page |
| `tidbyt_device_id` | From `pixlet devices` |
| `tidbyt_installation_id` | Any short alphanumeric tag — uniquely identifies this app's slot on the device |

See `config-example.yaml` for a template.

## How it picks the dominant signal

- The big tile color is driven by the page-wide `status.indicator` field — `none` / `minor` / `major` / `critical` / `maintenance`. This is what `https://status.claude.com` itself uses for the top-of-page banner.
- The "affected" count on the tile is the number of components whose `status` is anything other than `operational`.
- The animated incident panel picks the worst-impact open incident (`critical` > `major` > `minor`) — when there are multiple, only the worst is shown. The full list is always available at status.claude.com.

## Design notes

See [design-notes.md](./design-notes.md) for the API surface, color palette, layout decisions, and known watch-outs.
