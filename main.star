"""Claude status for Tidbyt.

Polls status.claude.com (Atlassian StatusPage) and renders a
glanceable overview: overall indicator on the left tile, per-component
dots on the right column. When an incident is open, the right column
animates between the component grid and a summary of the worst-impact
open incident.

See ./design-notes.md for the layout, polling cadence, and color
choices.
"""

load("render.star", "render")
load("http.star", "http")
load("schema.star", "schema")
load("time.star", "time")

SUMMARY_URL = "https://status.claude.com/api/v2/summary.json"

# StatusPage's CDN caches summary.json at s-maxage=10 s. 60 s is a polite
# multiplier on top of that — the Tidbyt render loop runs every 10 min
# anyway, so this TTL mainly protects against the device's preview re-
# renders during local development.
SUMMARY_TTL_S = 60

# Overall page indicator -> (bg, fg) for the big tile.
INDICATOR_COLORS = {
    "none": ("#00E400", "#000000"),
    "minor": ("#FFFF00", "#000000"),
    "major": ("#FF7E00", "#000000"),
    "critical": ("#FF0000", "#FFFFFF"),
    "maintenance": ("#0080FF", "#FFFFFF"),
}

# Per-component status -> dot color.
COMPONENT_COLORS = {
    "operational": "#00E400",
    "under_maintenance": "#0080FF",
    "degraded_performance": "#FFFF00",
    "partial_outage": "#FF7E00",
    "major_outage": "#FF0000",
}

# Severity rank for choosing the worst component (used to sort the
# right-column list) and to count "affected" components.
SEVERITY_RANK = {
    "operational": 0,
    "under_maintenance": 1,
    "degraded_performance": 2,
    "partial_outage": 3,
    "major_outage": 4,
}

# Incident-impact rank for picking the worst-impact open incident.
IMPACT_RANK = {"none": 0, "maintenance": 0, "minor": 1, "major": 2, "critical": 3}
IMPACT_COLOR = {
    "none": "#00E400",
    "maintenance": "#0080FF",
    "minor": "#FFFF00",
    "major": "#FF7E00",
    "critical": "#FF0000",
}


UNKNOWN_COLOR = "#888888"
FG_WHITE = "#FFFFFF"
FG_BLACK = "#000000"
LABEL_COLOR = "#AAAAAA"

# Known component name -> short label. Keeps the right-column rows under
# the ~32 px label budget. Anything not in this map falls back to a
# generic stripper + truncation so new components don't break the layout.
SHORT_NAMES = {
    "claude.ai": "Chat",
    "Claude Console (platform.claude.com)": "Cnsl",
    "Claude API (api.anthropic.com)": "API",
    "Claude Code": "Code",
    "Claude Cowork": "Cowk",
    "Claude for Government": "Gov",
}

# Display priority — higher is more prominent. Used as a secondary sort
# key after severity, so the 5 highest-priority components survive the
# cap below when nothing's wrong. Anthropic adds a 7th component → it
# defaults to priority 0 and shows last among ops, but any non-op
# severity bubbles it back to the top.
DISPLAY_PRIORITY = {
    "Claude API (api.anthropic.com)": 6,
    "Claude Code": 5,
    "claude.ai": 4,
    "Claude Console (platform.claude.com)": 3,
    "Claude Cowork": 2,
    "Claude for Government": 1,
}

# tom-thumb is 6 px tall; 6 rows × 6 px = 36 px and overflows the 32 px
# right-column height. Cap to 5 — the dropped row is the lowest-priority
# operational component (Gov in practice).
MAX_COMPONENT_ROWS = 5

# Two-frame animation: the display alternates between the component
# grid and the active-incident panel. Pixlet renders Animation children
# at 20 fps (50 ms each), so these are dwell counts in 50 ms units.
# Total cycle is 14.5 s to fit the Tidbyt's ~15 s app slot in one play
# (shorter cycles loop multiple times per slot, which is distracting
# when the content is static). Incident frame takes 70% of the cycle.
GRID_FRAMES = 87
INCIDENT_FRAMES = 203

# Incident frame: up to 4 full-width horizontal-marquee rows stacked
# above a 7 px colored status bar at the bottom (same indicator-color
# bar the AQ app uses for the smoke band). Each marquee row is 64 × 6
# (tom-thumb glyph height), so 4 * 6 + 1 px gap + 7 px bar = 32 px.
INCIDENT_ROWS_MAX = 4
INCIDENT_ROW_W = 64
INCIDENT_ROW_H = 6
STATUS_BAR_H = 7

