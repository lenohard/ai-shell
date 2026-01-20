# ai-shell-simple: no-ZLE integration.
#
# Primary interface is `ai-run ...` (no ZLE needed). Optionally, when running
# interactively with ZLE available, Ctrl+K can wrap the current line to
# `ai-run '...'` so you can press Enter to execute.
#
# Usage:
#   source /path/to/ai-shell-simple.zsh
#   ai-run <natural language request...>

typeset -g AI_SHELL_WRAP_KEY="${AI_SHELL_WRAP_KEY:-^K}" # Ctrl+K by default

# Load ~/.config/ai-shell/config.yaml (best-effort).
0="${${ZERO:-${0:#$ZSH_ARGZERO}}:-${(%):-%N}}"
local _AI_SHELL_ROOT="${0:A:h:h}"
local _AI_SHELL_LLM_CMD="${_AI_SHELL_ROOT}/bin/ai-shell-llm"
source "${_AI_SHELL_ROOT}/zsh/ai-shell-config.zsh" 2>/dev/null || true
_ai_shell_load_config 2>/dev/null || true

function ai-run() {
  # Usage:
  #   ai-run <natural language prompt...>
  # Behavior:
  #   - If the model returns shell commands: pick via fzf and inject into the next prompt (print -z).
  #   - If it returns chat: print it to the terminal.
  local request="$*"
  if [[ -z "${request//[[:space:]]/}" ]]; then
    # Allow: echo "..." | ai-run
    request="$(cat)"
  fi
  request="${request//$'\r'/}"
  request="${request%$'\n'}"

  if [[ -z "${request//[[:space:]]/}" ]]; then
    return 0
  fi

  # Hot-reload config for runtime options (model/comment behavior).
  # Note: Ctrl+K auto-exec behavior is controlled by AI_SHELL_AUTO_WRAP and is
  # intended to require re-sourcing to change, so we preserve it here.
  local _auto_saved="${AI_SHELL_AUTO_WRAP}"
  _ai_shell_load_config 2>/dev/null || true
  AI_SHELL_AUTO_WRAP="${_auto_saved}"

  if [[ ! -x "${_AI_SHELL_LLM_CMD}" ]]; then
    print -r -- "ai-shell: missing executable: ${_AI_SHELL_LLM_CMD}" > /dev/tty
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    print -r -- "ai-shell: missing python3" > /dev/tty
    return 1
  fi

  # Always render progress to the real terminal.
  local json
  local -a _llm_args
  _llm_args=(--auto)
  if [[ -n "${AI_SHELL_DEFAULT_MODEL}" ]]; then
    _llm_args+=(-m "${AI_SHELL_DEFAULT_MODEL}")
  fi
  local _model_label="${AI_SHELL_DEFAULT_MODEL:-default}"
  print -r -- "ai-shell: fetching reply from ${_model_label} ..." > /dev/tty
  json="$("${_AI_SHELL_LLM_CMD}" "${_llm_args[@]}" -- "${request}" 2> /dev/tty)"
  local _status=$?
  if (( _status != 0 )) && [[ -n "${AI_SHELL_FALLBACK_MODEL}" ]]; then
    print -r -- "ai-shell: model failed, fetching from ${AI_SHELL_FALLBACK_MODEL} ..." > /dev/tty
    _llm_args=(--auto -m "${AI_SHELL_FALLBACK_MODEL}")
    json="$("${_AI_SHELL_LLM_CMD}" "${_llm_args[@]}" -- "${request}" 2> /dev/tty)"
    _status=$?
  fi
  if [[ -z "${json//[[:space:]]/}" ]]; then
    print -r -- "ai-shell: empty response" > /dev/tty
    return 1
  fi
  if (( _status != 0 )); then
    print -r -- "ai-shell: request failed" > /dev/tty
    return 1
  fi

  local parsed kind rest
  parsed="$(python3 - "${json}" <<'PY'
import json
import sys

raw = sys.argv[1] if len(sys.argv) > 1 else ""
raw_stripped = raw.strip()

def parse_best_effort(text: str):
    s = text.strip()
    if not s:
        return {}
    try:
        obj = json.loads(s)
        return obj if isinstance(obj, dict) else {}
    except Exception:
        pass
    dec = json.JSONDecoder()
    i = 0
    last = {}
    while i < len(s):
        while i < len(s) and s[i] in " \t\r\n.,":
            i += 1
        if i >= len(s):
            break
        try:
            obj, end = dec.raw_decode(s, i)
        except Exception:
            i += 1
            continue
        if isinstance(obj, dict):
            last = obj
        i = end
    return last

obj = parse_best_effort(raw_stripped)
if not isinstance(obj, dict) or not obj:
    sys.stdout.write("chat\n" + (raw_stripped or raw))
    raise SystemExit(0)

kind = str(obj.get("type") or "chat").strip()
if kind == "shell":
    sys.stdout.write("shell\n")
    for item in (obj.get("commands") or []):
        item = item or {}
        cmd = str(item.get("cmd") or "").replace("\t", " ").strip()
        why = str(item.get("why") or "").replace("\t", " ").strip()
        if cmd:
            sys.stdout.write(f"{cmd}\t{why}\n")
else:
    content = obj.get("content")
    if content is None:
        content = raw_stripped or raw
    sys.stdout.write("chat\n" + str(content))
PY
)"

  if [[ "${parsed}" == *$'\n'* ]]; then
    kind="${parsed%%$'\n'*}"
    rest="${parsed#*$'\n'}"
  else
    # Command substitution strips trailing newlines; if we lost the separator,
    # treat it as "kind only" and empty content.
    kind="${parsed}"
    rest=""
  fi

  if [[ "${kind}" == "shell" ]]; then
    if ! command -v fzf >/dev/null 2>&1; then
      print -r -- "ai-shell: missing 'fzf'" > /dev/tty
      return 1
    fi
    local selected
    selected="$(
      print -r -- "${rest}" | fzf \
        --delimiter=$'\t' \
        --with-nth=1 \
        --preview='printf "%s\n\n%s\n" "WHY:" {2}' \
        --preview-window=down:wrap \
        --prompt='cmd> ' \
        --height=40% \
        --layout=reverse 2> /dev/tty
    )"
    if [[ -z "${selected}" ]]; then
      print -r -- "ai-shell: cancelled" > /dev/tty
      return 0
    fi
    local cmd="${selected%%$'\t'*}"
    local why=""
    if [[ "${selected}" == *$'\t'* ]]; then
      why="${selected#*$'\t'}"
    fi
    # Inject the chosen command into the next prompt buffer (no ZLE widget needed).
    # Append a trailing comment for easy history searching later.
    local comment="${request}"
    if [[ "${AI_SHELL_CMD_COMMENT_SOURCE}" == "why" ]]; then
      comment="${why}"
      [[ -z "${comment//[[:space:]]/}" ]] && comment="${request}"
    fi
    comment="${comment//$'\n'/ }"
    comment="${comment//$'\t'/ }"
    # Prevent zsh history expansion from triggering on "!" inside the comment.
    comment="${comment//\!/\\!}"
    comment="${comment#"${comment%%[![:space:]]*}"}"
    comment="${comment%"${comment##*[![:space:]]}"}"
    local final_line="${cmd}"
    if [[ -n "${comment}" ]]; then
      final_line="${cmd} # ${comment}"
    fi
    print -z -- "${final_line}"
    if [[ "${AI_SHELL_AUTO_COPY}" == "1" ]] && command -v pbcopy >/dev/null 2>&1; then
      # Copy the final injected command (with comment) for easy pasting elsewhere.
      print -rn -- "${final_line}" | pbcopy
    fi
    return 0
  fi

  if [[ "${AI_SHELL_AUTO_COPY}" == "1" ]] && command -v pbcopy >/dev/null 2>&1; then
    # Copy chat output as the "result" when not returning a shell command.
    print -rn -- "${rest}" | pbcopy
  fi
  print -r -- "${rest}" > /dev/tty
  return 0
}

