#!/bin/bash
# statusline.sh – Claude Code status bar script
# Reads session JSON from stdin (model, context, cost, tokens)
# Reads rate limit cache from .usage_cache (written by rate-proxy.js or usage.sh)
# Tracks token deltas in .statusline_state

CACHE_FILE="$HOME/.local/bin/.usage_cache"
STATE_FILE="$HOME/.local/bin/.statusline_state"
CACHE_MAX_AGE=300       # 5 minutes – trigger background refresh
CACHE_STALE_AGE=1800    # 30 minutes – data unreliable, show warning

# --- Read session data from stdin ---
INPUT=$(cat)

MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "?"' 2>/dev/null)
CTX_USED=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' 2>/dev/null | cut -d. -f1)
IN_TOK=$(echo "$INPUT" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null)
OUT_TOK=$(echo "$INPUT" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null)

# --- Turn tracking ---
# Turn = full user interaction (question → all iterations → done)
# New turn starts after long idle (6s+), meaning user sent a new message
# LAST_TURN = cost of the previous completed turn
PREV_IN=0 PREV_OUT=0 IDLE_TICKS=0
TURN_START_IN=0 TURN_START_OUT=0
LAST_TURN=0
NEW_TURN_THRESHOLD=3  # ticks idle before new turn (3 × 2s = 6s)
if [ -f "$STATE_FILE" ]; then
  source "$STATE_FILE" 2>/dev/null
  PREV_IN=${PREV_IN_TOK:-0}
  PREV_OUT=${PREV_OUT_TOK:-0}
  IDLE_TICKS=${IDLE_TICKS:-0}
  TURN_START_IN=${TURN_START_IN:-0}
  TURN_START_OUT=${TURN_START_OUT:-0}
  LAST_TURN=${LAST_TURN:-0}
fi

TICK_DELTA=$(( (IN_TOK - PREV_IN) + (OUT_TOK - PREV_OUT) ))

# Negative delta = new session (reset all tracking)
if [ "$TICK_DELTA" -lt 0 ] 2>/dev/null; then
  TURN_START_IN=$IN_TOK
  TURN_START_OUT=$OUT_TOK
  LAST_TURN=0
  IDLE_TICKS=0
elif [ "$TICK_DELTA" -eq 0 ] 2>/dev/null; then
  IDLE_TICKS=$(( IDLE_TICKS + 1 ))
elif [ "$IDLE_TICKS" -gt 0 ] 2>/dev/null; then
  # Was idle, now active again
  if [ "$IDLE_TICKS" -ge "$NEW_TURN_THRESHOLD" ] 2>/dev/null; then
    # Long idle → new turn. Save previous turn cost.
    LAST_TURN=$(( (PREV_IN - TURN_START_IN) + (PREV_OUT - TURN_START_OUT) ))
    TURN_START_IN=$PREV_IN
    TURN_START_OUT=$PREV_OUT
  fi
  IDLE_TICKS=0
fi

TURN_TOTAL=$(( (IN_TOK - TURN_START_IN) + (OUT_TOK - TURN_START_OUT) ))

# Save state
cat > "$STATE_FILE" <<STATE
PREV_IN_TOK=$IN_TOK
PREV_OUT_TOK=$OUT_TOK
IDLE_TICKS=$IDLE_TICKS
TURN_START_IN=$TURN_START_IN
TURN_START_OUT=$TURN_START_OUT
LAST_TURN=$LAST_TURN
STATE

# --- Token formatting (1234 → 1.2k, 12345 → 12k, 1234567 → 1.2M) ---
fmt_tok() {
  local n=$1
  if [ "$n" -ge 1000000 ] 2>/dev/null; then
    awk "BEGIN {printf \"%.1fM\", $n/1000000}" 2>/dev/null
  elif [ "$n" -ge 1000 ] 2>/dev/null; then
    awk "BEGIN {printf \"%.1fk\", $n/1000}" 2>/dev/null
  else
    echo "$n"
  fi
}

# Context window bar (10 chars)
ctx_bar() {
  local pct=$1 width=10
  local filled=$((pct * width / 100))
  [ "$filled" -gt "$width" ] && filled=$width
  local i=0 out=""
  while [ $i -lt $width ]; do
    if [ $i -lt "$filled" ]; then out="${out}▓"; else out="${out}░"; fi
    i=$((i + 1))
  done
  echo -n "$out"
}

ctx_color() {
  if [ "$1" -lt 50 ] 2>/dev/null; then echo -n "\033[32m"
  elif [ "$1" -lt 80 ] 2>/dev/null; then echo -n "\033[33m"
  else echo -n "\033[31m"
  fi
}

# --- Read rate limit cache ---
UTIL_5H="?" UTIL_7D="?" STATUS="?"
RATE_ERROR=""
if [ -f "$CACHE_FILE" ]; then
  source "$CACHE_FILE" 2>/dev/null
  NOW=$(date +%s)
  CACHE_AGE=$(( NOW - ${TIMESTAMP:-0} ))
  # Auth error or other failure in cache
  if [ "$STATUS" = "auth_error" ] || [ "$STATUS" = "no_headers" ]; then
    RATE_ERROR="TOKEN"
    UTIL_5H="" UTIL_7D=""
    if [ "$CACHE_AGE" -gt "$CACHE_MAX_AGE" ]; then
      ("$HOME/.local/bin/usage.sh" > /dev/null 2>&1 &)
    fi
  elif [ "$CACHE_AGE" -gt "$CACHE_STALE_AGE" ]; then
    # Cache too old – unreliable, try to refresh
    RATE_ERROR="STALE"
    UTIL_5H="" UTIL_7D=""
    ("$HOME/.local/bin/usage.sh" > /dev/null 2>&1 &)
  elif [ "$CACHE_AGE" -gt "$CACHE_MAX_AGE" ]; then
    ("$HOME/.local/bin/usage.sh" > /dev/null 2>&1 &)
  fi
