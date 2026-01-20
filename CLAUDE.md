## Purpose

`ai-shell` is a small prototype that adds an `ai-run ...` helper to zsh:
- You type a natural-language request and it asks an OpenAI-compatible LLM endpoint (Bifrost).
- If the model returns commands, you pick one via `fzf` and it injects the command into your prompt with a trailing `# ...` comment so it is searchable in shell history.

The long-term goal is to evolve this into a composable tool with multiple modes/presets, good streaming UX, and optional terminal UI enhancements.

## Current Stage (Prototype)

Implemented:
- `bin/ai-shell-llm`: stateless single-prompt client for OpenAI-compatible `/v1/chat/completions` with streaming output and a spinner while waiting for the first token.
- `zsh/ai-shell-simple.zsh`: zsh integration with `ai-run` plus an optional Ctrl+K ZLE wrapper (wrap current buffer into `ai-run ...`).

Notes:
- Chat is stateless: no conversation history is stored or sent.

## Current Preferred UX (No ZLE)

`zsh/ai-shell-simple.zsh` provides `ai-run`:
- It sends the request to `bin/ai-shell-llm --auto`.
- The model returns JSON with `type:"shell"| "plan" | "chat"`:
  - `type:"shell"`: show an `fzf` picker (command list + `why` in preview) and inject the chosen command into the next prompt (`print -z`), appending the original request as a trailing `# ...` comment for history searching.
  - `type:"plan"`: show an `fzf` picker of steps (ordered). You can multi-select to inject multiple steps as multiple lines.
  - `type:"chat"`: print the response.

## Install (zsh)

Prereqs:
- `python3`
- `fzf` (only needed for the `type:"shell"` picker)
- zsh `interactive_comments` option enabled (this repo enables it when sourced so `cmd # comment` works).

Option A: preferred (`ai-run`, no mode switch)
- Add to your `~/.zshrc`:
  - `source /Users/senaca/code/playground/ai-shell/zsh/ai-shell-simple.zsh`
- Usage:
  - `ai-run <natural language request...>`
  - Or type any command line, press Ctrl+K to wrap it into `ai-run '...'` (and optionally auto-execute, see config).

## Configuration

The zsh integration reads a best-effort YAML config from `~/.config/ai-shell/config.yaml` (simple `key: value` map).

Sourced-time (requires re-sourcing `zsh/ai-shell-simple.zsh`):
- `auto`: `true|false`. If true, Ctrl+K wraps the line into `ai-run ...` and executes immediately (no extra Enter).
- `trigger_key`: zsh bindkey string like `^K` (alias: `wrap_key`).
- `reselect_key`: zsh bindkey string like `^J`. Opens history re-select UI (see below).

Runtime (hot-reloaded on each `ai-run`):
- `auto-copy`: `true|false`. If true (default), copy the "result" to pasteboard via `pbcopy` (selected command line, or chat output).
- `default_model`: model passed as `-m ...` to `ai-shell-llm`. Can be a full model name or an alias from `model_alias`.
- `fallback_model`: if the first request fails (non-zero exit), retry once with this model. Can be a full model name or an alias from `model_alias`.
- `cmd_comment`: `request|why`. When you pick a command in `fzf`, the injected command line becomes `<cmd> # <request-or-why>` for easy history searching.
- `model_alias`: map of short aliases to full model names. Use by suffixing your prompt with `| <alias>` (e.g. `list files | mimo`). If alias is unknown, `ai-run` falls back to `default_model`.
- `history_file`: where `ai-run` stores the last N raw LLM replies as JSONL (default: `~/.config/ai-shell/history.jsonl`).
- `history_size`: number of entries to keep (default: 200).

Example:
```yaml
source-time:
  auto: true
  trigger_key: "^K"
  reselect_key: "^J"

runtime:
  auto-copy: true
  default_model: deepseek
  fallback_model: gemini-3-flash
  cmd_comment: request
  history_size: 200
  # history_file: ~/.config/ai-shell/history.jsonl
  model_alias:
    mimo: xiaomi/mimo-v2-flash
    gemini-3-flash: ai-gateway/google/gemini-3-flash-preview
    deepseek: mify-gateway/volcengine_maas/deepseek-v3-2-251201
```

## Files / Scripts

- `bin/ai-shell-llm`: OpenAI-compatible chat client; supports `--auto` (JSON) and `--shell-cmds` (TSV) outputs; `-m/--model` overrides model.
- `bin/ai-shell-history-preview`: helper used by `fzf --preview` to render saved history entries.
- `zsh/ai-shell-simple.zsh`: defines `ai-run` and an optional Ctrl+K ZLE wrapper (`AI_SHELL_WRAP_KEY`, default `^K`).

## How Chat Mode Works (Implementation Notes)

`ai-shell` is stateless by design: `bin/ai-shell-llm` always sends a single-message payload (`messages: [{role:user, content:<buffer>}]`) and does not persist or resend history.

## Waiting / Spinner UX

`bin/ai-shell-llm` starts a background spinner thread while waiting for the first streamed token:
- `_spinner(stop, started)` prints `\rWaiting |/-\` frames to stderr only when `stderr` is a TTY.
- The main thread sets `started` when the first non-empty `choices[0].delta.content` arrives; `stop` is set on completion/error.
- When `started` flips (or `stop` is set), the spinner clears its line and stops.

For non-streaming JSON modes (`--shell-cmds`, `--auto`), the spinner runs until the full response body is read.

`ai-run` suppresses the `ai-shell-llm` spinner (so it doesn't fight terminal UI) and instead prints a 3-line status block while fetching; the block is cleared once the response is received.

If `NO_COLOR` is set (or no TTY), the status block renders without ANSI colors.

## Re-select From History

`ai-run` saves the raw JSON reply (chat/shell/plan) to `history_file` (JSONL, last `history_size` entries).

Press `reselect_key` (default Ctrl+J) to:
- fuzzy-search previous `ai-run` replies (preview shows chat/commands/steps)
- for `shell`/`plan`: pick one or multiple commands/steps to inject into the prompt buffer (no auto-exec)
- for `chat`: do nothing (preview-only)

## Auto JSON Modes

- `ai-shell-llm --shell-cmds`: asks for shell-command suggestions and prints TSV (`cmd<TAB>why`) for easy piping into `fzf`.
- `ai-shell-llm --auto`: asks the model to choose between:
  - `{"type":"shell","commands":[{"why":...,"cmd":...}]}`
  - `{"type":"chat","content":"..."}`
- For these modes, runtime context (OS/macos version, arch, shell, cwd, python version) is appended to the system prompt so commands are correct for the current environment.

