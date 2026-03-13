# claude-code-usage

Real-time rate limit and token usage monitor for the [Claude Code](https://docs.anthropic.com/en/docs/claude-code) status bar.

## What it looks like

```
🤖 Opus 4.6  🧠 ▓▓▓▓▓░░░░░ 52%  │  🔋 61%✓ 1h10m · 4%▼ 6d21h  │  💬 45.6k
```

- 🤖 Active model
- 🧠 Context window usage (colored progress bar)
- 🔋 Rate limits with pace indicators and time until reset
  - First value: 5-hour window (usage%, pace icon, time remaining)
  - Second value: 7-day window (same format)
  - Pace icons: ▼ under budget · ✓ on track · ▲ over budget
  - Colors based on pace, not raw %: 84% with 2min left = green ✓
- 💬 Token cost of the current interaction (question → all iterations → done)

## Quick Install

```bash
curl -sL https://raw.githubusercontent.com/raczviktor/claude-code-usage/main/install.sh | bash
```

Then start the proxy and restart Claude Code:

```bash
node ~/.local/bin/rate-proxy.js &
```

## How It Works

### Proxy mode (recommended)

A lightweight Node.js reverse proxy sits between Claude Code and the Anthropic API. It forwards all requests transparently and extracts the `anthropic-ratelimit-*` headers from every response.

```
┌──────────┐  http   ┌──────────────┐  https  ┌──────────────┐
│  Claude   │───────►│  rate-proxy   │────────►│  Anthropic   │
│  Code     │◄───────│   :8087       │◄────────│  API         │
└──────────┘        └──────┬───────┘        └──────────────┘
                           │ write
                           ▼
┌──────────┐  read  ┌──────────────┐
│statusline│◄───────│ .usage_cache │
│   .sh    │        └──────────────┘
└────┬─────┘
     │ stdout
     ▼
┌──────────┐
│  Claude  │
│  Code    │
│  status  │
│  bar     │
└──────────┘
```

**How it works:**

1. `ANTHROPIC_BASE_URL=http://127.0.0.1:8087` in Claude Code settings redirects all API calls through the local proxy
2. **`rate-proxy.js`** forwards requests to `api.anthropic.com` transparently – Claude Code doesn't know it's there
3. On every response, it extracts rate limit headers and writes them to `.usage_cache`
4. **`statusline.sh`** reads the cache every 2 seconds, combines it with session data (model, context, tokens), and outputs the status bar

**Advantages:**

- **Zero extra API calls** – piggybacks on Claude Code's own traffic
- **Always up-to-date** – cache refreshes on every API call, not every 5 minutes
- **No auth issues** – uses Claude Code's own authentication
- **Negligible overhead** – simple TCP proxy, adds <1ms latency

### Polling mode (legacy fallback)

If Node.js is not available or the proxy is not running, `statusline.sh` falls back to the original polling approach:

1. **`usage.sh`** makes a minimal API call (1-token Haiku request) to read rate limit headers
2. It writes the parsed data to `.usage_cache`
3. **`statusline.sh`** triggers a background `usage.sh` when the cache is older than 5 minutes

This mode requires a valid authentication token and costs ~1 token per check.

### Why the proxy replaced polling

The original design used `usage.sh` to make standalone API calls and read the rate limit headers from the response. This worked well initially, but had several problems:

1. **OAuth tokens are short-lived (~8h)** – Claude Max users authenticate via OAuth. The token in `~/.claude/.credentials.json` expires and there's no public API to refresh it. When it expires, `usage.sh` gets 401 errors and the status bar shows stale data.

2. **Anthropic disabled OAuth on the public API** – As of early 2025, sending an OAuth token (`sk-ant-oat01-*`) to `api.anthropic.com` returns "OAuth authentication is currently not supported." This completely broke the standalone polling approach for Claude Max users.

3. **Extra API calls are wasteful** – Even when it worked, polling meant making a separate Haiku API call every 5 minutes just to read headers. With the proxy, the same data comes for free from Claude Code's own traffic.

The proxy approach solves all three issues: it uses Claude Code's own authenticated connection, so it works regardless of token type, never makes extra API calls, and the data is always fresh.

## Manual Install

1. Download the scripts:

```bash
mkdir -p ~/.local/bin
curl -sL https://raw.githubusercontent.com/raczviktor/claude-code-usage/main/src/rate-proxy.js -o ~/.local/bin/rate-proxy.js
curl -sL https://raw.githubusercontent.com/raczviktor/claude-code-usage/main/src/statusline.sh -o ~/.local/bin/statusline.sh
curl -sL https://raw.githubusercontent.com/raczviktor/claude-code-usage/main/src/usage.sh -o ~/.local/bin/usage.sh
chmod +x ~/.local/bin/statusline.sh ~/.local/bin/usage.sh
```

2. Add to your Claude Code settings (`~/.claude/settings.json`):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8087"
  },
  "statusLine": {
    "type": "command",
    "command": "bash ~/.local/bin/statusline.sh"
  }
}
```

3. Start the proxy and restart Claude Code:

```bash
node ~/.local/bin/rate-proxy.js &
```

## Starting the proxy automatically

The proxy must be running before Claude Code starts. Here are some options:

### Linux (systemd user service)

```bash
cat > ~/.config/systemd/user/rate-proxy.service <<EOF
[Unit]
Description=Claude Code rate limit proxy

