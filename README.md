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

- Linux with systemd, root access
- [Claude Code](https://claude.com/claude-code) logged in with a Claude subscription (reads `~/.claude/.credentials.json`; macOS Keychain is not supported)
- `curl`, `jq`

## Install

```bash
git clone https://github.com/rdna897/claude-window-keeper.git
cd claude-window-keeper
sudo ./install.sh
```

The installer enables the timer (it survives reboots) and finishes with a dry run that prints the detected reset time. It runs as root with `HOME=/root`; edit `User=`/`HOME=`/`PATH=` in `systemd/claude-window-keeper.service` first if your Claude login lives elsewhere.

## Usage

```bash
claude-window-keeper.sh --dry-run               # show the decision, send nothing
journalctl -u claude-window-keeper -n 20        # logs
systemctl list-timers claude-window-keeper.timer
```

Settings (model, effort, prompt, `LIVE_TRIGGER_ENABLED`) are in `/etc/default/claude-window-keeper`. Set `LIVE_TRIGGER_ENABLED=0` to disarm.

## Uninstall

```bash
sudo systemctl disable --now claude-window-keeper.timer
sudo rm /etc/systemd/system/claude-window-keeper.{service,timer} /usr/local/bin/claude-window-keeper.sh /etc/default/claude-window-keeper
sudo rm -r /var/lib/claude-window-keeper
```

## Caveat

The usage endpoint (`/api/oauth/usage`) is undocumented and may change.