function ai-shell-wrap-line() {
  # Wrap the current ZLE buffer into an `ai-run ...` invocation.
  # ${(qq)...} produces a safely quoted literal (may use $'...' when needed).
  BUFFER="ai-run ${(qq)BUFFER}"
  CURSOR=${#BUFFER}
  if [[ "${AI_SHELL_AUTO_WRAP}" == "1" ]]; then
    zle accept-line
  else
    zle redisplay
  fi
}

function _ai_shell_bind_wrap_key() {
  # Prompt plugins often rebind keys; re-apply on each prompt via precmd.
  bindkey -M emacs "${AI_SHELL_WRAP_KEY}" ai-shell-wrap-line
  bindkey -M viins "${AI_SHELL_WRAP_KEY}" ai-shell-wrap-line
  bindkey -M vicmd "${AI_SHELL_WRAP_KEY}" ai-shell-wrap-line
}

if [[ -o interactive ]]; then
  # Needed so injected commands like `cmd # comment` work in interactive shells.
  setopt interactive_comments 2>/dev/null || true
  autoload -Uz add-zsh-hook
  # Ensure ZLE is available in interactive shells (it's a module/builtin, not a
  # function, so checking $+functions[zle] is unreliable).
  zmodload -i zsh/zle 2>/dev/null || true
  if zle -N ai-shell-wrap-line 2>/dev/null; then
    _ai_shell_bind_wrap_key
    add-zsh-hook precmd _ai_shell_bind_wrap_key
  fi
fi
