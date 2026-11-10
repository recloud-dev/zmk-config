#!/bin/sh
set -eu

source_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
install_dir="$HOME/.config/mriya"
codex_config="$HOME/.codex/config.toml"
tmux_config="$HOME/.tmux.conf"
ghostty_config="$HOME/.config/ghostty/config"

for name in agent-jump.sh agent-list.sh agent-monitor.sh; do
    [ -x "$HOME/.tmux/scripts/$name" ] || {
        printf 'Missing existing AgentBar script: %s\n' "$name" >&2
        exit 1
    }
done

mkdir -p "$HOME/.codex" "$HOME/.config/ghostty"
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

if [ -f "$codex_config" ] && [ ! -e "$codex_config.mriya-backup" ]; then
    cp -p "$codex_config" "$codex_config.mriya-backup"
fi
if [ -f "$tmux_config" ] && [ ! -e "$tmux_config.mriya-backup" ]; then
    cp -p "$tmux_config" "$tmux_config.mriya-backup"
fi
if [ -f "$ghostty_config" ] && [ ! -e "$ghostty_config.mriya-backup" ]; then
    cp -p "$ghostty_config" "$ghostty_config.mriya-backup"
fi

{
    cat "$filtered"
    printf '# MRIYA-KEYS-BEGIN\n'
    cat "$source_dir/codex.toml"
    printf '# MRIYA-KEYS-END\n'
} > "$codex_config"
mkdir -p "$install_dir"
install -m 755 "$source_dir/agent-keys.sh" "$install_dir/agent-keys.sh"
install -m 644 "$source_dir/tmux.conf" "$install_dir/tmux.conf"
install -m 644 "$source_dir/ghostty.conf" "$install_dir/ghostty.conf"
source_line="source-file \"\$HOME/.config/mriya/tmux.conf\""
if ! grep -Fqx "$source_line" "$tmux_config" 2>/dev/null; then
    printf '\n%s\n' "$source_line" >> "$tmux_config"
fi
ghostty_line="config-file = $install_dir/ghostty.conf"
if ! grep -Fqx "$ghostty_line" "$ghostty_config" 2>/dev/null; then
    printf '\n%s\n' "$ghostty_line" >> "$ghostty_config"
fi
if tmux list-sessions >/dev/null 2>&1; then
    tmux source-file "$install_dir/tmux.conf"
fi
printf 'Installed F13–F18, F20–F21. F19 is unbound. Reload Ghostty config and restart Codex to load F18.\n'
