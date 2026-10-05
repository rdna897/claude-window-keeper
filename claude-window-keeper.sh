#!/usr/bin/env bash
#
# claude-window-keeper.sh - start the Claude five-hour window as soon as it resets.
#
# A Claude five-hour window only starts counting when a request is made.  This
# script reads the reset time of the current window from Anthropic's OAuth usage
# endpoint (the same data /usage shows), waits for it if it is imminent, and then
# sends one tiny ephemeral request (Haiku 4.5, low effort) so the next window
# starts immediately.
#
# Decision per run:
#   * five_hour.resets_at in the future, further than LOOKAHEAD_SECONDS away
#       -> window active; exit.
#   * resets_at within LOOKAHEAD_SECONDS -> sleep until it passes, re-check, ping.
#   * resets_at null or in the past      -> no active window; ping.
#   * usage endpoint unreachable/unauthorised -> fall back to own cadence
#       (last successful ping + 5h).  The ping itself refreshes the OAuth token.
#
# At most one ping per MIN_INTERVAL_SECONDS (default 1h): a window lasts 5h, so
# a ping inside that interval is guaranteed to be within a window already
# started by us, and the guard also covers usage-API lag right after a ping.
#
# Live requests need LIVE_TRIGGER_ENABLED=1 in /etc/default/claude-window-keeper.
# --dry-run shows the decision and the command without sending anything.
#
set -Eeuo pipefail
umask 077

DEFAULTS_FILE="/etc/default/claude-window-keeper"
if [[ -r "$DEFAULTS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$DEFAULTS_FILE"
fi

STATE_DIR="${STATE_DIR:-/var/lib/claude-window-keeper}"
LOCK_FILE="$STATE_DIR/keeper.lock"
LAST_SUCCESS_FILE="$STATE_DIR/last_success_epoch"
HISTORY_FILE="$STATE_DIR/trigger-history.log"

CREDENTIALS_FILE="${CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"
USAGE_URL="${USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")}"

WINDOW_SECONDS="${WINDOW_SECONDS:-18000}"
LOOKAHEAD_SECONDS="${LOOKAHEAD_SECONDS:-330}"
GRACE_SECONDS="${GRACE_SECONDS:-5}"
MIN_INTERVAL_SECONDS="${MIN_INTERVAL_SECONDS:-3600}"
LIVE_TRIGGER_ENABLED="${LIVE_TRIGGER_ENABLED:-0}"
KEEPER_MODEL="${KEEPER_MODEL:-claude-haiku-4-5-20251001}"
KEEPER_EFFORT="${KEEPER_EFFORT:-low}"
KEEPER_PROMPT="${KEEPER_PROMPT:-Reply with exactly: Hi}"
KEEPER_WORKDIR="${KEEPER_WORKDIR:-/tmp}"
EXEC_TIMEOUT_SECONDS="${EXEC_TIMEOUT_SECONDS:-120}"

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  --help|-h)
    echo "Usage: claude-window-keeper.sh [--dry-run]"
    exit 0
    ;;
  *)
    echo "usage: $0 [--dry-run]" >&2
    exit 2
    ;;
esac

log() {
  printf '[claude-window-keeper] %s %s\n' "$(date --iso-8601=seconds)" "$*"
}

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

format_epoch() {
  if is_uint "${1:-}" && (( $1 > 0 )); then
    date --date="@$1" '+%Y-%m-%d %H:%M:%S %Z'
  else
    printf 'unknown'
  fi
}

for var in WINDOW_SECONDS LOOKAHEAD_SECONDS GRACE_SECONDS MIN_INTERVAL_SECONDS EXEC_TIMEOUT_SECONDS; do
  if ! is_uint "${!var}"; then
    log "ERROR: $var must be a non-negative integer"
    exit 1
  fi
done
if [[ "$LIVE_TRIGGER_ENABLED" != 0 && "$LIVE_TRIGGER_ENABLED" != 1 ]]; then
  log "ERROR: LIVE_TRIGGER_ENABLED must be 0 or 1"
  exit 1
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# The lock keeps overlapping timer runs (one may be sleeping until the reset)
# and manual runs from sending two requests.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another run is holding the lock; nothing to do"
  exit 0
fi

last_success_epoch=0
if [[ -r "$LAST_SUCCESS_FILE" ]]; then
  read -r candidate < "$LAST_SUCCESS_FILE" || true
  is_uint "${candidate:-}" && last_success_epoch="$candidate"
fi

# Sets usage_status ("ok" or a reason) and reset_epoch (0 = no active window).
# The token is passed via a curl config on stdin so it never appears in argv.
fetch_reset() {
  usage_status="ok"
  reset_epoch=0
  local token body reset_iso
  token="$(jq -er '.claudeAiOauth.accessToken' "$CREDENTIALS_FILE" 2>/dev/null)" || {
    usage_status="no access token in $CREDENTIALS_FILE"
    return 1
  }
  body="$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -sS -m 20 -K - -H "anthropic-beta: oauth-2025-04-20" \
      -w '\n%{http_code}' "$USAGE_URL" 2>&1)" || {
    usage_status="usage request failed"
    return 1
  }
  local code="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [[ "$code" != 200 ]]; then
    usage_status="usage endpoint returned HTTP $code"
    return 1
  fi
  reset_iso="$(jq -er '.five_hour.resets_at // empty' <<<"$body" 2>/dev/null)" || reset_iso=""
  if [[ -n "$reset_iso" ]]; then
    reset_epoch="$(date --date="$reset_iso" +%s 2>/dev/null)" || {
      usage_status="unparseable resets_at: $reset_iso"
      reset_epoch=0
      return 1
    }
  fi
  return 0
}

