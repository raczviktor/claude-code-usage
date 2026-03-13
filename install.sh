#!/bin/bash
# install.sh – Installer for claude-code-usage
# Usage:
#   Install:   curl -sL https://raw.githubusercontent.com/raczviktor/claude-code-usage/main/install.sh | bash
#   Uninstall: curl -sL https://raw.githubusercontent.com/raczviktor/claude-code-usage/main/install.sh | bash -s -- --uninstall

set -e

REPO_RAW="https://raw.githubusercontent.com/raczviktor/claude-code-usage/main"
INSTALL_DIR="$HOME/.local/bin"
SETTINGS_FILE="$HOME/.claude/settings.json"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BOLD="\033[1m"
NC="\033[0m"

info()  { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}!${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

# ============================================================
# Uninstall
# ============================================================
if [ "$1" = "--uninstall" ]; then
  echo -e "${BOLD}Uninstalling claude-code-usage...${NC}"
  echo ""

  # Remove scripts
  for f in usage.sh statusline.sh rate-proxy.js; do
    if [ -f "$INSTALL_DIR/$f" ]; then
      rm "$INSTALL_DIR/$f"
      info "Removed $INSTALL_DIR/$f"
    fi
  done

  # Remove cache & state files
  for f in .usage_cache .statusline_state; do
    if [ -f "$INSTALL_DIR/$f" ]; then
      rm "$INSTALL_DIR/$f"
      info "Removed $INSTALL_DIR/$f"
    fi
  done

  # Remove statusLine and ANTHROPIC_BASE_URL from settings.json
  if [ -f "$SETTINGS_FILE" ] && command -v jq &>/dev/null; then
    TMP=$(mktemp)
    CHANGED=false

    # Remove statusLine from all project entries
    if jq -e '.projects // empty | to_entries[] | select(.value.statusLine)' "$SETTINGS_FILE" &>/dev/null; then
      jq '(.projects // {}) |= with_entries(del(.value.statusLine))' "$SETTINGS_FILE" > "$TMP" && mv "$TMP" "$SETTINGS_FILE"
      CHANGED=true
      info "Removed statusLine config from $SETTINGS_FILE"
    fi

    # Remove ANTHROPIC_BASE_URL from env
    if jq -e '.env.ANTHROPIC_BASE_URL' "$SETTINGS_FILE" &>/dev/null; then
      TMP=$(mktemp)
      jq 'del(.env.ANTHROPIC_BASE_URL)' "$SETTINGS_FILE" > "$TMP" && mv "$TMP" "$SETTINGS_FILE"
      info "Removed ANTHROPIC_BASE_URL from $SETTINGS_FILE"
    fi
  fi

  echo ""
  info "Uninstall complete. Restart Claude Code to apply changes."
  exit 0
fi

# ============================================================
# Install
# ============================================================
echo ""
echo -e "${BOLD}Installing claude-code-usage...${NC}"
echo ""

# --- Check prerequisites ---
MISSING=""
for cmd in jq curl awk; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING="$MISSING $cmd"
  fi
done

if [ -n "$MISSING" ]; then
  error "Missing required tools:${MISSING}"
  echo ""
  echo "  Install them first:"
  echo "    Ubuntu/Debian: sudo apt install jq curl gawk"
  echo "    macOS:         brew install jq curl gawk"
  echo "    Windows:       These are included with Git Bash"
  echo ""
  exit 1
fi

info "Prerequisites OK (jq, curl, awk)"

# Check for Node.js (needed for rate-proxy)
HAS_NODE=false
if command -v node &>/dev/null; then
  HAS_NODE=true
  info "Node.js found ($(node --version))"
else
  warn "Node.js not found – rate-proxy.js won't work (polling fallback will be used)"
fi

# --- Create install directory ---
mkdir -p "$INSTALL_DIR"
info "Directory ready: $INSTALL_DIR"

# --- Download scripts ---
for script in usage.sh statusline.sh rate-proxy.js; do
  curl -sL "$REPO_RAW/src/$script" -o "$INSTALL_DIR/$script"
  if [ "$script" != "rate-proxy.js" ]; then
    chmod +x "$INSTALL_DIR/$script"
  fi
  info "Installed $INSTALL_DIR/$script"
done

# --- Configure Claude Code settings ---
echo ""
STATUSLINE_CMD="$INSTALL_DIR/statusline.sh"

# Build the statusLine config snippet
STATUSLINE_JSON=$(cat <<'SLJSON'
{"type":"command","command":"~/.local/bin/statusline.sh"}
SLJSON
)

# Determine the project key (use "*" for global match)
PROJECT_KEY="*"

configure_settings() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    # No settings file – create one
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    if [ "$HAS_NODE" = true ]; then
      cat > "$SETTINGS_FILE" <<SETTINGS
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8087"
  },
  "statusLine": {
    "type": "command",
    "command": "bash ~/.local/bin/statusline.sh"
  }
}
SETTINGS
    else
      cat > "$SETTINGS_FILE" <<SETTINGS
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.local/bin/statusline.sh"
  }
}
SETTINGS
    fi
    info "Created $SETTINGS_FILE with statusLine config"

  else
    # Settings exists – merge in our config
    TMP=$(mktemp)

    # Add statusLine at top level if not present
    if ! jq -e '.statusLine' "$SETTINGS_FILE" &>/dev/null; then
      jq --argjson sl "$STATUSLINE_JSON" '. + {statusLine: $sl}' "$SETTINGS_FILE" > "$TMP" && mv "$TMP" "$SETTINGS_FILE"
      info "Added statusLine config to $SETTINGS_FILE"
    else
      info "statusLine already configured (no changes needed)"
    fi

    # Add ANTHROPIC_BASE_URL if node is available and not already set
    if [ "$HAS_NODE" = true ]; then
      if ! jq -e '.env.ANTHROPIC_BASE_URL' "$SETTINGS_FILE" &>/dev/null; then
        TMP=$(mktemp)
        jq '.env = ((.env // {}) + {"ANTHROPIC_BASE_URL": "http://127.0.0.1:8087"})' "$SETTINGS_FILE" > "$TMP" && mv "$TMP" "$SETTINGS_FILE"
        info "Added ANTHROPIC_BASE_URL to $SETTINGS_FILE (proxy mode)"
      else
        info "ANTHROPIC_BASE_URL already set"
      fi
    fi
  fi
}

configure_settings

# --- Pre-populate cache ---
echo ""
if [ "$HAS_NODE" = true ]; then
  echo -e "${BOLD}Rate proxy mode enabled.${NC}"
  echo ""
  echo "  Start the proxy before launching Claude Code:"
  echo "    node ~/.local/bin/rate-proxy.js &"
  echo ""
  echo "  The proxy intercepts Claude Code's API calls and extracts"
  echo "  rate limit data – no extra API calls, always up-to-date."
  echo ""
  echo "  Tip: Add the proxy to your system startup script."
else
  echo -e "${BOLD}Running initial usage check (polling mode)...${NC}"
  if "$INSTALL_DIR/usage.sh"; then
    info "Cache populated"
  else
    warn "Initial usage check failed (this is OK – it will retry automatically)"
    warn "Make sure you have a valid token in ~/.claude/.credentials.json"
    warn "or set the ANTHROPIC_API_KEY environment variable"
  fi
fi

# --- Done ---
echo ""
echo -e "${BOLD}${GREEN}Installation complete!${NC}"
echo ""
echo "  Restart Claude Code to see the status bar."
if [ "$HAS_NODE" = true ]; then
  echo "  Don't forget to start the proxy: node ~/.local/bin/rate-proxy.js &"
fi
echo ""
