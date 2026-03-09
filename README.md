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

Then restart Claude Code.

## Manual Install

1. Download the scripts:

```bash
mkdir -p ~/.local/bin
curl -sL https://raw.githubusercontent.com/raczviktor/claude-code-usage/main/src/usage.sh -o ~/.local/bin/usage.sh
curl -sL https://raw.githubusercontent.com/raczviktor/claude-code-usage/main/src/statusline.sh -o ~/.local/bin/statusline.sh
chmod +x ~/.local/bin/usage.sh ~/.local/bin/statusline.sh
```

2. Add to your Claude Code settings (`~/.claude/settings.json`):

```json
{
  "projects": {
    "*": {
      "statusLine": {
        "command": "~/.local/bin/statusline.sh",
        "refresh": "2s",
        "enabled": true
      }
    }
  }
}
```

3. Pre-populate the cache:

```bash
~/.local/bin/usage.sh
```

4. Restart Claude Code.

## How It Works

```
                     ┌──────────────┐
                     │  Anthropic   │
                     │  Messages    │
                     │  API         │
                     └──────┬───────┘
                            │ rate limit headers
                            ▼
┌──────────┐ cache  ┌──────────────┐
│statusline│◄───────│   usage.sh   │
│   .sh    │  file  │  (checker)   │
└────┬─────┘        └──────────────┘
     │ stdout              ▲
     ▼                     │ background refresh
┌──────────┐               │ every 5 min
│  Claude  │───────────────┘
│  Code    │
│ status   │
│  bar     │
└──────────┘
```

1. **`usage.sh`** makes a minimal API call (1-token Haiku request) and reads the `anthropic-ratelimit-*` response headers
2. It writes the parsed rate limit data (utilization, reset timestamps) to a cache file (`~/.local/bin/.usage_cache`)
3. **`statusline.sh`** is called by Claude Code every 2 seconds with session JSON on stdin
4. It reads session data (model, context, tokens) and combines it with cached rate limits
5. It calculates **pace** (time-proportional usage rate) to color-code limits: green if sustainable, red if burning too fast
6. It tracks **turn cost**: total tokens from your question through all iterations until done
7. If the cache is older than 5 minutes, it spawns a background `usage.sh` to refresh it

## Customization

### Cache refresh interval

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

Edit the `width` variable in `usage.sh` (default: `20`):

```bash
local width=30  # wider bar
```

### Model for API probe

Edit the model in the `curl` call in `usage.sh`. Haiku is the cheapest option:

```bash
-d '{"model":"claude-haiku-4-5-20251001", ...}'
```

## Troubleshooting

### "Error: Could not read access token"

Your Claude Code credentials file is missing or malformed. Make sure you're logged into Claude Code (`claude` in terminal).

### "Error: Authentication failed"

Your OAuth token has expired. Restart Claude Code to refresh it, or set `ANTHROPIC_API_KEY` manually.

### "Error: No rate limit headers"

The API response didn't include rate limit headers. This can happen if:
- The API endpoint is unreachable
- You're behind a proxy that strips headers
- The API version has changed

### Status bar shows `...` or `?` for rate limits

The cache hasn't been populated yet. Run `usage.sh` manually once:

```bash
~/.local/bin/usage.sh
```

### Colors don't show up

Your terminal may not support ANSI colors. Claude Code's built-in terminal should work fine.

## Uninstall

```bash
curl -sL https://raw.githubusercontent.com/raczviktor/claude-code-usage/main/install.sh | bash -s -- --uninstall
```

Or manually:

```bash
rm ~/.local/bin/usage.sh ~/.local/bin/statusline.sh
rm ~/.local/bin/.usage_cache ~/.local/bin/.statusline_state
# Then remove the statusLine block from ~/.claude/settings.json
```

## Notes

- **Claude Max (subscription):** Uses the OAuth token from `~/.claude/.credentials.json` automatically
- **API key users:** Set `ANTHROPIC_API_KEY` environment variable. The API probe call costs ~1 token per check (negligible)
- **Rate limit headers** are specific to your account tier and are returned with every API response
- Works on **Linux, macOS, and Windows** (Git Bash / WSL)

## License

[MIT](LICENSE)
