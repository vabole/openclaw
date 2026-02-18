#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# Cron/launchd shells can have a minimal PATH that breaks `openclaw`/`node`.
PATH_PREFIX="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
if [[ -n "${PATH:-}" ]]; then
  export PATH="${PATH_PREFIX}:${PATH}"
else
  export PATH="${PATH_PREFIX}"
fi

OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
NODE_BIN="${OPENCLAW_NODE_BIN:-}"
UPDATE_TIMEOUT_SECONDS="${OPENCLAW_UPDATE_TIMEOUT_SECONDS:-1200}"
APPLY_ON_SUCCESS="${OPENCLAW_APPLY_ON_SUCCESS:-1}"
SYNC_ORIGIN_ON_SUCCESS="${OPENCLAW_SYNC_ORIGIN_ON_SUCCESS:-1}"
SYNC_REMOTE="${OPENCLAW_SYNC_REMOTE:-origin}"
SYNC_BRANCH="${OPENCLAW_SYNC_BRANCH:-main}"
SYNC_FORCE_WITH_LEASE="${OPENCLAW_SYNC_FORCE_WITH_LEASE:-1}"

NOTIFY_CHANNEL="${OPENCLAW_NOTIFY_CHANNEL:-slack}"
NOTIFY_TARGET="${OPENCLAW_NOTIFY_TARGET:-}"
NOTIFY_ACCOUNT="${OPENCLAW_NOTIFY_ACCOUNT:-}"
NOTIFY_THREAD_ID="${OPENCLAW_NOTIFY_THREAD_ID:-}"
NOTIFY_ON_NO_CHANGE="${OPENCLAW_NOTIFY_ON_NO_CHANGE:-0}"
NOTIFY_MAX_CHARS="${OPENCLAW_NOTIFY_MAX_CHARS:-3500}"

STATE_DIR="${OPENCLAW_UPDATE_STATE_DIR:-${HOME}/.openclaw}"
LOCK_DIR="${OPENCLAW_UPDATE_LOCK_DIR:-${STATE_DIR}/locks/hourly-update.lock}"
LOG_DIR="${OPENCLAW_UPDATE_LOG_DIR:-${STATE_DIR}/logs/hourly-update}"

RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${LOG_DIR}/${RUN_TS}"
RUN_LOG="${RUN_DIR}/run.log"
UPDATE_JSON="${RUN_DIR}/update-result.json"

mkdir -p "${RUN_DIR}" "$(dirname -- "${LOCK_DIR}")"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${RUN_LOG}" >/dev/null
}

cleanup_lock() {
  if [[ -d "${LOCK_DIR}" ]] && [[ -f "${LOCK_DIR}/pid" ]]; then
    local lock_pid
    lock_pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    if [[ "${lock_pid}" == "$$" ]]; then
      rm -rf "${LOCK_DIR}" || true
    fi
  fi
}

acquire_lock() {
  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    printf '%s\n' "$$" >"${LOCK_DIR}/pid"
    trap cleanup_lock EXIT
    return 0
  fi

  local existing_pid=""
  if [[ -f "${LOCK_DIR}/pid" ]]; then
    existing_pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
  fi

  if [[ -n "${existing_pid}" ]] && [[ "${existing_pid}" =~ ^[0-9]+$ ]] && kill -0 "${existing_pid}" 2>/dev/null; then
    log "another update run is already active (pid ${existing_pid}); exiting"
    exit 0
  fi

  log "stale update lock detected; clearing and retrying"
  rm -rf "${LOCK_DIR}" || true
  mkdir "${LOCK_DIR}"
  printf '%s\n' "$$" >"${LOCK_DIR}/pid"
  trap cleanup_lock EXIT
}

