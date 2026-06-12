#!/usr/bin/env bash
  # Stop hook: kiírja az utolsó assistant válasz tool / Skill / Agent használatait.
  # Input (stdin JSON): { session_id, transcript_path, stop_hook_active, ... }
  # Output (stdout JSON): { systemMessage: "..." } – Claude Code megjeleníti a UI-on.

  set -euo pipefail

  input=$(cat)
  # Diag: minden tüzelést logolunk, hogy tudjuk fut-e a hook egyáltalán
  echo "[$(date -Iseconds)] Stop hook fired" >> /tmp/claude-stop-hook.log
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')

  if [[ -z "$transcript" || ! -f "$transcript" ]]; then
    exit 0
  fi

  # Az utolsó "valódi" user fordulótól (nem tool_result, nem meta) gyűjtjük a
  # közbeeső assistant tool_use-okat.
  summary=$(jq -rs '
    ([ to_entries[]
       | select(
           .value.type == "user"
           and ((.value.isMeta // false) | not)
           and ((.value.isSidechain // false) | not)
           and (
             (.value.message.content | type) == "string"
             or ((.value.message.content | type) == "array"
                 and ((.value.message.content | map(.type)) | any(. != "tool_result")))
           )
         )
       | .key
     ] | (.[-1] // -1)) as $start
    | [ .[ ($start + 1) : ][]
        | select(.type == "assistant" and ((.isSidechain // false) | not))
        | .message.content[]?
        | select(.type == "tool_use")
        | if .name == "Skill" then "Skill:" + (.input.skill // "?")
          elif .name == "Agent" or .name == "Task" then "Agent:" + (.input.subagent_type // "?")
          elif (.name | startswith("mcp__")) then
            (.name | split("__")) as $p
            | "MCP:" + ($p[1] // "?") + ":" + ($p[2] // "?")
          elif .name == "Bash" then
            ((.input.command // "") | sub("^\\s+"; "") | split(" ")[0] // "?") as $cmd
            | if $cmd == "" then "Bash" else "Bash:" + $cmd end
          elif .name == "WebFetch" then
            ((.input.url // "") | capture("^https?://(?<h>[^/]+)").h // "?") as $host
            | "WebFetch:" + $host
          else .name end
      ]
    | reduce .[] as $n ({}; .[$n] = ((.[$n] // 0) + 1))
    | to_entries | sort_by(-.value)
    | map("\(.key)×\(.value)")
    | join(", ")
  ' "$transcript")

  if [[ -z "$summary" ]]; then
    exit 0
  fi

  jq -nc --arg msg "🧰 $summary" '{systemMessage: $msg}'%