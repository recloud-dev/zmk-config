#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
while IFS= read -r binding; do
    trigger=${binding#*= }
    trigger=${trigger%%=*}
    case "$trigger" in
        f14|f15|f17|f18)
            printf 'Agent key conflicts with macOS/Rectangle: %s\n' "$trigger" >&2
            exit 1
            ;;
    esac
done < "$root/config/host/ghostty.conf"
real_tmux=$(command -v tmux)
task_socket="mriya-host-test-$$"
work=$(mktemp -d)
trap '"$real_tmux" -L "$task_socket" kill-server 2>/dev/null || true; rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/bin" "$work/home/.tmux/scripts" "$work/home/.codex"
export HOME="$work/home" TEST_LOG="$work/log" TEST_COMMAND=codex TEST_BACK='%9'
export PATH="$work/bin:$PATH"

cat > "$work/bin/tmux" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOG"
last=''
for arg do last=$arg; done
case "$1" in
    display-message)
        case "$last" in
            '#{client_pid}') printf '42\n' ;;
            '#{session_id}') [ "${TEST_TARGET_CLOSED:-0}" != 1 ] || exit 1; printf '$2\n' ;;
            '#{pane_current_command}') printf '%s\n' "$TEST_COMMAND" ;;
            '#{@agent_state}') printf 'waiting\n' ;;
        esac
        ;;
    show-option) printf '%s\n' "$TEST_BACK" ;;
    list-sessions) exit 1 ;;
esac
MOCK
cat > "$HOME/.tmux/scripts/agent-jump.sh" <<'MOCK'
#!/bin/sh
printf '%s\n' 'work:1 %2'
MOCK
cp "$HOME/.tmux/scripts/agent-jump.sh" "$HOME/.tmux/scripts/agent-list.sh"
cp "$HOME/.tmux/scripts/agent-jump.sh" "$HOME/.tmux/scripts/agent-monitor.sh"
chmod +x "$work/bin/tmux" "$HOME/.tmux/scripts/"*.sh

run() {
    : > "$TEST_LOG"
    "$root/config/host/agent-keys.sh" "$1" '%1' '/dev/ttys001'
}

run next
grep -Fqx 'set-option -g @mriya_back_42 %1' "$TEST_LOG"
grep -Fqx 'select-pane -t %2' "$TEST_LOG"
grep -Fqx "switch-client -c /dev/ttys001 -t \$2" "$TEST_LOG"
grep -Fqx 'set-option -pu -t %2 @agent_state' "$TEST_LOG"

run back
grep -Fqx 'select-pane -t %9' "$TEST_LOG"
export TEST_TARGET_CLOSED=1
if run back; then printf 'Closed pane was accepted\n' >&2; exit 1; fi
if grep -q '^switch-client\|^select-pane\|^set-option' "$TEST_LOG"; then
    printf 'Closed pane changed navigation state\n' >&2; exit 1
fi
unset TEST_TARGET_CLOSED

run model
grep -Fqx 'send-keys -t %1 S-F6' "$TEST_LOG"
run less
grep -Fqx 'send-keys -t %1 S-Down' "$TEST_LOG"
run more
grep -Fqx 'send-keys -t %1 S-Up' "$TEST_LOG"
export TEST_COMMAND=claude
run model
grep -Fqx 'send-keys -t %1 M-p' "$TEST_LOG"
run less
grep -Fqx 'send-keys -t %1 M-p Left' "$TEST_LOG"
run more
grep -Fqx 'send-keys -t %1 M-p Right' "$TEST_LOG"
export TEST_COMMAND=zsh
run model
if grep -q '^send-keys' "$TEST_LOG"; then
    printf 'Agent input leaked to shell\n' >&2; exit 1
fi

printf 'model = "existing-model"\n' > "$HOME/.codex/config.toml"
printf 'set -g prefix C-space\n' > "$HOME/.tmux.conf"
"$root/config/host/install.sh"
cp "$HOME/.codex/config.toml" "$work/installed-codex"
"$root/config/host/install.sh"
cmp "$HOME/.codex/config.toml" "$work/installed-codex"
[ ! -L "$HOME/.config/mriya" ]
cmp "$root/config/host/agent-keys.sh" "$HOME/.config/mriya/agent-keys.sh"
[ "$(grep -c '^# MRIYA-KEYS-BEGIN$' "$HOME/.codex/config.toml")" = 1 ]
[ "$(grep -c '^source-file' "$HOME/.tmux.conf")" = 1 ]
[ "$(grep -c '^config-file' "$HOME/.config/ghostty/config")" = 1 ]
grep -Fqx 'model = "existing-model"' "$HOME/.codex/config.toml"
grep -Fqx 'model = "existing-model"' "$HOME/.codex/config.toml.mriya-backup"
printf '\n[tui.keymap.chat]\nopen_presets = ["f2"]\n' >> "$HOME/.codex/config.toml"
cp "$HOME/.codex/config.toml" "$work/with-custom-bindings"
if "$root/config/host/install.sh" 2>/dev/null; then
    printf 'Existing custom keybindings were overwritten\n' >&2; exit 1
fi
cmp "$HOME/.codex/config.toml" "$work/with-custom-bindings"

"$real_tmux" -L "$task_socket" -f /dev/null new-session -d -s check 'sleep 60'
"$real_tmux" -L "$task_socket" source-file "$root/config/host/tmux.conf" 2> "$work/tmux-errors"
[ ! -s "$work/tmux-errors" ]
[ "$("$real_tmux" -L "$task_socket" list-keys -T root | grep -c 'S-F[1-9] ')" = 8 ]
if "$real_tmux" -L "$task_socket" list-keys -T root S-F7 >/dev/null 2>&1; then
    printf 'F19 transport was bound\n' >&2; exit 1
fi
printf 'Host keys: navigation, closed panes, client routing, shell isolation and installer checks passed.\n'
