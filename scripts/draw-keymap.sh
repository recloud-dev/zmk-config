#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
export KEYMAP_SVG_DIR="$work"

keymap draw docs/keymap-proposed.yaml -o docs/keymap-proposed.svg
index=0
while IFS= read -r layer; do
    keymap draw docs/keymap-proposed.yaml --keys-only -s "$layer" -o "$work/$index.svg"
    index=$((index + 1))
done <<'LAYERS'
0 · Основной — EN / RU
1 · FN — функции / агенты
2 · Мышь — движение / прокрутка
3 · SYM — цифры / символы
4 · NAV — редактирование текста
5 · SETUP — Bluetooth / прошивка
6 · Мышь ×4 — прокрутка ×2
7 · Мышь ×8 — прокрутка ×4
8 · Мышь ×2 — прокрутка ×1.5
LAYERS
keymap draw docs/keymap-proposed.yaml --combos-only -s '0 · Основной — EN / RU' -o "$work/COMBOS.svg"
perl -0pe 's!\{\{SVG_(\d+|COMBOS)\}\}!do {
    open my $svg, "<", "$ENV{KEYMAP_SVG_DIR}/$1.svg" or die "Cannot read generated SVG";
    local $/;
    <$svg>
}!ge' scripts/keymap-viewer.template.html > docs/keymap-proposed.html
rsvg-convert --background-color white --width 1600 \
    --output docs/keymap-proposed-base.png "$work/0.svg"
printf 'Rendered 9 layers and combo diagrams.\n'
