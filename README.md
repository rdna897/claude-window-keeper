# claude-window-keeper

A Claude 5-hour usage window only starts when you send a request. This systemd timer reads when your current window resets and, the moment it does, sends one tiny ephemeral message (`Hi`) to Haiku 4.5 at low effort, so the next window starts immediately.

## How it works

Every 5 minutes it reads `five_hour.resets_at` from Anthropic's OAuth usage endpoint (the data behind `/usage`).

- Window active, reset more than ~5.5 min away: exit.
- Reset imminent: sleep until it passes, re-check, then ping.
- No active window: ping.
- Usage endpoint unavailable: fall back to 5 h after the last successful ping.

At most one ping per hour. Each ping runs `claude -p` with `--safe-mode --tools "" --no-session-persistence`, about 3.6k input tokens on Haiku only.

## Requirements

- Linux with systemd
- [Claude Code](https://claude.com/claude-code) logged in with a Claude subscription (reads `~/.claude/.credentials.json`; macOS Keychain is not supported)
- `curl`, `jq`

## Install (no git needed)

```bash
curl -fsSL https://github.com/rdna897/claude-window-keeper/archive/refs/heads/main.tar.gz | tar -xz -C /tmp \
  && sudo /tmp/claude-window-keeper-main/install.sh
```

Run as the user who is logged in to Claude Code. The installer sets up the job for that user (override with `KEEPER_USER=name`), enables the timer so it survives reboots, and ends with a dry run showing the detected reset time. Re-running it keeps your settings. If you're already root, drop `sudo`.

## Usage

```bash
claude-window-keeper.sh --dry-run               # show the decision, send nothing
journalctl -u claude-window-keeper -n 20        # logs
systemctl list-timers claude-window-keeper.timer
```

Settings (model, effort, prompt, `LIVE_TRIGGER_ENABLED`) are in `/etc/default/claude-window-keeper`. Set `LIVE_TRIGGER_ENABLED=0` to disarm.

## Uninstall

```bash
sudo /tmp/claude-window-keeper-main/install.sh uninstall
```

## Caveat

The usage endpoint (`/api/oauth/usage`) is undocumented and may change.
