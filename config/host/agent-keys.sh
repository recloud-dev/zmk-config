#!/bin/sh
set -eu
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
export PATH

action=$1
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
    *) printf 'Unknown action: %s\n' "$action" >&2; exit 2 ;;
esac
