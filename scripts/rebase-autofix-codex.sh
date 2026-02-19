#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=""
UPSTREAM_REF="${OPENCLAW_REBASE_AUTOFIX_UPSTREAM_REF:-upstream/main}"
RUN_LOG=""
RESULT_LOG=""
CODEX_BIN="${OPENCLAW_CODEX_BIN:-codex}"
CODEX_MODEL="${OPENCLAW_REBASE_AUTOFIX_MODEL:-}"
CONFLICT_ALLOWLIST="${OPENCLAW_REBASE_AUTOFIX_CONFLICT_ALLOWLIST:-src/config/types.slack.ts,src/config/zod-schema.providers-core.ts,src/slack/monitor/message-handler/dispatch.ts,src/slack/streaming.ts,git-hooks/pre-commit,skills/imsg/SKILL.md,skills/bluebubbles/SKILL.md}"

usage() {
  cat <<'USAGE'
Usage: rebase-autofix-codex.sh --repo <path> [options]

Options:
  --repo <path>         Git repo root (required).
  --upstream <ref>      Upstream ref to rebase onto (default: upstream/main).
  --run-log <path>      Parent hourly update run log (optional).
  --result-log <path>   Dedicated autofix log file (optional).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_ROOT="${2:-}"
      shift 2
      ;;
    --upstream)
      UPSTREAM_REF="${2:-}"
      shift 2
      ;;
    --run-log)
      RUN_LOG="${2:-}"
      shift 2
      ;;
    --result-log)
      RESULT_LOG="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${REPO_ROOT}" ]]; then
  echo "Missing required --repo argument" >&2
  usage >&2
  exit 2
fi

if [[ -z "${RESULT_LOG}" ]]; then
  RESULT_LOG="$(mktemp "/tmp/rebase-autofix-codex.XXXXXX.log")"
fi
mkdir -p "$(dirname -- "${RESULT_LOG}")"

if [[ -n "${RUN_LOG}" ]]; then
  mkdir -p "$(dirname -- "${RUN_LOG}")"
fi

log() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
  printf '%s\n' "${line}" >>"${RESULT_LOG}"
  if [[ -n "${RUN_LOG}" ]]; then
    printf '%s\n' "${line}" >>"${RUN_LOG}"
  fi
  printf '%s\n' "${line}"
}

fail() {
  log "ERROR: $*"
  exit 1
}

git_cmd=(git -C "${REPO_ROOT}")

if ! "${git_cmd[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "not a git repository: ${REPO_ROOT}"
fi

current_branch="$("${git_cmd[@]}" branch --show-current 2>/dev/null || true)"
if [[ "${current_branch}" != "main" ]]; then
  fail "expected branch main, got ${current_branch:-detached}"
fi

is_rebase_in_progress() {
  local rebase_merge rebase_apply
  rebase_merge="$("${git_cmd[@]}" rev-parse --git-path rebase-merge)"
  rebase_apply="$("${git_cmd[@]}" rev-parse --git-path rebase-apply)"
  [[ -d "${rebase_merge}" || -d "${rebase_apply}" ]]
}

abort_rebase_if_needed() {
  if is_rebase_in_progress; then
    log "aborting in-progress rebase"
    "${git_cmd[@]}" rebase --abort >/dev/null 2>&1 || true
  fi
}

repo_is_clean() {
  [[ -z "$("${git_cmd[@]}" status --porcelain -- :!dist/control-ui/)" ]]
}

if ! repo_is_clean; then
  fail "working tree is not clean; refusing autofix"
fi

start_sha="$("${git_cmd[@]}" rev-parse --short HEAD)"
log "autofix start: branch=main head=${start_sha} upstream=${UPSTREAM_REF}"

set +e
"${git_cmd[@]}" rebase "${UPSTREAM_REF}" >>"${RESULT_LOG}" 2>&1
rebase_exit=$?
set -e

if [[ "${rebase_exit}" -eq 0 ]]; then
  end_sha="$("${git_cmd[@]}" rev-parse --short HEAD)"
  log "rebase succeeded without conflicts (${start_sha} -> ${end_sha})"
  exit 0
fi

