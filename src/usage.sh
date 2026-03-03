#!/bin/bash
# usage.sh – Claude rate limit checker & cache writer
# Reads OAuth token from ~/.claude/.credentials.json (Claude Max)
# or uses ANTHROPIC_API_KEY environment variable (API users)
# Writes cache file for statusline.sh

CRED_FILE="$HOME/.claude/.credentials.json"
CACHE_FILE="$HOME/.local/bin/.usage_cache"

# --- Token resolution ---
if [ -z "$ANTHROPIC_API_KEY" ]; then
  if [ -f "$CRED_FILE" ]; then
    TOKEN=$(jq -r '.claudeAiOauth.accessToken' "$CRED_FILE" 2>/dev/null)
    if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
      echo "Error: Could not read access token from $CRED_FILE"
      exit 1
    fi
  else
    echo "Error: No ANTHROPIC_API_KEY set and $CRED_FILE not found"
    exit 1
  fi
else
  TOKEN="$ANTHROPIC_API_KEY"
fi

# --- API call (haiku = cheapest model, we only need the headers) ---
RESPONSE=$(curl -s -D- -o /dev/null "https://api.anthropic.com/v1/messages" \
  -H "x-api-key: $TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}' 2>/dev/null)

# --- Error handling ---
if echo "$RESPONSE" | grep -q "HTTP.*401\|HTTP.*403"; then
  echo "Error: Authentication failed – token expired or invalid"
  exit 1
fi

if ! echo "$RESPONSE" | grep -qi "ratelimit"; then
  echo "Error: No rate limit headers in response"
  echo "$RESPONSE" | head -20
  exit 1
fi

# --- Header parsing ---
parse_header() {
  echo "$RESPONSE" | grep -i "anthropic-ratelimit-$1:" | head -1 | sed 's/.*: //' | tr -d '\r\n'
}

# Unified rate limit values
STATUS=$(parse_header "unified-status")
STATUS_5H=$(parse_header "unified-5h-status")
UTIL_5H=$(parse_header "unified-5h-utilization")
RESET_5H=$(parse_header "unified-5h-reset")
STATUS_7D=$(parse_header "unified-7d-status")
UTIL_7D=$(parse_header "unified-7d-utilization")
RESET_7D=$(parse_header "unified-7d-reset")
FALLBACK=$(parse_header "unified-fallback-percentage")
OVERAGE=$(parse_header "unified-overage-status")

# --- Write cache file (read by statusline.sh) ---
cat > "$CACHE_FILE" <<CACHE
TIMESTAMP=$(date +%s)
STATUS=$STATUS
STATUS_5H=$STATUS_5H
UTIL_5H=$UTIL_5H
RESET_5H=$RESET_5H
STATUS_7D=$STATUS_7D
UTIL_7D=$UTIL_7D
RESET_7D=$RESET_7D
CACHE

# --- Helper: awk-based math (bc not always available, e.g. on Windows/Git Bash) ---
calc() { awk "BEGIN {printf \"%.0f\", $1}" 2>/dev/null; }

# Color based on utilization (0.0–1.0 scale)
color_util() {
  local pct=$(calc "$1 * 100")
  if [ -z "$pct" ]; then echo "\033[0m"
  elif [ "$pct" -lt 50 ] 2>/dev/null; then echo "\033[32m"
  elif [ "$pct" -lt 80 ] 2>/dev/null; then echo "\033[33m"
  else echo "\033[31m"
  fi
}

# Status icon
status_icon() {
  case "$1" in
    allowed) echo "✅";;
    throttled) echo "⚠️";;
    rejected) echo "❌";;
    *) echo "❓";;
  esac
}

# Progress bar (20 chars wide)
bar() {
  local util="$1"
  local width=20
  local filled=$(calc "$util * $width")
  [ -z "$filled" ] || [ "$filled" -lt 0 ] 2>/dev/null && filled=0
  local i=0
  local out=""
  while [ $i -lt $width ]; do
    if [ $i -lt "$filled" ] 2>/dev/null; then
      out="${out}█"
    else
      out="${out}░"
    fi
    i=$((i + 1))
  done
  echo -n "$out"
}

# Format reset timestamp to readable date
fmt_reset() {
  if [ -n "$1" ]; then
    date -d "@$1" "+%m/%d %H:%M" 2>/dev/null || date -r "$1" "+%m/%d %H:%M" 2>/dev/null || echo "$1"
  fi
}

NC="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"

PCT_5H=$(calc "$UTIL_5H * 100")
PCT_7D=$(calc "$UTIL_7D * 100")
FREE_5H=$(calc "(1 - $UTIL_5H) * 100")
FREE_7D=$(calc "(1 - $UTIL_7D) * 100")

echo ""
echo -e "${BOLD}═══ Claude Usage ═══${NC}  $(status_icon $STATUS)"
echo ""
echo -e "  ${BOLD}5h window${NC}  $(status_icon $STATUS_5H)  resets: $(fmt_reset $RESET_5H)"
echo -e "  $(color_util $UTIL_5H)  $(bar $UTIL_5H)  ${PCT_5H}%% used  (${FREE_5H}%% free)${NC}"
echo ""
echo -e "  ${BOLD}7d window${NC}  $(status_icon $STATUS_7D)  resets: $(fmt_reset $RESET_7D)"
echo -e "  $(color_util $UTIL_7D)  $(bar $UTIL_7D)  ${PCT_7D}%% used  (${FREE_7D}%% free)${NC}"
echo ""
