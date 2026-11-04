#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

set -euo pipefail
cd "$(dirname "$0")/.."
install_test_dir=$(mktemp -d)
trap 'command rm -rf "$install_test_dir"' EXIT

# Run the real installation block against disposable bundles. No process is
# stopped and no app under /Applications is read, removed or installed.
sed -n '/^if (( INSTALL )); then$/,$p' build.sh \
    | sed 's|/Applications|$install_test_dir/Applications|g' > "$install_test_dir/install.zsh"
[[ -s "$install_test_dir/install.zsh" ]]
mkdir -p "$install_test_dir/Applications" "$install_test_dir/stage"
print new > "$install_test_dir/stage/content"
INSTALL=1
STAGE="$install_test_dir/stage"
stopped=()
signed=()
stop_process() { stopped+=("$1"); }
sign_installed_bundle() { signed+=("$1"); }

for variant in developer official fork; do
    DEV=0
    FORK=0
    stopped=()
    signed=()
    for name in Vorss 'Vorssaint Utils' Vorssaint 'Vorssaint (Developer)' 'Menu Utility MCP'; do
        mkdir -p "$install_test_dir/Applications/$name.app"
        print original > "$install_test_dir/Applications/$name.app/content"
    done
    if [[ "$variant" == developer ]]; then
        DEV=1
        APP_NAME='Vorssaint (Developer)'
        EXECUTABLE=VorssaintDeveloper
    elif [[ "$variant" == fork ]]; then
        FORK=1
        APP_NAME='Menu Utility MCP'
        EXECUTABLE=MenuUtilityMCP
    else
        APP_NAME=Vorssaint
        EXECUTABLE=Vorssaint
    fi
    source "$install_test_dir/install.zsh"
    [[ "$(cat "$install_test_dir/Applications/$APP_NAME.app/content")" == new ]]
    [[ "${signed[*]}" == "$install_test_dir/Applications/$APP_NAME.app" ]]
    if (( DEV )); then
        [[ "${stopped[*]}" == VorssaintDeveloper ]]
        for name in Vorss 'Vorssaint Utils' Vorssaint 'Menu Utility MCP'; do
            [[ "$(cat "$install_test_dir/Applications/$name.app/content")" == original ]]
        done
    elif (( FORK )); then
        [[ "${stopped[*]}" == MenuUtilityMCP ]]
        for name in Vorss 'Vorssaint Utils' Vorssaint 'Vorssaint (Developer)'; do
            [[ "$(cat "$install_test_dir/Applications/$name.app/content")" == original ]]
        done
    else
        [[ "${stopped[*]}" == 'Vorssaint Vorss VorssaintUtils' ]]
        [[ ! -e "$install_test_dir/Applications/Vorss.app" ]]
        [[ ! -e "$install_test_dir/Applications/Vorssaint Utils.app" ]]
        [[ "$(cat "$install_test_dir/Applications/Vorssaint (Developer).app/content")" == original ]]
        [[ "$(cat "$install_test_dir/Applications/Menu Utility MCP.app/content")" == original ]]
    fi
done
print 'DEVELOPER INSTALL ISOLATION TESTS OK'
