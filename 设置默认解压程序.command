#!/bin/bash
set -u

if [[ $EUID -eq 0 ]]; then
    printf '%s\n' '请退出管理员终端，在你平时使用的账户里双击运行此脚本。'
    exit 1
fi

app='/Applications/夏威夷果开罐器.app'
executable="$app/Contents/MacOS/ArchiveHere"
if [[ ! -x "$executable" ]]; then
    printf '%s\n' '请先打开「安装夏威夷果开罐器」，完成第一步。'
    exit 1
fi

registrar='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
if [[ -x "$registrar" ]]; then
    "$registrar" -f "$app" >/dev/null 2>&1 || true
fi
exec "$executable" --set-defaults
