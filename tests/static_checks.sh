#!/bin/sh
# Catches plugin mistakes that compile fine in Lua but fail only on a device:
#  1. undeclared globals (e.g. a local used outside its function);
#  2. `self:method()` calls with no definition in the plugin or in KOReader's
#     widget base classes (e.g. a helper removed in a refactor);
#  3. icon names that do not exist in KOReader (shown as a warning triangle).
# Checks 2 and 3 need a KOReader install; set KOREADER_DIR (default
# /usr/lib/koreader) or they are skipped.
set -eu
cd "$(dirname "$0")/../coppice.koplugin"
KO=${KOREADER_DIR:-/usr/lib/koreader}
out=$(mktemp)
trap 'rm -f "$out"' EXIT

allow='^(_G|_VERSION|assert|collectgarbage|coroutine|debug|dofile|error|getfenv|getmetatable|io|ipairs|jit|load|loadfile|loadstring|math|module|next|os|package|pairs|pcall|print|rawequal|rawget|rawlen|rawset|require|select|setfenv|setmetatable|string|table|tonumber|tostring|type|unpack|xpcall|bit|G_reader_settings|G_defaults)$'
for m in *.lua; do
    luajit -bl "$m" | sed -nE 's/.*(GGET|GSET).*; "([A-Za-z_][A-Za-z0-9_]*)"$/\2/p' | sort -u |
        while read -r name; do
            echo "$name" | grep -qE "$allow" || echo "$m: undeclared global $name" >>"$out"
        done
done

# KOReader's VerticalSpan reads its height from `width`; `height` is ignored
# and silently gives a zero-height gap.
grep -n 'VerticalSpan:new{ *height' ./*.lua | sed 's/^/VerticalSpan needs width, not height: /' >>"$out" || true

# `_` is KOReader's gettext function; binding it as a throwaway loop or
# local variable shadows it, and any `_("...")` inside then calls a number.
grep -nE '\bfor _ *[,=]|\blocal _ *,|function *\( *_ *[,)]' ./*.lua |
    sed 's/^/shadows gettext `_`: /' >>"$out" || true

if [ -d "$KO/frontend" ]; then
    W=$KO/frontend/ui/widget
    base=$(grep -ohE 'function [A-Za-z]+:[a-zA-Z_]+' "$W/container/inputcontainer.lua" \
        "$W/container/widgetcontainer.lua" "$W/widget.lua" "$W/eventlistener.lua" | sed 's/.*://')
    defined=$(cat ./*.lua | grep -oE '(function [A-Za-z_]+[:.]|[A-Za-z_]+\.)[a-zA-Z_]+ *(\(|= *function)' |
        sed -E 's/.*[:.]([a-zA-Z_]+).*/\1/')
    known=$(printf '%s\n%s\n' "$base" "$defined" | sort -u)
    for m in *.lua; do
        grep -oE 'self:[a-zA-Z_]+\(' "$m" | sed 's/self://; s/($//' | sort -u | while read -r c; do
            echo "$known" | grep -qx "$c" || echo "$m: self:$c() is not defined" >>"$out"
        done
    done
    I=$KO/resources/icons
    grep -ohE '"[a-z][a-z0-9.-]*"' ./*.lua | tr -d '"' | sort -u | while read -r name; do
        # Only names used as icons: next to an `icon` key on the same line.
        grep -qE "icon[a-z_]* *=[^,}]*\"$name\"" ./*.lua || continue
        [ -e "$I/mdlight/$name.svg" ] || [ -e "$I/mdlight/$name.png" ] ||
            [ -e "$I/$name.svg" ] || [ -e "$I/$name.png" ] ||
            echo "icon \"$name\" does not exist in KOReader" >>"$out"
    done
else
    echo "static_checks: $KO not found; method and icon checks skipped"
fi

if [ -s "$out" ]; then cat "$out"; exit 1; fi
echo "static_checks: globals, methods, icons and gettext ok"
