#!/bin/bash
# install.sh – Installer for claude-code-usage
# Usage:
#   Install:   curl -sL https://raw.githubusercontent.com/rviktor87/claude-code-usage/main/install.sh | bash
#   Uninstall: curl -sL https://raw.githubusercontent.com/rviktor87/claude-code-usage/main/install.sh | bash -s -- --uninstall

set -e

REPO_RAW="https://raw.githubusercontent.com/rviktor87/claude-code-usage/main"
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
  for f in usage.sh statusline.sh; do
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

  # Remove statusLine from settings.json
  if [ -f "$SETTINGS_FILE" ] && command -v jq &>/dev/null; then
    if jq -e '.projects // empty | to_entries[] | select(.value.statusLine)' "$SETTINGS_FILE" &>/dev/null; then
      # Remove statusLine from all project entries
      TMP=$(mktemp)
      jq '(.projects // {}) |= with_entries(del(.value.statusLine))' "$SETTINGS_FILE" > "$TMP" && mv "$TMP" "$SETTINGS_FILE"
      info "Removed statusLine config from $SETTINGS_FILE"
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

# --- Create install directory ---
mkdir -p "$INSTALL_DIR"
info "Directory ready: $INSTALL_DIR"

# --- Download scripts ---
for script in usage.sh statusline.sh; do
  curl -sL "$REPO_RAW/src/$script" -o "$INSTALL_DIR/$script"
  chmod +x "$INSTALL_DIR/$script"
  info "Installed $INSTALL_DIR/$script"
done

# --- Configure Claude Code settings ---
echo ""
STATUSLINE_CMD="$INSTALL_DIR/statusline.sh"

# Build the statusLine config snippet
STATUSLINE_JSON=$(cat <<'SLJSON'
{"command":"~/.local/bin/statusline.sh","refresh":"2s","enabled":true}
SLJSON
)

# Determine the project key (use "*" for global match)
PROJECT_KEY="*"

configure_settings() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    # No settings file – create one
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    cat > "$SETTINGS_FILE" <<SETTINGS
{
  "projects": {
    "$PROJECT_KEY": {
      "statusLine": $STATUSLINE_JSON
    }
  }
}
SETTINGS
    info "Created $SETTINGS_FILE with statusLine config"

  elif ! jq -e '.projects' "$SETTINGS_FILE" &>/dev/null; then
    # Settings exists but no projects key
    TMP=$(mktemp)
    jq --argjson sl "$STATUSLINE_JSON" --arg pk "$PROJECT_KEY" \
      '. + {projects: {($pk): {statusLine: $sl}}}' "$SETTINGS_FILE" > "$TMP" && mv "$TMP" "$SETTINGS_FILE"
    info "Added statusLine config to $SETTINGS_FILE"

  elif ! jq -e --arg pk "$PROJECT_KEY" '.projects[$pk].statusLine' "$SETTINGS_FILE" &>/dev/null; then
    # Projects exists but no statusLine for this key
    TMP=$(mktemp)
    jq --argjson sl "$STATUSLINE_JSON" --arg pk "$PROJECT_KEY" \
      '.projects[$pk] = ((.projects[$pk] // {}) + {statusLine: $sl})' "$SETTINGS_FILE" > "$TMP" && mv "$TMP" "$SETTINGS_FILE"
    info "Added statusLine config to $SETTINGS_FILE"

  else
    # statusLine already exists
    EXISTING=$(jq -r --arg pk "$PROJECT_KEY" '.projects[$pk].statusLine.command // ""' "$SETTINGS_FILE")
    if [ "$EXISTING" = "$STATUSLINE_CMD" ] || [ "$EXISTING" = "~/.local/bin/statusline.sh" ]; then
      info "statusLine already configured (no changes needed)"
    else
      warn "statusLine already configured with a different command:"
      echo "      current: $EXISTING"
      echo "      new:     $STATUSLINE_CMD"
      echo ""
      if [ -t 0 ]; then
        read -rp "  Overwrite? [y/N] " ans
        if [[ "$ans" =~ ^[Yy] ]]; then
          TMP=$(mktemp)
          jq --argjson sl "$STATUSLINE_JSON" --arg pk "$PROJECT_KEY" \
            '.projects[$pk].statusLine = $sl' "$SETTINGS_FILE" > "$TMP" && mv "$TMP" "$SETTINGS_FILE"
          info "Updated statusLine config"
        else
          warn "Kept existing statusLine config"
        fi
      else
        warn "Non-interactive mode – keeping existing statusLine config"
        warn "To update manually, edit $SETTINGS_FILE"
      fi
    fi
  fi
}

configure_settings

# --- Pre-populate cache ---
echo ""
echo -e "${BOLD}Running initial usage check...${NC}"
if "$INSTALL_DIR/usage.sh"; then
  info "Cache populated"
else
  warn "Initial usage check failed (this is OK – it will retry automatically)"
  warn "Make sure you have a valid token in ~/.claude/.credentials.json"
  warn "or set the ANTHROPIC_API_KEY environment variable"
fi

# --- Done ---
echo ""
echo -e "${BOLD}${GREEN}Installation complete!${NC}"
echo ""
echo "  Restart Claude Code to see the status bar."
echo "  Run 'usage.sh' anytime to check your rate limits."
echo ""
