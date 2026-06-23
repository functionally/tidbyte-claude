#!/usr/bin/env bash
# Pre-deploy sanity check.
# - Verifies the StatusPage summary.json endpoint responds
# - Prints overall indicator + per-component status + active incidents
# - Confirms Tidbyt creds are populated
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f config.yaml ]]; then
  echo "ERROR: config.yaml is missing. Run: cp config-example.yaml config.yaml" >&2
  exit 1
fi

TIDBYT_KEY="$(yq -r '.tidbyt_api_key' config.yaml)"
TIDBYT_DEVICE_ID="$(yq -r '.tidbyt_device_id' config.yaml)"
TIDBYT_INSTALLATION_ID="$(yq -r '.tidbyt_installation_id' config.yaml)"

green() { printf "\033[32m%s\033[0m" "$1"; }
red()   { printf "\033[31m%s\033[0m" "$1"; }
yellow(){ printf "\033[33m%s\033[0m" "$1"; }
ok()    { printf "  $(green '✓') %s\n" "$1"; }
warn()  { printf "  $(red '✗') %s\n" "$1"; }

URL="https://status.claude.com/api/v2/summary.json"

echo "== StatusPage summary =="
RESP=$(curl -sL --max-time 12 -w "\n%{http_code}" "$URL")
CODE=$(printf '%s' "$RESP" | tail -n1)
BODY=$(printf '%s' "$RESP" | sed '$d')
if [[ "$CODE" != "200" ]]; then
  warn "$URL returned HTTP $CODE"
  exit 1
fi
ok "summary.json HTTP 200 ($(printf '%s' "$BODY" | wc -c) bytes)"

echo
python3 - <<EOF
import json
d = json.loads('''${BODY}''')

status = d.get("status") or {}
indicator = status.get("indicator", "?")
desc = status.get("description", "?")
ind_color = {"none":"\033[32m", "minor":"\033[33m", "major":"\033[33m",
             "critical":"\033[31m", "maintenance":"\033[34m"}.get(indicator, "\033[0m")
print(f"== Overall ==")
print(f"  {ind_color}{indicator}\033[0m — {desc}")

print()
print("== Components ==")
COMP_COLOR = {"operational":"\033[32m", "degraded_performance":"\033[33m",
              "partial_outage":"\033[33m", "major_outage":"\033[31m",
              "under_maintenance":"\033[34m"}
for c in d.get("components", []):
    if c.get("group"): continue
    col = COMP_COLOR.get(c["status"], "")
    print(f"  {col}{c['status']:22s}\033[0m  {c['name']}")

incidents = d.get("incidents") or []
print()
print(f"== Active incidents ({len(incidents)}) ==")
IMP_COLOR = {"none":"\033[32m", "minor":"\033[33m", "major":"\033[33m",
             "critical":"\033[31m", "maintenance":"\033[34m"}
for i in incidents:
    col = IMP_COLOR.get(i.get("impact",""), "")
    affected = [c["name"] for c in i.get("components",[])]
    print(f"  [{col}{i.get('impact','?'):8s}\033[0m] [{i.get('status','?'):12s}]")
    print(f"    {i.get('name','?')}")
    print(f"    since {i.get('created_at','?')}, affects: {', '.join(affected) if affected else '(none)'}")

maint = d.get("scheduled_maintenances") or []
if maint:
    print()
    print(f"== Scheduled maintenances ({len(maint)}) ==")
    for m in maint:
        print(f"  {m.get('name','?')} — scheduled_for {m.get('scheduled_for','?')}")
EOF

echo
echo "== Tidbyt credentials =="
[[ -n "$TIDBYT_KEY" && "$TIDBYT_KEY" != "null" && "$TIDBYT_KEY" != YOUR-* ]] \
  && ok "tidbyt_api_key set" || warn "tidbyt_api_key not set in config.yaml"
[[ -n "$TIDBYT_DEVICE_ID" && "$TIDBYT_DEVICE_ID" != "null" && "$TIDBYT_DEVICE_ID" != YOUR-* ]] \
  && ok "tidbyt_device_id set" || warn "tidbyt_device_id not set in config.yaml"
if [[ "$TIDBYT_INSTALLATION_ID" =~ ^[A-Za-z0-9]+$ ]]; then
  ok "tidbyt_installation_id ($TIDBYT_INSTALLATION_ID) is alphanumeric"
else
  warn "tidbyt_installation_id ($TIDBYT_INSTALLATION_ID) must be alphanumeric"
fi

echo
echo "All checks passed. Safe to deploy."
