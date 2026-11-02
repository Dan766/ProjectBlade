#!/usr/bin/env bash
# Godot helpers for agents (Git Bash on Windows).
#   tools/godot.sh import            # (re)import the project; needed after adding class_name scripts
#   tools/godot.sh test              # headless GDScript tests; exit 1 on any failure or SCRIPT ERROR
#   tools/godot.sh shot <png> [args] # open the game window, save a screenshot + FPS, quit
#                                    # args are passed to the game, e.g. --zoom=0.25 --travel
set -u
GODOT="${GODOT:-$LOCALAPPDATA/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.7.2-stable_win64_console.exe}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAME="$ROOT/game"

case "${1:-}" in
  import)
    "$GODOT" --headless --path "$GAME" --import 2>&1 | grep -vE "^\s*$" | tail -20
    ;;
  test)
    out="$("$GODOT" --headless --path "$GAME" -s res://tests/run_tests.gd 2>&1)"
    code=$?
    echo "$out" | grep -vE "^Godot Engine|^\s*$"
    if echo "$out" | grep -qE "SCRIPT ERROR|Parse Error|Failed to load script"; then
      echo "godot.sh: script errors found -> FAIL"; exit 1
    fi
    exit $code
    ;;
  shot)
    png="$2"; shift 2
    "$GODOT" --path "$GAME" --windowed --resolution 1600x900 -- --screenshot="$png" "$@" 2>&1 | grep -E "AUTO|ERROR|error"
    ;;
  *)
    echo "usage: tools/godot.sh import|test|shot <png> [args]"; exit 2
    ;;
esac