[Service]
ExecStart=/usr/bin/node %h/.local/bin/rate-proxy.js
Restart=on-failure

[Install]
WantedBy=default.target
EOF

systemctl --user enable --now rate-proxy
```

### macOS (launchd)

```bash
cat > ~/Library/LaunchAgents/com.claude.rate-proxy.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.claude.rate-proxy</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/node</string>
        <string>${HOME}/.local/bin/rate-proxy.js</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.claude.rate-proxy.plist
```

### Windows (startup batch script)

Add to your startup script (e.g., `start_env.bat`):

```batch
start /B "" node "%USERPROFILE%\.local\bin\rate-proxy.js"
```

Or create a shortcut in `shell:startup` pointing to:

```
node.exe C:\Users\<you>\.local\bin\rate-proxy.js
```

## Customization

### Proxy port

Set the `RATE_PROXY_PORT` environment variable (default: `8087`):

```bash
RATE_PROXY_PORT=9090 node ~/.local/bin/rate-proxy.js &
```

Remember to update `ANTHROPIC_BASE_URL` in settings.json to match.

### Cache refresh interval (polling mode)

Edit `CACHE_MAX_AGE` in `statusline.sh` (default: `300` = 5 minutes):

```bash
CACHE_MAX_AGE=600  # 10 minutes
```

### Status bar refresh rate

Edit `refresh` in your `settings.json`:

```json
"refresh": "5s"
```

### Progress bar width

Edit the `width` variable in `ctx_bar()` in `statusline.sh` (default: `10`):

```bash
local pct=$1 width=15  # wider bar
```

## Troubleshooting

### Status bar shows `⚠ token expired`

The cache contains an auth error from a failed `usage.sh` call. If you're using the proxy, this shouldn't happen. Check that:
- The proxy is running: `curl -s http://127.0.0.1:8087/v1/messages` should return a response (even an error)
- `ANTHROPIC_BASE_URL` is set in your settings.json

### Status bar shows `⚠ rate limit stale`

The cache hasn't been updated in 30+ minutes. Either:
- The proxy isn't running (start it)
- Claude Code hasn't made any API calls recently (this is normal during idle)

### Status bar shows `🔋 ...`

The cache file doesn't exist yet. If using the proxy, make your first Claude Code request – it will be populated automatically. If using polling mode, run `usage.sh` manually.

### Proxy shows `EADDRINUSE`

Another process is already using port 8087. Either:
- The proxy is already running (nothing to do)
- Another service uses that port – change `RATE_PROXY_PORT`

### "Error: Authentication failed" (usage.sh)

Your OAuth token has expired. This only affects polling mode. Switch to proxy mode to avoid this issue entirely.

### Colors don't show up

Your terminal may not support ANSI colors. Claude Code's built-in terminal should work fine.

## Uninstall

```bash
curl -sL https://raw.githubusercontent.com/raczviktor/claude-code-usage/main/install.sh | bash -s -- --uninstall
```

Or manually:

```bash
rm ~/.local/bin/rate-proxy.js ~/.local/bin/usage.sh ~/.local/bin/statusline.sh
rm ~/.local/bin/.usage_cache ~/.local/bin/.statusline_state
# Then remove statusLine and ANTHROPIC_BASE_URL from ~/.claude/settings.json
```

Don't forget to stop the proxy process and remove any startup scripts.

## Notes

- **Proxy mode** works with any authentication method – OAuth (Claude Max), API keys, everything
- **Polling mode** requires a valid `ANTHROPIC_API_KEY` or OAuth token. The API probe costs ~1 token per check (negligible)
- **Rate limit headers** are specific to your account tier and are returned with every API response
- The proxy has zero dependencies – just Node.js standard library
- Works on **Linux, macOS, and Windows** (Git Bash / WSL)

## License

[MIT](LICENSE)
