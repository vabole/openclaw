# Fork Customizations (vabole/openclaw)

This fork tracks `openclaw/openclaw` upstream with a small set of local changes.
Ops automation (sync, rebase) lives in `vabole/openclaw-ops`.

## Active customizations

### 1. Browser tool: download actions

**Files:** `src/agents/tools/browser-tool.ts`, `browser-tool.schema.ts`, `browser-tool.e2e.test.ts`

Adds `download` and `waitForDownload` actions to the browser tool. Allows agents to
download files by element ref or wait for an in-progress download to complete.
Includes schema additions (`path` param, new action types) and full test coverage.

### 2. Slack: native slash command aliases

**Files:** `src/slack/monitor/slash.ts`

Rewrites native Slack command registration to also register `textAliases` as
separate Slack slash commands (deduped). Upstream only registers the primary
command name; this gives broader slash command coverage. Also simplifies prompt
construction and cleans up a type cast in the options handler.

### 3. Commands registry: nativeName for allowlist/bash

**Files:** `src/auto-reply/commands-registry.data.ts`

Adds `nativeName` to the `allowlist` and `bash` command definitions and removes
their `scope: "text"` restriction, making them available as native Slack slash
commands (not just text-parsed).

### 4. transcribe.sh: executable permission

**Files:** `skills/openai-whisper-api/scripts/transcribe.sh`

Upstream ships this as 644 (not executable). Fork fixes to 755. Upstream bug —
candidate for a one-line PR.

## Related repos

| Repo                     | Purpose                                                   |
| ------------------------ | --------------------------------------------------------- |
| `vabole/openclaw-ops`    | Fork sync automation (mirror-main, rebase, notifications) |
| `vabole/openclaw-config` | Runtime config at `~/.openclaw`                           |