else
  ("$HOME/.local/bin/usage.sh" > /dev/null 2>&1 &)
  UTIL_5H="" UTIL_7D=""
  RATE_ERROR="..."
fi

NC="\033[0m"
DIM="\033[2m"

# Remaining time until reset (seconds → "1h23m" / "2d5h")
fmt_remaining() {
  local reset=$1
  if [ -z "$reset" ] || [ "$reset" = "0" ]; then echo "?"; return; fi
  local now=$(date +%s)
  local diff=$(( reset - now ))
  if [ "$diff" -le 0 ] 2>/dev/null; then echo "now"; return; fi
  local d=$(( diff / 86400 )) h=$(( (diff % 86400) / 3600 )) m=$(( (diff % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then echo "${d}d${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h${m}m"
  else echo "${m}m"
  fi
}

# Pace: actual_usage / expected_usage (time-proportional)
# < 1.0 = under budget (good), > 1.0 = over budget (bad)
calc_pace() {
  local util=$1 reset=$2 window=$3
  if [ -z "$util" ] || [ "$util" = "?" ] || [ "$util" = "..." ] || [ -z "$reset" ] || [ "$reset" = "0" ]; then echo "?"; return; fi
  local now=$(date +%s)
  local remaining=$(( reset - now ))
  [ "$remaining" -le 0 ] && remaining=0
  local elapsed=$(( window - remaining ))
  [ "$elapsed" -le 0 ] && { echo "?"; return; }
  awk "BEGIN {
    expected = $elapsed / $window
    if (expected < 0.01) { printf \"?\"; exit }
    printf \"%.1f\", $util / expected
  }" 2>/dev/null || echo "?"
}

pace_color() {
  local pace=$1
  if [ "$pace" = "?" ]; then echo -n ""; return; fi
  local lvl=$(awk "BEGIN { if ($pace < 1.0) print 0; else if ($pace < 1.3) print 1; else print 2 }" 2>/dev/null)
  case "$lvl" in
    0) echo -n "\033[32m";;
    1) echo -n "\033[33m";;
    2) echo -n "\033[31m";;
  esac
}

pace_icon() {
  local pace=$1
  if [ "$pace" = "?" ]; then echo -n ""; return; fi
  local lvl=$(awk "BEGIN { if ($pace < 0.8) print 0; else if ($pace < 1.0) print 1; else if ($pace < 1.3) print 2; else print 3 }" 2>/dev/null)
  case "$lvl" in
    0) echo -n "\033[32m▼${NC}";;
    1) echo -n "\033[32m✓${NC}";;
    2) echo -n "\033[33m▲${NC}";;
    3) echo -n "\033[31m▲${NC}";;
  esac
}

u2p() {
  if [ "$1" = "?" ] || [ "$1" = "..." ] || [ -z "$1" ]; then echo "$1"
  else awk "BEGIN {printf \"%.0f\", $1 * 100}" 2>/dev/null || echo "?"
  fi
}

SEP="${DIM}│${NC}"

LAST_FMT=""
if [ "$TURN_TOTAL" -gt 0 ] 2>/dev/null; then
  LAST_FMT="  ${SEP}  💬 $(fmt_tok $TURN_TOTAL)"
fi

# Rate limit section: warning on error, normal display otherwise
if [ -n "$RATE_ERROR" ]; then
  if [ "$RATE_ERROR" = "TOKEN" ]; then
    RATE_FMT="  ${SEP}  \033[33m⚠ token expired – run usage.sh\033[0m"
  elif [ "$RATE_ERROR" = "STALE" ]; then
    RATE_FMT="  ${SEP}  \033[33m⚠ rate limit stale\033[0m"
  else
    RATE_FMT="  ${SEP}  🔋 ..."
  fi
else
  PCT_5H=$(u2p "$UTIL_5H")
  PCT_7D=$(u2p "$UTIL_7D")
  REM_5H=$(fmt_remaining "${RESET_5H:-0}")
  REM_7D=$(fmt_remaining "${RESET_7D:-0}")
  PACE_5H=$(calc_pace "$UTIL_5H" "${RESET_5H:-0}" 18000)
  PACE_7D=$(calc_pace "$UTIL_7D" "${RESET_7D:-0}" 604800)
  RATE_FMT="  ${SEP}  🔋 $(pace_color $PACE_5H)${PCT_5H}%${NC}$(pace_icon $PACE_5H) ${DIM}${REM_5H}${NC} · $(pace_color $PACE_7D)${PCT_7D}%${NC}$(pace_icon $PACE_7D) ${DIM}${REM_7D}${NC}"
fi

echo -e "🤖 ${MODEL}  🧠 $(ctx_color $CTX_USED)$(ctx_bar $CTX_USED) ${CTX_USED}%${NC}${RATE_FMT}${LAST_FMT}"
