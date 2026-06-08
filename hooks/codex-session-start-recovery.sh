#!/usr/bin/env bash
# Superflow Codex SessionStart hook.
# Prints a compact recovery bundle for Codex resumes/startups.

set +e

INPUT=""
if [ ! -t 0 ]; then
  INPUT="$(cat 2>/dev/null || true)"
fi

CWD=""
if command -v jq >/dev/null 2>&1 && [ -n "$INPUT" ] && printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // .project_cwd // .workspace.cwd // empty' 2>/dev/null)"
fi
CWD="${CWD:-${CODEX_CWD:-${CLAUDE_PROJECT_DIR:-${CLAUDE_CODE_CWD:-$PWD}}}}"

if [ ! -d "$CWD" ]; then
  CWD="$PWD"
fi

find_project_root() {
  local dir="$1"
  local prev=""

  dir="$(cd "$dir" 2>/dev/null && pwd -P)"
  while [ -n "$dir" ] && [ "$dir" != "$prev" ]; do
    if [ -f "$dir/.superflow-state.json" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    prev="$dir"
    dir="$(dirname "$dir")"
  done

  return 1
}

print_excerpt() {
  local path="$1"
  local lines="$2"
  local label="$3"
  local total_lines=""

  if [ ! -r "$path" ]; then
    return 0
  fi

  printf '## %s\n' "$label"
  printf 'Path: %s\n\n' "$path"
  sed -n "1,${lines}p" "$path" 2>/dev/null
  total_lines="$(wc -l < "$path" 2>/dev/null)"
  if [ -n "$total_lines" ] && [ "$total_lines" -gt "$lines" ]; then
    printf '\n[truncated: showing first %s of %s lines]\n' "$lines" "$total_lines"
  fi
  printf '\n'
}

PROJECT_ROOT="$(find_project_root "$CWD" 2>/dev/null)"
AGENTS_PATH=""
for path in "$HOME/.codex/AGENTS.md" "$HOME/codex/AGENTS.md"; do
  if [ -r "$path" ]; then
    AGENTS_PATH="$path"
    break
  fi
done

if [ -z "$PROJECT_ROOT" ] && [ -z "$AGENTS_PATH" ]; then
  exit 0
fi

printf '# Superflow Codex Recovery Bundle\n\n'
printf 'Working directory: %s\n' "$CWD"
if [ -n "$PROJECT_ROOT" ]; then
  printf 'Superflow project: %s\n' "$PROJECT_ROOT"
else
  printf 'Superflow project: not detected\n'
fi
printf '\n'

if [ -n "$AGENTS_PATH" ]; then
  printf 'Durable instruction file: %s\n' "$AGENTS_PATH"
  printf 'Recovery rule: after compaction, re-read this file, .superflow-state.json, and the latest .superflow/compact-log dump if present.\n\n'
  print_excerpt "$AGENTS_PATH" 90 "AGENTS.md Excerpt"
fi

if [ -n "$PROJECT_ROOT" ]; then
  print_excerpt "$PROJECT_ROOT/.superflow-state.json" 220 ".superflow-state.json"

  COMPACT_DIR="$PROJECT_ROOT/.superflow/compact-log"
  if [ -d "$COMPACT_DIR" ]; then
    LATEST_DUMP="$(find "$COMPACT_DIR" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {sub(/^[^ ]+ /, ""); print; exit}')"
    if [ -n "$LATEST_DUMP" ]; then
      print_excerpt "$LATEST_DUMP" 160 "Latest Compact Log Excerpt"
    else
      printf '## Latest Compact Log Excerpt\nPath: none found in %s\n\n' "$COMPACT_DIR"
    fi
  else
    printf '## Latest Compact Log Excerpt\nPath: %s does not exist yet\n\n' "$COMPACT_DIR"
  fi
fi

exit 0