now_epoch="$(date +%s)"
due_reason=""
reset_source="usage-api"

if fetch_reset; then
  if (( reset_epoch > now_epoch )); then
    remaining=$(( reset_epoch - now_epoch ))
    if (( remaining > LOOKAHEAD_SECONDS )); then
      log "window active; resets $(format_epoch "$reset_epoch") (in ${remaining}s)"
      exit 0
    fi
    if [[ "$DRY_RUN" == 1 ]]; then
      log "dry-run: reset in ${remaining}s; a live run would sleep until then and re-check"
    else
      log "reset in ${remaining}s ($(format_epoch "$reset_epoch")); waiting"
      sleep $(( remaining + GRACE_SECONDS ))
      now_epoch="$(date +%s)"
      if ! fetch_reset; then
        log "ERROR: re-check after reset failed: $usage_status"
        exit 1
      fi
      if (( reset_epoch > now_epoch )); then
        log "a new window is already active (resets $(format_epoch "$reset_epoch")); nothing to do"
        exit 0
      fi
    fi
    due_reason="five-hour window reset at $(format_epoch "$reset_epoch")"
  elif (( reset_epoch > 0 )); then
    due_reason="five-hour window ended at $(format_epoch "$reset_epoch") and no new one has started"
  else
    due_reason="no active five-hour window"
  fi
else
  reset_source="own-cadence"
  log "WARN: $usage_status; falling back to own cadence"
  if (( last_success_epoch == 0 )); then
    log "no keeper baseline; refusing to guess when the window expired"
    exit 1
  fi
  if (( now_epoch - last_success_epoch < WINDOW_SECONDS )); then
    log "fallback window active until $(format_epoch "$((last_success_epoch + WINDOW_SECONDS))")"
    exit 0
  fi
  due_reason="usage unavailable and the window from $(format_epoch "$last_success_epoch") has expired"
fi

if (( last_success_epoch > 0 && now_epoch - last_success_epoch < MIN_INTERVAL_SECONDS )); then
  log "last keeper ping at $(format_epoch "$last_success_epoch") is within ${MIN_INTERVAL_SECONDS}s; skipping ($due_reason)"
  exit 0
fi

log "trigger due: $due_reason"

claude_args=(
  -p "$KEEPER_PROMPT"
  --model "$KEEPER_MODEL"
  --effort "$KEEPER_EFFORT"
  --safe-mode            # skip CLAUDE.md, skills, plugins, hooks, MCP: keeps the request tiny
  --tools ""
  --no-session-persistence
  --output-format json
)

if [[ "$DRY_RUN" == 1 || "$LIVE_TRIGGER_ENABLED" == 0 ]]; then
  if [[ "$DRY_RUN" == 1 ]]; then
    log "dry-run: no request will be sent"
  else
    log "live trigger is disarmed by $DEFAULTS_FILE; no request will be sent"
  fi
  log "would run (cwd $KEEPER_WORKDIR): $CLAUDE_BIN ${claude_args[*]}"
  exit 0
fi

if [[ ! -x "$CLAUDE_BIN" ]]; then
  log "ERROR: claude CLI not executable at $CLAUDE_BIN"
  exit 1
fi

log "sending one keeper request with model=$KEEPER_MODEL effort=$KEEPER_EFFORT"
output_file="$(mktemp "$STATE_DIR/trigger-output.XXXXXX")"
trap 'rm -f -- "$output_file"' EXIT

cd "$KEEPER_WORKDIR"
if timeout "$EXEC_TIMEOUT_SECONDS" "$CLAUDE_BIN" "${claude_args[@]}" >"$output_file" 2>&1 &&
   jq -e '.is_error == false' "$output_file" >/dev/null 2>&1; then
  trigger_epoch="$(date +%s)"
  state_tmp="$(mktemp "$STATE_DIR/last_success.XXXXXX")"
  printf '%s\n' "$trigger_epoch" > "$state_tmp"
  mv -f -- "$state_tmp" "$LAST_SUCCESS_FILE"
  printf 'timestamp=%s source=%s reset=%s model=%s effort=%s reason=%s\n' \
    "$trigger_epoch" "$reset_source" "$reset_epoch" "$KEEPER_MODEL" "$KEEPER_EFFORT" "$due_reason" >> "$HISTORY_FILE"
  log "keeper request succeeded at $(format_epoch "$trigger_epoch"): $(jq -r '.result // empty' "$output_file" | head -c 100)"
  exit 0
fi

log "ERROR: keeper request failed; output tail:"
tail -n 20 "$output_file"
exit 1
