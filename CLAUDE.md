## Purpose

`ai-shell` is a small prototype that adds a "mode switch" to zsh:

- Normal mode: shell behaves normally.
- Chat mode: the current command line is treated as a prompt, sent to an OpenAI-compatible LLM endpoint (Bifrost), and the streamed response is printed in the terminal.

The long-term goal is to evolve this into a composable tool with multiple modes/presets, good streaming UX, and optional terminal UI enhancements.

## Current Stage (Prototype)

Implemented:
- `bin/ai-shell-llm`: stateless single-prompt client for OpenAI-compatible `/v1/chat/completions` with streaming output and a spinner while waiting for the first token.
- `zsh/ai-shell-simple.zsh`: simplest zsh integration with a single function `ai-run` (no ZLE widgets/keybindings).
- `zsh/ai-shell-config.zsh`: YAML config loader used by the zsh integration.

Notes:
- Chat is stateless: no conversation history is stored or sent.

## Current Preferred UX (No ZLE)

`zsh/ai-shell-simple.zsh` provides `ai-run`:
- It sends the request to `bin/ai-shell-llm --auto`.
- The model returns JSON with `type:"shell"| "chat"`:
  - `type:"shell"`: show an `fzf` picker (command list + `why` in preview) and inject the chosen command into the next prompt (`print -z`), appending the original request as a trailing `# ...` comment for history searching.
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

The zsh integration loads a best-effort YAML config from `~/.config/ai-shell/config.yaml` (simple `key: value` map).

Keys:
- `auto`: `true|false`. If true, Ctrl+K in `zsh/ai-shell-simple.zsh` wraps the line into `ai-run ...` and executes immediately (no extra Enter). Requires re-sourcing to update widget behavior.
- `auto-copy`: `true|false`. If true (default), copy the "result" to pasteboard via `pbcopy` (selected command line, or chat output).
- `default_model`: model passed as `-m ...` to `ai-shell-llm` (hot-reloaded each `ai-run`).
- `fallback_model`: if the first request fails (non-zero exit), retry once with this model.
- `cmd_comment`: `request|why`. When you pick a command in `fzf`, the injected command line becomes `<cmd> # <request-or-why>` for easy history searching.

Example:
```yaml
auto: true
default_model: mify-gateway/deepseek-chat
cmd_comment: request
```

## Files / Scripts

- `bin/ai-shell-llm`: OpenAI-compatible chat client; supports `--auto` (JSON) and `--shell-cmds` (TSV) outputs; `-m/--model` overrides model.
- `zsh/ai-shell-simple.zsh`: defines `ai-run` and an optional Ctrl+K ZLE wrapper (`AI_SHELL_WRAP_KEY`, default `^K`).
- `zsh/ai-shell-config.zsh`: loads `~/.config/ai-shell/config.yaml` and exports: `AI_SHELL_AUTO_WRAP` (`1|0`), `AI_SHELL_DEFAULT_MODEL`, `AI_SHELL_CMD_COMMENT_SOURCE` (`request|why`).

## How Chat Mode Works (Implementation Notes)

`ai-shell` is stateless by design: `bin/ai-shell-llm` always sends a single-message payload (`messages: [{role:user, content:<buffer>}]`) and does not persist or resend history.

## Waiting / Spinner UX

`bin/ai-shell-llm` starts a background spinner thread while waiting for the first streamed token:
- `_spinner(stop, started)` prints `\rWaiting |/-\` frames to stderr only when `stderr` is a TTY.
- The main thread sets `started` when the first non-empty `choices[0].delta.content` arrives; `stop` is set on completion/error.
- When `started` flips (or `stop` is set), the spinner clears its line and stops.

For non-streaming JSON modes (`--shell-cmds`, `--auto`), the spinner runs until the full response body is read.

## Auto JSON Modes

- `ai-shell-llm --shell-cmds`: asks for shell-command suggestions and prints TSV (`cmd<TAB>why`) for easy piping into `fzf`.
- `ai-shell-llm --auto`: asks the model to choose between:
  - `{"type":"shell","commands":[{"why":...,"cmd":...}]}`
  - `{"type":"chat","content":"..."}`
- For these modes, runtime context (OS/macos version, arch, shell, cwd, python version) is appended to the system prompt so commands are correct for the current environment.

## Pending / Ideas

Near-term:
- Support model/provider aliases (e.g. `@fast`, `@reason`, etc.) via a small config file.
- Optional lightweight rendering for markdown/code blocks (plain text fallback).

Later:
- Stateful chat (history, truncation/token budgeting, privacy controls).
- Additional modes (translate/summarize/rewrite, “send current buffer” helpers, etc.).
- Better UX around errors/retries/timeouts and consistent formatting of outputs.