def fetch_summary():
    print("[fetch] GET %s ttl=%d" % (SUMMARY_URL, SUMMARY_TTL_S))
    r = http.get(SUMMARY_URL, ttl_seconds = SUMMARY_TTL_S)
    print("[fetch] HTTP=%d bytes=%d" % (r.status_code, len(r.body())))
    if r.status_code != 200:
        return None
    body = r.json()
    if body == None:
        return None
    status = body.get("status") or {}
    print("[fetch] indicator=%s description=%s components=%d incidents=%d" % (
        status.get("indicator", "?"),
        status.get("description", "?"),
        len(body.get("components", [])),
        len(body.get("incidents", [])),
    ))
    return body

def _short_name(name):
    if name in SHORT_NAMES:
        return SHORT_NAMES[name]
    i = name.find("(")
    if i >= 0:
        name = name[:i].strip()
    if name.startswith("Claude for "):
        name = name[11:]
    elif name.startswith("Claude "):
        name = name[7:]
    if len(name) > 7:
        name = name[:7]
    return name.strip()

def _component_row(comp):
    color = COMPONENT_COLORS.get(comp["status"], UNKNOWN_COLOR)
    return render.Row(
        cross_align = "center",
        children = [
            render.Padding(
                pad = (0, 0, 2, 0),
                child = render.Box(width = 4, height = 4, color = color),
            ),
            render.Text(_short_name(comp["name"]), color = FG_WHITE, font = "tom-thumb"),
        ],
    )

def _component_grid(components):
    return render.Padding(
        pad = (2, 0, 0, 0),
        child = render.Column(
            expanded = True,
            main_align = "space_evenly",
            children = [_component_row(c) for c in components],
        ),
    )

def _format_age(seconds):
    """Compact duration: '<1m', 'Nm', 'Nh', or 'Nd'. Max 3 chars + suffix."""
    if seconds == None or seconds < 60:
        return "<1m"
    minutes = int(seconds / 60)
    if minutes < 60:
        return str(minutes) + "m"
    hours = int(minutes / 60)
    if hours < 24:
        return str(hours) + "h"
    days = int(hours / 24)
    return str(days) + "d"

def _parse_iso(s):
    """StatusPage uses RFC3339 with ms ('2026-06-23T14:19:06.033Z').
    Slice off the fractional seconds since Starlark's time.parse_time
    is strict about the format string matching exactly."""
    if not s or len(s) < 19:
        return None
    return time.parse_time(s[:19] + "Z", format = "2006-01-02T15:04:05Z")

def _incident_age_s(inc):
    t = _parse_iso(inc.get("created_at", ""))
    if t == None:
        return None
    return time.now().unix - t.unix

def _big_tile(indicator, affected_count, oldest_age_s):
    bg, fg = INDICATOR_COLORS.get(indicator, ("#444444", FG_WHITE))
    if indicator == "none" or indicator == None:
        body = render.Column(
            expanded = True,
            main_align = "center",
            cross_align = "center",
            children = [render.Text("OK", color = fg, font = "10x20")],
        )
    else:
        count_str = str(affected_count) if affected_count > 0 else "!"
        big_font = "10x20" if len(count_str) <= 2 else "6x13"
        children = [render.Text(count_str, color = fg, font = big_font)]
        if oldest_age_s != None:
            children.append(render.Text(_format_age(oldest_age_s), color = fg, font = "tom-thumb"))
        body = render.Column(
            expanded = True,
            main_align = "center",
            cross_align = "center",
            children = children,
        )
    return render.Box(width = 28, height = 32, color = bg, child = body)

def _normalize_title(text):
    """Map typographic Unicode to ASCII so the BDF tom-thumb font has a
    glyph for every char and Starlark's byte-based len() matches the
    visual char count (matters when text contains U+2019 etc.)."""
    if text == None:
        return ""
    return (text
        .replace("’", "'")
        .replace("‘", "'")
        .replace("“", "\"")
        .replace("”", "\"")
        .replace("–", "-")
        .replace("—", "-")
        .replace("…", "..."))

def _top_incidents(incidents, n):
    """Sort open incidents by impact (worst first), then by recency
    (newest first as tiebreaker), and take the first n."""
    return sorted(incidents, key = lambda i: (
        -IMPACT_RANK.get(i.get("impact", ""), -1),
        # ISO timestamps sort lexicographically, so negating via reverse
        # is awkward — invert by comparing to a max sentinel.
        "~" if not i.get("created_at") else "",
        -1 * int(_incident_age_s(i) or 0),
    ))[:n]

def _incident_row(inc):
    """One marquee row for an incident, colored by its impact."""
    impact = inc.get("impact", "?")
    color = IMPACT_COLOR.get(impact, FG_WHITE)
    name = _normalize_title(inc.get("name", "?"))
    return render.Box(
        width = INCIDENT_ROW_W,
        height = INCIDENT_ROW_H,
        child = render.Marquee(
            width = INCIDENT_ROW_W,
            child = render.Text(name, color = color, font = "tom-thumb"),
        ),
    )

