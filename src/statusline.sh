#!/bin/bash
# statusline.sh – Claude Code status bar script
# Reads session JSON from stdin (model, context, cost, tokens)
# Reads rate limit cache from .usage_cache (written by usage.sh)
# Tracks token deltas in .statusline_state

CACHE_FILE="$HOME/.local/bin/.usage_cache"
STATE_FILE="$HOME/.local/bin/.statusline_state"
CACHE_MAX_AGE=300  # 5 minutes

# --- Read session data from stdin ---
INPUT=$(cat)

MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "?"' 2>/dev/null)
CTX_USED=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' 2>/dev/null | cut -d. -f1)
IN_TOK=$(echo "$INPUT" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null)
OUT_TOK=$(echo "$INPUT" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null)

# --- Turn-based token tracking ---
# Detects idle→active transitions to mark turn boundaries.
# "turn:" shows cumulative tokens since the current turn started.
PREV_IN=0 PREV_OUT=0 WAS_IDLE=0
TURN_START_IN=0 TURN_START_OUT=0
if [ -f "$STATE_FILE" ]; then
  source "$STATE_FILE" 2>/dev/null
  PREV_IN=${PREV_IN_TOK:-0}
  PREV_OUT=${PREV_OUT_TOK:-0}
  WAS_IDLE=${WAS_IDLE:-0}
  TURN_START_IN=${TURN_START_IN:-0}
  TURN_START_OUT=${TURN_START_OUT:-0}
fi

TICK_DELTA=$(( (IN_TOK - PREV_IN) + (OUT_TOK - PREV_OUT) ))

# Negative delta = new session (reset all tracking)
if [ "$TICK_DELTA" -lt 0 ] 2>/dev/null; then
  TURN_START_IN=$IN_TOK
  TURN_START_OUT=$OUT_TOK
  WAS_IDLE=0
elif [ "$TICK_DELTA" -eq 0 ] 2>/dev/null; then
  # No change since last refresh → idle
  WAS_IDLE=1
elif [ "$WAS_IDLE" -eq 1 ] 2>/dev/null; then
  # Was idle, now tokens changed → new turn started
  TURN_START_IN=$PREV_IN
  TURN_START_OUT=$PREV_OUT
  WAS_IDLE=0
fi

TURN_IN=$(( IN_TOK - TURN_START_IN ))
TURN_OUT=$(( OUT_TOK - TURN_START_OUT ))
TURN_TOTAL=$(( TURN_IN + TURN_OUT ))

# Save state
cat > "$STATE_FILE" <<STATE
PREV_IN_TOK=$IN_TOK
PREV_OUT_TOK=$OUT_TOK
WAS_IDLE=$WAS_IDLE
TURN_START_IN=$TURN_START_IN
TURN_START_OUT=$TURN_START_OUT
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
if [ -f "$CACHE_FILE" ]; then
  source "$CACHE_FILE" 2>/dev/null
  NOW=$(date +%s)
  CACHE_AGE=$(( NOW - ${TIMESTAMP:-0} ))
  if [ "$CACHE_AGE" -gt "$CACHE_MAX_AGE" ]; then
    ("$HOME/.local/bin/usage.sh" > /dev/null 2>&1 &)
  fi
else
  ("$HOME/.local/bin/usage.sh" > /dev/null 2>&1 &)
  UTIL_5H="..." UTIL_7D="..."
fi

NC="\033[0m"
DIM="\033[2m"

u2p() {
  if [ "$1" = "?" ] || [ "$1" = "..." ] || [ -z "$1" ]; then echo "$1"
  else awk "BEGIN {printf \"%.0f\", $1 * 100}" 2>/dev/null || echo "?"
  fi
}

u_color() {
  local pct=$(u2p "$1")
  if [ "$pct" = "?" ] || [ "$pct" = "..." ]; then echo -n ""
  elif [ "$pct" -lt 50 ] 2>/dev/null; then echo -n "\033[32m"
  elif [ "$pct" -lt 80 ] 2>/dev/null; then echo -n "\033[33m"
  else echo -n "\033[31m"
  fi
}

s_icon() {
  case "$1" in
    allowed) echo -n "✅";; throttled) echo -n "⚠️";; rejected) echo -n "❌";; *) echo -n "·";;
  esac
}

PCT_5H=$(u2p "$UTIL_5H")
PCT_7D=$(u2p "$UTIL_7D")

# Line 1: model + context window + turn token consumption
echo -e "${MODEL}  $(ctx_color $CTX_USED)$(ctx_bar $CTX_USED) ${CTX_USED}%%${NC}  ${DIM}turn:${NC} $(fmt_tok $TURN_IN)→$(fmt_tok $TURN_OUT) ${DIM}($(fmt_tok $TURN_TOTAL))${NC}"

# Line 2: rate limits + total tokens
echo -e "$(s_icon $STATUS) 5h:$(u_color $UTIL_5H)${PCT_5H}%%${NC}  7d:$(u_color $UTIL_7D)${PCT_7D}%%${NC}  ${DIM}all: $(fmt_tok $IN_TOK)→$(fmt_tok $OUT_TOK)${NC}"