conflict_files="$("${git_cmd[@]}" diff --name-only --diff-filter=U 2>/dev/null || true)"
if [[ -z "${conflict_files}" ]]; then
  abort_rebase_if_needed
  fail "rebase failed without conflict markers; manual intervention required"
fi

IFS=',' read -r -a allowlist_paths <<<"${CONFLICT_ALLOWLIST}"
trimmed_allowlist=()
for item in "${allowlist_paths[@]}"; do
  item="${item#"${item%%[![:space:]]*}"}"
  item="${item%"${item##*[![:space:]]}"}"
  if [[ -n "${item}" ]]; then
    trimmed_allowlist+=("${item}")
  fi
done

is_allowed_conflict() {
  local path="$1"
  local allowed
  for allowed in "${trimmed_allowlist[@]}"; do
    if [[ "${path}" == "${allowed}" ]]; then
      return 0
    fi
  done
  return 1
}

unexpected_conflicts=()
while IFS= read -r conflict; do
  [[ -z "${conflict}" ]] && continue
  if ! is_allowed_conflict "${conflict}"; then
    unexpected_conflicts+=("${conflict}")
  fi
done <<<"${conflict_files}"

if (( ${#unexpected_conflicts[@]} > 0 )); then
  log "conflicts outside allowlist detected:"
  for conflict in "${unexpected_conflicts[@]}"; do
    log "  - ${conflict}"
  done
  abort_rebase_if_needed
  fail "autofix refused: conflict surface exceeded policy"
fi

if ! command -v "${CODEX_BIN}" >/dev/null 2>&1; then
  abort_rebase_if_needed
  fail "codex binary not found: ${CODEX_BIN}"
fi

log "running Codex conflict resolver"

conflict_summary="$(printf '%s\n' "${conflict_files}")"
allowlist_summary="$(printf '%s\n' "${trimmed_allowlist[@]}")"

read -r -d '' prompt <<EOF || true
Resolve the active git rebase conflicts in ${REPO_ROOT} with a strict upstream-first policy.

Current conflicted files:
${conflict_summary}

Allowed conflict surface:
${allowlist_summary}

Rules:
1. Prefer upstream behavior and keep local patch surface minimal.
2. Do not edit unrelated files.
3. If any new conflict appears outside the allowed list, abort the rebase and stop.
4. If you cannot confidently preserve intended behavior, abort the rebase and stop.
5. Complete the rebase cleanly (no unresolved conflicts, no staged/unstaged leftovers).

Run git commands directly, finish the rebase if safe, and leave the repo clean.
EOF

codex_cmd=("${CODEX_BIN}" exec --dangerously-bypass-approvals-and-sandbox --cd "${REPO_ROOT}" --color never)
if [[ -n "${CODEX_MODEL}" ]]; then
  codex_cmd+=(--model "${CODEX_MODEL}")
fi

set +e
printf '%s\n' "${prompt}" | "${codex_cmd[@]}" - >>"${RESULT_LOG}" 2>&1
codex_exit=$?
set -e

if [[ "${codex_exit}" -ne 0 ]]; then
  abort_rebase_if_needed
  fail "codex resolver failed (exit=${codex_exit})"
fi

remaining_conflicts="$("${git_cmd[@]}" diff --name-only --diff-filter=U 2>/dev/null || true)"
if [[ -n "${remaining_conflicts}" ]]; then
  abort_rebase_if_needed
  fail "resolver left unresolved conflicts"
fi

if is_rebase_in_progress; then
  abort_rebase_if_needed
  fail "resolver left rebase in progress"
fi

if ! repo_is_clean; then
  fail "resolver left working tree dirty"
fi

read -r ahead behind <<<"$("${git_cmd[@]}" rev-list --left-right --count "main...${UPSTREAM_REF}" 2>/dev/null || printf '')"
if ! [[ "${ahead:-}" =~ ^[0-9]+$ ]] || ! [[ "${behind:-}" =~ ^[0-9]+$ ]]; then
  fail "unable to validate branch divergence after resolver run"
fi
if (( behind > 0 )); then
  fail "main is still behind ${UPSTREAM_REF} by ${behind} commit(s)"
fi

end_sha="$("${git_cmd[@]}" rev-parse --short HEAD)"
log "autofix complete (${start_sha} -> ${end_sha})"
exit 0