def _blank_row():
    return render.Box(width = INCIDENT_ROW_W, height = INCIDENT_ROW_H)

def _incident_marquees(incidents):
    """Up to INCIDENT_ROWS_MAX full-width incident marquees stacked
    top-down, with blank rows padding the bottom when fewer incidents
    exist. Worst-impact incident occupies row 0 so a top-down scan
    hits it first."""
    n = len(incidents)
    if n > INCIDENT_ROWS_MAX:
        n = INCIDENT_ROWS_MAX
    rows = []
    for i in range(n):
        rows.append(_incident_row(incidents[i]))
    for _ in range(INCIDENT_ROWS_MAX - n):
        rows.append(_blank_row())
    return render.Column(children = rows)

def _status_bar(indicator, affected_count, oldest_age_s):
    """Bottom band echoing the frame-1 big tile: indicator-color
    background, contrast-flipped foreground, '<age> ago  <N> hit' text."""
    bg, fg = INDICATOR_COLORS.get(indicator, ("#444444", FG_WHITE))
    if oldest_age_s != None:
        text = _format_age(oldest_age_s) + " ago  " + str(affected_count) + " hit"
    else:
        text = str(affected_count) + " hit"
    return render.Box(
        width = 64,
        height = STATUS_BAR_H,
        color = bg,
        child = render.Padding(
            pad = (2, 1, 0, 0),
            child = render.Text(text, color = fg, font = "tom-thumb"),
        ),
    )

def _affected_count(components):
    n = 0
    for c in components:
        if SEVERITY_RANK.get(c["status"], 0) > 0:
            n += 1
    return n

def _worst_incident(incidents):
    if len(incidents) == 0:
        return None
    worst = incidents[0]
    worst_rank = IMPACT_RANK.get(worst.get("impact", ""), -1)
    for i in incidents[1:]:
        r = IMPACT_RANK.get(i.get("impact", ""), -1)
        if r > worst_rank:
            worst_rank = r
            worst = i
    return worst

def _error_view(msg):
    return render.Root(
        child = render.Box(
            color = "#222222",
            child = render.Column(
                expanded = True,
                main_align = "center",
                cross_align = "center",
                children = [render.Text(msg, color = FG_WHITE, font = "tom-thumb")],
            ),
        ),
    )

def main(config):
    summary = fetch_summary()
    if summary == None:
        return _error_view("STATUS ERR")

    status = summary.get("status") or {}
    indicator = status.get("indicator", "none")

    # Drop component-group rows; group=true entries are headers with no
    # status of their own. Claude's page is flat today but the API
    # supports groups.
    components = [c for c in (summary.get("components") or []) if not c.get("group", False)]
    components = sorted(components, key = lambda c: (
        -SEVERITY_RANK.get(c["status"], 0),
        -DISPLAY_PRIORITY.get(c.get("name", ""), 0),
        c.get("name", ""),
    ))
    components_shown = components[:MAX_COMPONENT_ROWS]

    incidents = summary.get("incidents") or []
    worst = _worst_incident(incidents)
    oldest_age = _incident_age_s(worst) if worst != None else None
    affected = _affected_count(components)
    top_incs = _top_incidents(incidents, INCIDENT_ROWS_MAX)

    print("[render] indicator=%s affected=%d incidents=%d shown=%d worst=%s" % (
        indicator, affected, len(incidents), len(top_incs),
        worst.get("name", "-") if worst else "-",
    ))

    big = _big_tile(indicator, affected, oldest_age)
    grid = _component_grid(components_shown)
    grid_view = render.Row(expanded = True, children = [big, grid])

    if len(top_incs) == 0:
        body = grid_view
    else:
        # Frame 1: severity tile + component grid. Frame 2: drop the
        # left tile, use the full width for up to INCIDENT_ROWS_MAX
        # incident marquees stacked over a colored status bar at the
        # bottom. The bar carries the severity color and age + hit
        # count so the indicator signal still reads on frame 2.
        grid_frame = render.Box(width = 64, height = 32, color = "#000000", child = grid_view)
        inc_view = render.Column(
            expanded = True,
            main_align = "space_between",
            children = [
                _incident_marquees(top_incs),
                _status_bar(indicator, affected, oldest_age),
            ],
        )
        inc_frame = render.Box(width = 64, height = 32, color = "#000000", child = inc_view)
        body = render.Animation(
            children = [grid_frame] * GRID_FRAMES + [inc_frame] * INCIDENT_FRAMES,
        )

    return render.Root(
        child = render.Box(color = "#000000", child = body),
    )

def get_schema():
    return schema.Schema(version = "1", fields = [])