send_notification() {
  local text="$1"

  if [[ -z "${NOTIFY_TARGET}" ]]; then
    log "notification skipped: OPENCLAW_NOTIFY_TARGET is not set"
    return 0
  fi

  if [[ "${NOTIFY_MAX_CHARS}" =~ ^[0-9]+$ ]] && (( ${#text} > NOTIFY_MAX_CHARS )); then
    text="${text:0:NOTIFY_MAX_CHARS}"
  fi

  local cmd=("${OPENCLAW_BIN}" message send --channel "${NOTIFY_CHANNEL}" --target "${NOTIFY_TARGET}" --message "${text}")
  if [[ -n "${NOTIFY_ACCOUNT}" ]]; then
    cmd+=(--account "${NOTIFY_ACCOUNT}")
  fi
  if [[ -n "${NOTIFY_THREAD_ID}" ]]; then
    cmd+=(--thread-id "${NOTIFY_THREAD_ID}")
  fi

  if "${cmd[@]}" >>"${RUN_LOG}" 2>&1; then
    log "notification sent via ${NOTIFY_CHANNEL}:${NOTIFY_TARGET}"
    return 0
  fi

  log "notification failed via ${NOTIFY_CHANNEL}:${NOTIFY_TARGET}"
  return 1
}

should_apply_on_success() {
  case "${APPLY_ON_SUCCESS}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

should_sync_origin_on_success() {
  case "${SYNC_ORIGIN_ON_SUCCESS}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

should_sync_force_with_lease() {
  case "${SYNC_FORCE_WITH_LEASE}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_node_bin() {
  if [[ -n "${NODE_BIN}" ]]; then
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    NODE_BIN="$(command -v node)"
    return 0
  fi
  if [[ -x "/opt/homebrew/bin/node" ]]; then
    NODE_BIN="/opt/homebrew/bin/node"
    return 0
  fi
  if [[ -x "/usr/local/bin/node" ]]; then
    NODE_BIN="/usr/local/bin/node"
    return 0
  fi
  return 1
}

sync_origin_branch() {
  git -C "${REPO_ROOT}" fetch "${SYNC_REMOTE}" "${SYNC_BRANCH}" >>"${RUN_LOG}" 2>&1

  local remote_ref="refs/remotes/${SYNC_REMOTE}/${SYNC_BRANCH}"
  if ! git -C "${REPO_ROOT}" rev-parse --verify "${remote_ref}" >/dev/null 2>&1; then
    log "sync remote branch not found: ${remote_ref}"
    return 1
  fi

  local local_only="0"
  local remote_only="0"
  read -r local_only remote_only <<<"$(git -C "${REPO_ROOT}" rev-list --left-right --count "HEAD...${remote_ref}")"

  if (( local_only == 0 && remote_only == 0 )); then
    log "remote already in sync (${SYNC_REMOTE}/${SYNC_BRANCH}); push skipped"
    printf 'no-change\n'
    return 0
  fi

  if (( local_only > 0 && remote_only == 0 )); then
    log "pushing ${local_only} commit(s) to ${SYNC_REMOTE}/${SYNC_BRANCH}"
    git -C "${REPO_ROOT}" push "${SYNC_REMOTE}" "HEAD:${SYNC_BRANCH}" >>"${RUN_LOG}" 2>&1
    printf 'push\n'
    return 0
  fi

  local remote_sha
  remote_sha="$(git -C "${REPO_ROOT}" rev-parse "${remote_ref}")"
  if should_sync_force_with_lease; then
    log "remote diverged (local=${local_only} remote=${remote_only}); force-with-lease push to ${SYNC_REMOTE}/${SYNC_BRANCH}"
    git -C "${REPO_ROOT}" push \
      --force-with-lease="${SYNC_BRANCH}:${remote_sha}" \
      "${SYNC_REMOTE}" \
      "HEAD:${SYNC_BRANCH}" >>"${RUN_LOG}" 2>&1
    printf 'force-with-lease\n'
    return 0
  fi

  log "remote diverged (local=${local_only} remote=${remote_only}); set OPENCLAW_SYNC_FORCE_WITH_LEASE=1 to auto-sync"
  return 1
}

main_upstream_divergence_counts() {
  local branch
  branch="$(git -C "${REPO_ROOT}" branch --show-current 2>/dev/null || true)"
  if [[ "${branch}" != "main" ]]; then
    return 1
  fi

  if ! git -C "${REPO_ROOT}" rev-parse --verify refs/remotes/upstream/main >/dev/null 2>&1; then
    return 1
  fi

  local ahead behind
  read -r ahead behind <<<"$(git -C "${REPO_ROOT}" rev-list --left-right --count "main...upstream/main" 2>/dev/null || printf '')"
  if ! [[ "${ahead:-}" =~ ^[0-9]+$ ]] || ! [[ "${behind:-}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if (( ahead > 0 && behind > 0 )); then
    printf '%s %s\n' "${ahead}" "${behind}"
    return 0
  fi
  return 1
}

parse_update_json() {
  if ! resolve_node_bin; then
    log "node runtime not found; set OPENCLAW_NODE_BIN to parse update json"
    printf '\x1f\x1f\x1f\x1f\x1f\x1f'
    return 0
  fi

  "${NODE_BIN}" - "${UPDATE_JSON}" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
const SEP = "\u001f";

function extractFirstJsonObject(raw) {
  const start = raw.indexOf("{");
  if (start < 0) {
    return null;
  }
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < raw.length; i += 1) {
    const ch = raw[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === "\\\\") {
        escaped = true;
      } else if (ch === "\"") {
        inString = false;
      }
      continue;
    }
    if (ch === "\"") {
      inString = true;
      continue;
    }
    if (ch === "{") {
      depth += 1;
      continue;
    }
    if (ch === "}") {
      depth -= 1;
      if (depth === 0) {
        return raw.slice(start, i + 1);
      }
    }
  }
  return null;
}

try {
  const raw = fs.readFileSync(file, "utf8");
  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    const firstObject = extractFirstJsonObject(raw);
    if (!firstObject) {
      throw new Error("no-json-object");
    }
    data = JSON.parse(firstObject);
  }
  const steps = Array.isArray(data?.steps) ? data.steps : [];
  const upstreamRef =
    steps.find(
      (step) =>
        typeof step?.command === "string" &&
        step.command.includes("rev-parse --abbrev-ref --symbolic-full-name @{upstream}")
    )?.stdoutTail ?? "";
  const upstreamSha =
    steps.find(
      (step) => typeof step?.command === "string" && step.command.includes("rev-parse @{upstream}")
    )?.stdoutTail ?? "";

  const fields = [
    data?.status ?? "",
    data?.mode ?? "",
    data?.reason ?? "",
    data?.before?.sha ?? "",
    data?.after?.sha ?? "",
    data?.before?.version ?? "",
    data?.after?.version ?? "",
    upstreamRef,
    upstreamSha,
  ];
  process.stdout.write(fields.map((v) => String(v).replace(/\u001f/g, " ")).join(SEP));
} catch {
  process.stdout.write(["", "", "", "", "", "", "", "", ""].join(SEP));
}
NODE
}

build_commit_summary() {
  local before_sha="$1"
  local after_sha="$2"
  local upstream_ref="${3:-}"
  local upstream_sha="${4:-}"

  if [[ -n "${before_sha}" ]] && [[ -n "${upstream_sha}" ]]; then
    local upstream_base
    upstream_base="$(git -C "${REPO_ROOT}" merge-base "${before_sha}" "${upstream_sha}" 2>/dev/null || true)"
    if [[ -n "${upstream_base}" ]]; then
      local upstream_compare_url="https://github.com/openclaw/openclaw/compare/${upstream_base}...${upstream_sha}"
      local upstream_commit_count
      upstream_commit_count="$(git -C "${REPO_ROOT}" rev-list --count "${upstream_base}..${upstream_sha}" 2>/dev/null || printf '0')"

      local upstream_commits
      upstream_commits="$(git -C "${REPO_ROOT}" log --no-merges --pretty=format:'- %h %s' "${upstream_base}..${upstream_sha}" 2>/dev/null | head -n 12 || true)"

      if [[ -z "${upstream_commits}" ]]; then
        upstream_commits="- (no upstream commit subjects available)"
      fi

      printf 'Upstream: %s (%s -> %s)\nUpstream commits: %s\n%s\nUpstream compare: %s\n' \
        "${upstream_ref:-@{upstream}}" \
        "${upstream_base:0:8}" \
        "${upstream_sha:0:8}" \
        "${upstream_commit_count}" \
        "${upstream_commits}" \
        "${upstream_compare_url}"
      return 0
    fi
  fi

  local compare_url="https://github.com/openclaw/openclaw/compare/${before_sha}...${after_sha}"
  local commit_count
  commit_count="$(git -C "${REPO_ROOT}" rev-list --count "${before_sha}..${after_sha}" 2>/dev/null || printf '0')"

  local commits
  commits="$(git -C "${REPO_ROOT}" log --no-merges --pretty=format:'- %h %s' "${before_sha}..${after_sha}" 2>/dev/null | head -n 12 || true)"

  if [[ -z "${commits}" ]]; then
    commits="- (no commit subjects available)"
  fi

  printf 'Commits: %s\n%s\nCompare: %s\n' "${commit_count}" "${commits}" "${compare_url}"
}

if ! [[ "${UPDATE_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || (( UPDATE_TIMEOUT_SECONDS <= 0 )); then
  echo "OPENCLAW_UPDATE_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

acquire_lock

log "starting hourly update (repo=${REPO_ROOT})"

cd "${REPO_ROOT}"

set +e
"${OPENCLAW_BIN}" update --json --no-restart --yes --timeout "${UPDATE_TIMEOUT_SECONDS}" >"${UPDATE_JSON}" 2>>"${RUN_LOG}"
update_exit=$?
set -e

IFS=$'\x1f' read -r status mode reason before_sha after_sha before_version after_version upstream_ref upstream_sha <<<"$(parse_update_json)"

host_label="$(hostname -s 2>/dev/null || hostname || echo unknown-host)"
short_before="${before_sha:0:8}"
short_after="${after_sha:0:8}"

changed="0"
if [[ -n "${before_sha}" ]] && [[ -n "${after_sha}" ]] && [[ "${before_sha}" != "${after_sha}" ]]; then
  changed="1"
fi

if [[ "${update_exit}" -eq 0 ]] && [[ "${status}" == "ok" ]]; then
  log "update finished successfully (mode=${mode:-unknown} before=${short_before:-n/a} after=${short_after:-n/a})"

  applied_label="not-requested"
  if [[ "${changed}" == "1" ]] && should_apply_on_success; then
    log "applying update by restarting gateway service"
    if "${OPENCLAW_BIN}" gateway restart >>"${RUN_LOG}" 2>&1; then
      applied_label="gateway-restarted"
      log "gateway restart completed"
    else
      log "gateway restart failed after successful update"
      restart_failure_message=$(cat <<MSG
OpenClaw update applied partially on ${host_label}
Update fetched successfully but gateway restart failed.
Mode: ${mode:-unknown}
Version: ${before_version:-unknown} -> ${after_version:-unknown}
Commit: ${short_before:-n/a} -> ${short_after:-n/a}
Log: ${RUN_LOG}
MSG
)
      send_notification "${restart_failure_message}" || true
      exit 1
    fi
  elif [[ "${changed}" == "1" ]]; then
    applied_label="disabled"
    log "successful update detected but apply step is disabled"
  else
    applied_label="no-change"
  fi

  sync_label="disabled"
  if should_sync_origin_on_success; then
    log "syncing local branch to ${SYNC_REMOTE}/${SYNC_BRANCH}"
    if sync_result="$(sync_origin_branch)"; then
      case "${sync_result}" in
        force-with-lease)
          sync_label="force-with-lease"
          ;;
        push)
          sync_label="push"
          ;;
        *)
          sync_label="no-change"
          ;;
      esac
      log "remote sync completed (${SYNC_REMOTE}/${SYNC_BRANCH})"
    else
      sync_label="failed"
      log "remote sync failed (${SYNC_REMOTE}/${SYNC_BRANCH})"
      sync_failure_message=$(cat <<MSG
OpenClaw update succeeded but remote sync failed on ${host_label}
Remote: ${SYNC_REMOTE}/${SYNC_BRANCH}
Mode: ${mode:-unknown}
Version: ${before_version:-unknown} -> ${after_version:-unknown}
Commit: ${short_before:-n/a} -> ${short_after:-n/a}
Applied: ${applied_label}
Gateway remains running on current local commit.
Log: ${RUN_LOG}
MSG
)
      send_notification "${sync_failure_message}" || true
      exit 1
    fi
  fi

  if [[ "${changed}" == "1" ]]; then
    commit_summary="$(build_commit_summary "${before_sha}" "${after_sha}" "${upstream_ref}" "${upstream_sha}")"
    success_message=$(cat <<MSG
OpenClaw update success on ${host_label}
Mode: ${mode:-unknown}
${commit_summary}
Version: ${before_version:-unknown} -> ${after_version:-unknown}
Local head: ${short_before:-n/a} -> ${short_after:-n/a}
Applied: ${applied_label}
Sync: ${sync_label} (${SYNC_REMOTE}/${SYNC_BRANCH})
MSG
)
    send_notification "${success_message}" || true
  elif [[ "${NOTIFY_ON_NO_CHANGE}" == "1" || "${NOTIFY_ON_NO_CHANGE}" == "true" ]]; then
    no_change_message=$(cat <<MSG
OpenClaw update check succeeded on ${host_label}
Mode: ${mode:-unknown}
No upstream code changes were applied.
Version: ${before_version:-unknown}
Commit: ${short_after:-n/a}
Applied: ${applied_label}
Sync: ${sync_label} (${SYNC_REMOTE}/${SYNC_BRANCH})
MSG
)
    send_notification "${no_change_message}" || true
  else
    log "no code changes detected; success notification suppressed"
  fi

  exit 0
fi

if [[ "${update_exit}" -ne 0 ]] && [[ "${status}" == "error" ]] && [[ "${reason}" == "rebase-failed" ]]; then
  if divergence_counts="$(main_upstream_divergence_counts)"; then
    read -r ahead_count behind_count <<<"${divergence_counts}"
    log "rebase conflict on diverged main (ahead=${ahead_count} behind=${behind_count}); manual merge required"
    diverged_message=$(cat <<MSG
OpenClaw update paused on ${host_label}
Reason: rebase conflict while local main diverges from upstream/main.
Local main vs upstream/main: ahead=${ahead_count} behind=${behind_count}
Action: merge/rebase upstream/main into local main manually, then rerun update.
Log: ${RUN_LOG}
MSG
)
    send_notification "${diverged_message}" || true
    exit 0
  fi
fi

log "update did not complete cleanly (exit=${update_exit} status=${status:-unknown} reason=${reason:-unknown})"

failure_message=$(cat <<MSG
OpenClaw update failed on ${host_label}
Exit code: ${update_exit}
Status: ${status:-unknown}
Mode: ${mode:-unknown}
Reason: ${reason:-unknown}
Version: ${before_version:-unknown} -> ${after_version:-unknown}
Commit: ${short_before:-n/a} -> ${short_after:-n/a}
Log: ${RUN_LOG}
MSG
)

send_notification "${failure_message}" || true

exit 1
