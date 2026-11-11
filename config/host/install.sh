#!/bin/sh
set -eu

source_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
install_dir="$HOME/.config/mriya"
codex_config="$HOME/.codex/config.toml"
tmux_config="$HOME/.tmux.conf"
ghostty_config="$HOME/.config/ghostty/config"
skhd_config="$HOME/.config/skhd/skhdrc"

for name in agent-jump.sh agent-list.sh agent-monitor.sh; do
    [ -x "$HOME/.tmux/scripts/$name" ] || {
        printf 'Missing existing AgentBar script: %s\n' "$name" >&2
        exit 1
    }
done

mkdir -p "$HOME/.codex" "$HOME/.config/skhd"
filtered=$(mktemp)
trap 'rm -f "$filtered"' EXIT HUP INT TERM
if [ -f "$codex_config" ]; then
    awk '
        /^# MRIYA-KEYS-BEGIN$/ { skip=1; next }
        /^# MRIYA-KEYS-END$/ { skip=0; next }
        !skip { print }
    ' "$codex_config" > "$filtered"
fi
if grep -Eq '^[[:space:]]*\[[[:space:]]*tui\.(keymap\.chat|presets\.0)[[:space:]]*\]' "$filtered"; then
    printf 'Merge config/host/codex.toml into existing Codex keybindings manually.\n' >&2
    exit 1
fi

for config in "$codex_config" "$tmux_config" "$ghostty_config" "$skhd_config"; do
    if [ -f "$config" ] && [ ! -e "$config.mriya-backup" ]; then
        cp -p "$config" "$config.mriya-backup"
    fi
done

{
    cat "$filtered"
    printf '# MRIYA-KEYS-BEGIN\n'
    cat "$source_dir/codex.toml"
    printf '# MRIYA-KEYS-END\n'
} > "$codex_config"
mkdir -p "$install_dir"
install -m 755 "$source_dir/agent-keys.sh" "$install_dir/agent-keys.sh"
install -m 644 "$source_dir/skhdrc" "$install_dir/skhdrc"
load_line=".load \"$install_dir/skhdrc\""
if ! grep -Fqx "$load_line" "$skhd_config" 2>/dev/null; then
    printf '\n%s\n' "$load_line" >> "$skhd_config"
fi

remove_line() {
    if [ -f "$1" ] && grep -Fqx "$2" "$1"; then
        grep -Fvx "$2" "$1" > "$filtered" || true
        cat "$filtered" > "$1"
    fi
}
source_line="source-file \"\$HOME/.config/mriya/tmux.conf\""
if [ -f "$tmux_config" ] && grep -Fqx "$source_line" "$tmux_config"; then
    if tmux list-sessions >/dev/null 2>&1; then
        for key in S-F1 S-F2 S-F3 S-F4 S-F5 S-F6 S-F8 S-F9; do
            binding=$(tmux list-keys -T root "$key" 2>/dev/null || true)
            case "$binding" in
                *mriya/agent-keys.sh*) tmux unbind-key -n "$key" ;;
                *'S-F5 '*'resize-pane -Z') tmux unbind-key -n "$key" ;;
            esac
        done
    fi
    remove_line "$tmux_config" "$source_line"
fi
ghostty_line="config-file = $install_dir/ghostty.conf"
remove_line "$ghostty_config" "$ghostty_line"
rm -f "$install_dir/tmux.conf" "$install_dir/ghostty.conf"
if command -v skhd >/dev/null 2>&1 && pgrep -x skhd >/dev/null 2>&1; then
    skhd --reload
fi
printf 'Installed global skhd agent keys. FN+P is disabled.\n'
