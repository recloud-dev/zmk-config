#!/bin/sh
set -eu
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
export PATH

action=$1
case "$action" in
    next|list|back|monitor|zoom|model|less|more) ;;
    *) printf 'Unknown action: %s\n' "$action" >&2; exit 2 ;;
esac
clients=$(tmux list-clients -F '#{client_activity}|#{client_name}|#{session_id}')
if [ $# -ge 2 ]; then
    selected=$(printf '%s\n' "$clients" | awk -F'|' -v client="$2" '$2 == client')
else
    selected=$(printf '%s\n' "$clients" | sort -t'|' -k1,1nr | awk -F'|' '
        NR == 1 { first=$0; activity=$1; next }
        NR == 2 && $1 == activity { ambiguous=1 }
        END { if (!ambiguous) print first }
    ')
fi
if [ -z "$selected" ]; then
    printf 'No unique tmux client. Specify: agent-keys.sh <action> <client-name>\n' >&2
    exit 1
fi
IFS='|' read -r _activity client session <<EOF
$selected
EOF
pane=$(tmux display-message -p -t "$session" '#{pane_id}')
client_pid=$(tmux display-message -p -c "$client" '#{client_pid}')
back_key="@mriya_back_$client_pid"

focus_terminal() {
    command -v osascript >/dev/null 2>&1 || return 0
    client_tty=$(tmux display-message -p -c "$client" '#{client_tty}')
    terminal_pid=$client_pid
    set -- "$client_tty" "$terminal_pid"
    while [ "$terminal_pid" -gt 1 ]; do
        terminal_pid=$(ps -p "$terminal_pid" -o ppid= | tr -d '[:space:]')
        case "$terminal_pid" in ''|*[!0-9]*) break ;; esac
        [ "$terminal_pid" -gt 1 ] || break
        set -- "$@" "$terminal_pid"
    done
    if ! osascript -l JavaScript - "$@" <<'JXA'
ObjC.import('AppKit');
function run(args) {
    const tty = args[0];
    for (let i = 1; i < args.length; i++) {
        const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(args[i]));
        if (app.isNil() || app.activationPolicy !== $.NSApplicationActivationPolicyRegular) continue;
        if (ObjC.unwrap(app.bundleIdentifier) === 'com.mitchellh.ghostty') {
            const ghostty = Application('com.mitchellh.ghostty');
            const terminals = ghostty.terminals.whose({tty: tty})();
            if (terminals.length !== 1) throw new Error('No unique Ghostty terminal for ' + tty);
            ghostty.focus(terminals[0]);
        }
        if (!app.activateWithOptions(0)) throw new Error('Terminal activation refused');
        const deadline = Date.now() + 2000;
        while (Date.now() < deadline) {
            if (app.active) return;
            $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.05));
        }
        throw new Error('Terminal did not become active');
    }
    throw new Error('No terminal application owns this tmux client');
}
JXA
    then
        tmux display-message -c "$client" 'Не удалось активировать терминал'
        return 1
    fi
}

focus_terminal

remember() {
    tmux set-option -g "$back_key" "$pane"
}

jump() {
    destination=$1
    session=$(tmux display-message -p -t "$destination" '#{session_id}' 2>/dev/null) || {
        tmux display-message -c "$client" 'Панель уже закрыта'
        return 1
    }
    remember
    tmux select-window -t "$destination"
    tmux select-pane -t "$destination"
    tmux switch-client -c "$client" -t "$session"
}

case "$action" in
    next)
        target=$(DRY=1 "$HOME/.tmux/scripts/agent-jump.sh")
        [ -n "$target" ] || exit 0
        target=${target##* }
        jump "$target"
        case $(tmux display-message -p -t "$target" '#{@agent_state}') in
            waiting|done)
                tmux set-option -pu -t "$target" @agent_state
                tmux set-option -pu -t "$target" @agent_since
                ;;
        esac
        ;;
    list)
        remember
        tmux display-popup -c "$client" -E -w 70% -h 60% "$HOME/.tmux/scripts/agent-list.sh"
        ;;
    back)
        target=$(tmux show-option -gqv "$back_key")
        if [ -n "$target" ] && [ "$target" != "$pane" ]; then
            jump "$target"
        else
            tmux display-message -c "$client" 'Нет предыдущей панели'
        fi
        ;;
    monitor)
        remember
        tmux new-window -t "$(tmux display-message -p -t "$pane" '#{session_id}'):" \
            -n agent-monitor "$HOME/.tmux/scripts/agent-monitor.sh"
        ;;
    zoom) tmux resize-pane -t "$pane" -Z ;;
    model|less|more)
        command=$(tmux display-message -p -t "$pane" '#{pane_current_command}')
        case "$command:$action" in
            codex:model)
                tmux send-keys -t "$pane" S-F6
                tmux display-message -c "$client" 'Codex: 0 — выбрать модель'
                ;;
            codex:less) tmux send-keys -t "$pane" S-Down ;;
            codex:more) tmux send-keys -t "$pane" S-Up ;;
            claude:model) tmux send-keys -t "$pane" M-p ;;
            claude:less) tmux send-keys -t "$pane" M-p Left ;;
            claude:more) tmux send-keys -t "$pane" M-p Right ;;
            *) tmux display-message -c "$client" 'Эта команда доступна в Codex CLI и Claude Code' ;;
        esac
        ;;
esac
