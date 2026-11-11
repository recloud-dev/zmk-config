#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
original_path=$PATH
real_tmux=$(command -v tmux)
task_socket="mriya-host-test-$$"
work=$(mktemp -d)
trap '"$real_tmux" -L "$task_socket" kill-server 2>/dev/null || true; rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/bin" "$work/home/.tmux/scripts" "$work/home/.codex" "$work/home/.config/ghostty" "$work/home/.config/skhd"
export HOME="$work/home" TEST_LOG="$work/log" TEST_COMMAND=codex TEST_BACK='%9'
export TEST_FOCUS_SCRIPT="$work/focus.js"
export TEST_CLIENTS='10|/dev/ttys001|session-one'
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
            '#{client_tty}') printf '/dev/ttys001\n' ;;
            '#{pane_id}') printf '%%1\n' ;;
            '#{session_id}') [ "${TEST_TARGET_CLOSED:-0}" != 1 ] || exit 1; printf '$2\n' ;;
            '#{pane_current_command}') printf '%s\n' "$TEST_COMMAND" ;;
            '#{@agent_state}') printf 'waiting\n' ;;
        esac
        ;;
    show-option) printf '%s\n' "$TEST_BACK" ;;
    list-clients) printf '%s\n' "$TEST_CLIENTS" ;;
    list-sessions) exit 1 ;;
esac
MOCK
cat > "$work/bin/ps" <<'MOCK'
#!/bin/sh
case "$2" in
    42) printf '41\n' ;;
    41) printf '40\n' ;;
    *) printf '1\n' ;;
esac
MOCK
cat > "$work/bin/osascript" <<'MOCK'
#!/bin/sh
cat > "$TEST_FOCUS_SCRIPT"
printf 'focus %s\n' "$*" >> "$TEST_LOG"
exit "${TEST_FOCUS_FAIL:-0}"
MOCK
cat > "$HOME/.tmux/scripts/agent-jump.sh" <<'MOCK'
#!/bin/sh
printf '%s\n' 'work:1 %2'
MOCK
cp "$HOME/.tmux/scripts/agent-jump.sh" "$HOME/.tmux/scripts/agent-list.sh"
cp "$HOME/.tmux/scripts/agent-jump.sh" "$HOME/.tmux/scripts/agent-monitor.sh"
chmod +x "$work/bin/"* "$HOME/.tmux/scripts/"*.sh

run() {
    : > "$TEST_LOG"
    "$root/config/host/agent-keys.sh" "$1"
}

run list
grep -Fqx 'focus -l JavaScript - /dev/ttys001 42 41 40' "$TEST_LOG"
awk '/^focus / { focused=1 } /^display-popup / { if (!focused) exit 1; opened=1 }
     END { if (!opened) exit 1 }' "$TEST_LOG"
export TEST_FOCUS_FAIL=1
if run list; then printf 'Popup opened after terminal focus failed\n' >&2; exit 1; fi
if grep -q '^display-popup' "$TEST_LOG"; then exit 1; fi
unset TEST_FOCUS_FAIL
run monitor
grep -q '^focus ' "$TEST_LOG"
grep -q '^new-window ' "$TEST_LOG"

node - "$TEST_FOCUS_SCRIPT" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(process.argv[2], 'utf8');
function check({tty = '/dev/ttys001', bundle = 'com.mitchellh.ghostty', matches = 1, accepted = true, owner = true} = {}) {
    const events = [];
    const surface = {tty: '/dev/ttys001'};
    const app = {
        isNil: () => false, activationPolicy: 0, bundleIdentifier: bundle,
        activateWithOptions: () => { events.push('activate'); app.active = true; return accepted; },
    };
    const context = vm.createContext({
        ObjC: {import: () => {}, unwrap: value => value},
        $: {
            NSApplicationActivationPolicyRegular: 0,
            NSRunningApplication: {
                runningApplicationWithProcessIdentifier: pid => owner && pid === 40 ? app : {isNil: () => true},
            },
        },
        Application: id => {
            assert.equal(id, 'com.mitchellh.ghostty');
            return {
                terminals: {whose: query => () => query.tty === surface.tty ? Array(matches).fill(surface) : []},
                focus: target => { assert.equal(target, surface); events.push('surface'); },
            };
        },
    });
    vm.runInContext(source, context);
    return {events, run: () => context.run([tty, '42', '41', '40'])};
}
let test = check();
test.run();
assert.deepEqual(test.events, ['surface', 'activate']);
for (const options of [{tty: '/dev/other'}, {matches: 2}]) {
    test = check(options);
    assert.throws(test.run, /No unique Ghostty terminal/);
    assert.deepEqual(test.events, []);
}
test = check({accepted: false});
assert.throws(test.run, /activation refused/);
test = check({owner: false});
assert.throws(test.run, /No terminal application/);
test = check({bundle: 'com.apple.Terminal'});
test.run();
assert.deepEqual(test.events, ['activate']);
console.log('Terminal focus: exact Ghostty TTY, activation order, failures and app fallback passed.');
JS

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
run zoom
grep -Fqx 'resize-pane -t %1 -Z' "$TEST_LOG"
export TEST_CLIENTS='10|old-client|session-one
20|new-client|session-two'
run model
grep -Fqx 'display-message -p -t session-two #{pane_id}' "$TEST_LOG"
export TEST_CLIENTS='20|old-client|session-one
20|new-client|session-two'
if run model; then printf 'Ambiguous client was accepted\n' >&2; exit 1; fi
if grep -q '^send-keys' "$TEST_LOG"; then exit 1; fi
"$root/config/host/agent-keys.sh" model old-client
grep -Fqx 'display-message -p -t session-one #{pane_id}' "$TEST_LOG"
export TEST_CLIENTS=''
if run model; then printf 'Missing client was accepted\n' >&2; exit 1; fi
if grep -q '^send-keys' "$TEST_LOG"; then exit 1; fi
export TEST_CLIENTS='10|/dev/ttys001|session-one'
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
legacy_source="source-file \"\$HOME/.config/mriya/tmux.conf\""
printf '%s\n' "$legacy_source" >> "$HOME/.tmux.conf"
printf 'font-size = 16\nconfig-file = %s/.config/mriya/ghostty.conf\n' "$HOME" > "$HOME/.config/ghostty/config"
printf 'hyper - x : echo preserved\n' > "$HOME/.config/skhd/skhdrc"
"$root/config/host/install.sh"
cp "$HOME/.codex/config.toml" "$work/installed-codex"
"$root/config/host/install.sh"
cmp "$HOME/.codex/config.toml" "$work/installed-codex"
[ ! -L "$HOME/.config/mriya" ]
cmp "$root/config/host/agent-keys.sh" "$HOME/.config/mriya/agent-keys.sh"
[ "$(grep -c '^# MRIYA-KEYS-BEGIN$' "$HOME/.codex/config.toml")" = 1 ]
if grep -q '^source-file' "$HOME/.tmux.conf"; then exit 1; fi
if grep -q '^config-file' "$HOME/.config/ghostty/config"; then exit 1; fi
[ "$(grep -c '^.load ' "$HOME/.config/skhd/skhdrc")" = 1 ]
grep -Fqx 'hyper - x : echo preserved' "$HOME/.config/skhd/skhdrc"
grep -Fqx 'font-size = 16' "$HOME/.config/ghostty/config"
cmp "$root/config/host/skhdrc" "$HOME/.config/mriya/skhdrc"
[ "$(grep -c '^ctrl + alt + shift - f[1-689] :' "$HOME/.config/mriya/skhdrc")" = 8 ]
if grep -q ' - f7 :' "$HOME/.config/mriya/skhdrc"; then exit 1; fi
grep -Fqx 'model = "existing-model"' "$HOME/.codex/config.toml"
grep -Fqx 'model = "existing-model"' "$HOME/.codex/config.toml.mriya-backup"
printf '\n[tui.keymap.chat]\nopen_presets = ["f2"]\n' >> "$HOME/.codex/config.toml"
cp "$HOME/.codex/config.toml" "$work/with-custom-bindings"
if "$root/config/host/install.sh" 2>/dev/null; then
    printf 'Existing custom keybindings were overwritten\n' >&2; exit 1
fi
cmp "$HOME/.codex/config.toml" "$work/with-custom-bindings"

cp "$work/installed-codex" "$HOME/.codex/config.toml"
mkdir "$work/native"
ln -s "$real_tmux" "$work/native/tmux"
printf '#!/bin/sh\nexit 0\n' > "$work/native/skhd"
chmod +x "$work/native/skhd"
export PATH="$work/native:$original_path"
"$real_tmux" -L "$task_socket" -f /dev/null new-session -d -s check 'sleep 60'
TMUX="$("$real_tmux" -L "$task_socket" display-message -p '#{socket_path}'),0,0"
export TMUX
"$real_tmux" bind-key -n S-F1 run-shell "$HOME/.config/mriya/agent-keys.sh next"
"$real_tmux" bind-key -n S-F5 resize-pane -Z
"$real_tmux" bind-key -n S-F3 display-message user-binding
printf '%s\n' "$legacy_source" >> "$HOME/.tmux.conf"
"$root/config/host/install.sh"
if "$real_tmux" list-keys -T root S-F1 >/dev/null 2>&1; then exit 1; fi
if "$real_tmux" list-keys -T root S-F5 >/dev/null 2>&1; then exit 1; fi
"$real_tmux" list-keys -T root S-F3 | grep -q user-binding
printf 'Host keys: navigation, closed panes, client routing, shell isolation and installer checks passed.\n'
