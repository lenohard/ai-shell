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
typeset -g AI_SHELL_RESELECT_KEY="${AI_SHELL_RESELECT_KEY:-^J}" # Ctrl+J by default
typeset -g AI_SHELL_AUTO_WRAP="${AI_SHELL_AUTO_WRAP:-1}" # 1/0; affects Ctrl+K widget behavior
typeset -g AI_SHELL_PENDING_BUFFER=""
typeset -g AI_SHELL_FORCE_ZLE_INJECT=0

# Resolve the repo root to find bin/ai-shell-llm.
typeset -g _AI_SHELL_SCRIPT_PATH="${${ZERO:-${0:#$ZSH_ARGZERO}}:-${(%):-%N}}"
typeset -g _AI_SHELL_ROOT="${_AI_SHELL_SCRIPT_PATH:A:h:h}"
typeset -g _AI_SHELL_LLM_CMD="${_AI_SHELL_ROOT}/bin/ai-shell-llm"

typeset -g _AI_SHELL_STATUS_LINES=0

function _ai_shell_tty_print() {
  print -r -- "$*" > /dev/tty
}

function _ai_shell_color_enabled() {
  # Enable simple ANSI colors only for interactive TTYs unless NO_COLOR is set.
  [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 || -t 2 || -t 0 ]]
}

function _ai_shell_status_begin() {
  # Print a small status block (3 lines) that stays visible during the request.
  # We clear it once the response is fetched so it doesn't pollute scrollback.
  local model_label="$1"
  local request_label="$2"
  local note="$3"

  local req="${request_label//$'\n'/ }"
  req="${req//$'\t'/ }"
  if (( ${#req} > 120 )); then
    req="${req[1,117]}..."
  fi

  if _ai_shell_color_enabled; then
    local R=$'\033[0m' B=$'\033[1m' D=$'\033[2m' C=$'\033[36m' Y=$'\033[33m'
    _ai_shell_tty_print "${C}ai-shell${R}${D}:${R} ${B}model${R}${D}:${R} ${B}${model_label}${R}"
    _ai_shell_tty_print "${C}ai-shell${R}${D}:${R} ${B}request${R}${D}:${R} ${D}${req}${R}"
    _ai_shell_tty_print "${C}ai-shell${R}${D}:${R} ${Y}${note}${R}"
  else
    _ai_shell_tty_print "ai-shell: model: ${model_label}"
    _ai_shell_tty_print "ai-shell: request: ${req}"
    _ai_shell_tty_print "ai-shell: ${note}"
  fi
  _AI_SHELL_STATUS_LINES=3
}

function _ai_shell_status_update_note() {
  # Replace the third line of the status block.
  local note="$1"
  if (( _AI_SHELL_STATUS_LINES <= 0 )); then
    return 0
  fi
  # We are typically sitting on the line after the block; move up to line 3.
  if _ai_shell_color_enabled; then
    local R=$'\033[0m' C=$'\033[36m' D=$'\033[2m' Y=$'\033[33m'
    printf '\033[1A\r\033[0K%s\n' "${C}ai-shell${R}${D}:${R} ${Y}${note}${R}" > /dev/tty
  else
    printf '\033[1A\r\033[0K%s\n' "ai-shell: ${note}" > /dev/tty
  fi
}

function _ai_shell_status_end() {
  # Clear the status block plus the current line (best-effort).
  local i
  if (( _AI_SHELL_STATUS_LINES <= 0 )); then
    return 0
  fi
  # Clear current line, then walk up clearing the status lines.
  printf '\r\033[0K' > /dev/tty
  for i in {1..3}; do
    printf '\033[1A\r\033[0K' > /dev/tty
  done
  _AI_SHELL_STATUS_LINES=0
}

function _ai_shell_config_file() {
  print -r -- "${XDG_CONFIG_HOME:-$HOME/.config}/ai-shell/config.yaml"
}

function _ai_shell_default_history_file() {
  print -r -- "${XDG_CONFIG_HOME:-$HOME/.config}/ai-shell/history.jsonl"
}

function _ai_shell_load_sourced_config() {
  # Config that only takes effect when sourced (key bindings / widget behavior).
  command -v python3 >/dev/null 2>&1 || return 0
  local cfg_file="$(_ai_shell_config_file)"
  [[ -f "${cfg_file}" ]] || return 0

  local out
  out="$(
    python3 - "${cfg_file}" <<'PY'
import shlex
import sys

path = sys.argv[1]

def parse_bool(s: str):
    s = s.strip().lower()
    if s in {"1", "true", "yes", "y", "on"}:
        return True
    if s in {"0", "false", "no", "n", "off"}:
        return False
    return None

cfg = {}
stack = []  # list[(indent:int, key:str)]
try:
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            # Preserve indentation so we can support simple nested sections:
            # source-time: / runtime: with 2-space indented children.
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if ":" not in stripped:
                continue
            indent = len(line) - len(line.lstrip(" "))
            k, v = stripped.split(":", 1)
            k = k.strip()
            v = v.strip()
            # Support inline comments only when the value is unquoted.
            if v and not (v.startswith("'") or v.startswith('"')) and " #" in v:
                v = v.split(" #", 1)[0].rstrip()
            if (len(v) >= 2) and ((v[0] == v[-1] == "'") or (v[0] == v[-1] == '"')):
                v = v[1:-1]
            while stack and stack[-1][0] >= indent:
                stack.pop()
            if v == "":
                stack.append((indent, k))
                continue
            prefix = ".".join([kk for _, kk in stack])
            full = f"{prefix}.{k}" if prefix else k
            cfg[full] = v
except Exception:
    cfg = {}

def get_any(*keys: str):
    for k in keys:
        if k in cfg:
            return cfg[k]
    return ""

# trigger_key (aka wrap_key): zsh bindkey string like "^K"
trigger_key = get_any(
    "trigger_key",
    "wrap_key",
    "source-time.trigger_key",
    "source-time.wrap_key",
    "source_time.trigger_key",
    "source_time.wrap_key",
)
if trigger_key.strip():
    sys.stdout.write("AI_SHELL_WRAP_KEY=" + shlex.quote(trigger_key.strip()) + "\n")

reselect_key = get_any(
    "reselect_key",
    "source-time.reselect_key",
    "source_time.reselect_key",
)
if reselect_key.strip():
    sys.stdout.write("AI_SHELL_RESELECT_KEY=" + shlex.quote(reselect_key.strip()) + "\n")

auto = get_any("auto", "source-time.auto", "source_time.auto")
if auto is not None:
    b = parse_bool(auto)
    if b is not None:
        sys.stdout.write("AI_SHELL_AUTO_WRAP=" + ("1" if b else "0") + "\n")
PY
  )"

  if [[ -n "${out}" ]]; then
    # Only contains simple `KEY=<shell-escaped>` assignments.
    eval "${out}"
  fi
}

_ai_shell_load_sourced_config 2>/dev/null || true

function _ai_shell_load_runtime_config() {
  # Runtime config (hot-reloaded).
  command -v python3 >/dev/null 2>&1 || return 0
  local cfg_file="$(_ai_shell_config_file)"
  [[ -f "${cfg_file}" ]] || return 0

  local out
  out="$(
    python3 - "${cfg_file}" <<'PY'
import os
import shlex
import sys

path = sys.argv[1]

def parse_bool(s: str):
    s = s.strip().lower()
    if s in {"1", "true", "yes", "y", "on"}:
        return True
    if s in {"0", "false", "no", "n", "off"}:
        return False
    return None

cfg = {}
stack = []  # list[(indent:int, key:str)]
try:
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if ":" not in stripped:
                continue
            indent = len(line) - len(line.lstrip(" "))
            k, v = stripped.split(":", 1)
            k = k.strip()
            v = v.strip()
            if v and not (v.startswith("'") or v.startswith('"')) and " #" in v:
                v = v.split(" #", 1)[0].rstrip()
            if (len(v) >= 2) and ((v[0] == v[-1] == "'") or (v[0] == v[-1] == '"')):
                v = v[1:-1]
            while stack and stack[-1][0] >= indent:
                stack.pop()
            if v == "":
                stack.append((indent, k))
                continue
            prefix = ".".join([kk for _, kk in stack])
            full = f"{prefix}.{k}" if prefix else k
            cfg[full] = v
except Exception:
    cfg = {}

def get_any(*keys: str):
    for k in keys:
        if k in cfg:
            return cfg[k]
    return ""

cmd_comment = get_any("cmd_comment", "runtime.cmd_comment").strip().lower()
if cmd_comment in {"raw_request"}:
    cmd_comment = "request"
if cmd_comment not in {"request", "why"}:
    cmd_comment = "request"

auto_copy = None
for key in ("auto-copy", "auto_copy", "runtime.auto-copy", "runtime.auto_copy"):
    if key in cfg:
        auto_copy = parse_bool(cfg[key])
        break
auto_copy_effective = True if auto_copy is None else bool(auto_copy)

history_size = get_any("history_size", "runtime.history_size").strip()
try:
    hs = int(history_size) if history_size else 200
except Exception:
    hs = 200
if hs <= 0:
    hs = 200

history_file = get_any("history_file", "runtime.history_file").strip()

sys.stdout.write("cmd_comment=" + shlex.quote(cmd_comment) + "\n")
sys.stdout.write("auto_copy=" + ("1" if auto_copy_effective else "0") + "\n")
sys.stdout.write("history_size=" + shlex.quote(str(hs)) + "\n")
sys.stdout.write("history_file=" + shlex.quote(history_file) + "\n")
PY
  )"

  if [[ -n "${out}" ]]; then
    eval "${out}"
  fi
}

function _ai_shell_history_save() {
  # Save the raw LLM JSON reply so we can re-select later.
  local model_label="$1"
  local request="$2"
  local raw_json="$3"
  local kind="$4"

  command -v python3 >/dev/null 2>&1 || return 0

  local cfg_file="$(_ai_shell_config_file)"
  local history_size="200" history_file=""
  if [[ -f "${cfg_file}" ]]; then
    _ai_shell_load_runtime_config 2>/dev/null || true
  fi
  local file="${history_file:-$(_ai_shell_default_history_file)}"

  # Use stdin for the raw JSON payload; use -c for code so we don't conflict
  # with python reading its program from stdin.
  python3 -c 'import json, os, sys, time
path=os.path.expanduser(sys.argv[1])
keep=int(sys.argv[2]) if sys.argv[2].strip() else 200
model=sys.argv[3]
kind=sys.argv[4]
request=sys.argv[5]
raw=sys.stdin.read()
try:
    payload=json.loads(raw) if raw.strip() else {}
except Exception:
    payload={"type": kind or "unknown", "raw": raw}
entry={"ts": int(time.time()), "model": model, "request": request, "type": kind or str(payload.get("type") or "unknown"), "payload": payload}
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
if keep>0:
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines=f.readlines()
        if len(lines)>keep:
            with open(path, "w", encoding="utf-8") as f:
                f.writelines(lines[-keep:])
    except Exception:
         pass' "${file}" "${history_size}" "${model_label}" "${kind}" "${request}" <<<"${raw_json}"
}

function _ai_shell_inject_block() {
  # $1: request, $2: cmd_comment, $3: auto_copy (1/0), $4: lines ("cmd<TAB>why" per line)
  local request="$1"
  local cmd_comment="$2"
  local auto_copy="$3"
  local lines="$4"

  local out
  # Use -c (program in argv) so stdin is free for the selected lines.
  out="$(
    python3 -c '
import sys
request = sys.argv[1]
mode = sys.argv[2].strip().lower()
lines = [ln.rstrip("\n") for ln in sys.stdin.read().splitlines() if ln.strip()]
final_lines = []
for ln in lines:
    if "\t" in ln:
        cmd, why = ln.split("\t", 1)
    else:
        cmd, why = ln, ""
    cmd = cmd.strip()
    why = why.strip()
    if not cmd:
        continue
    comment = request
    if mode == "why" and why.strip():
        comment = why
    comment = comment.replace("\n", " ").replace("\t", " ").strip()
    comment = comment.replace("!", r"\!")  # avoid history expansion surprises
    if comment:
        final_lines.append(f"{cmd} # {comment}")
    else:
        final_lines.append(cmd)
sys.stdout.write("\n".join(final_lines))
' "${request}" "${cmd_comment}" <<<"${lines}"
  )"

  [[ -z "${out}" ]] && return 0
  if [[ "${AI_SHELL_FORCE_ZLE_INJECT}" == "1" ]]; then
    BUFFER="${out}"
    CURSOR=${#BUFFER}
    AI_SHELL_PENDING_BUFFER=""
    zle redisplay 2>/dev/null && return 0
  fi
  if [[ -n "${ZLE:-}" || -n "${WIDGET:-}" ]]; then
    # When called from a ZLE widget (e.g. Ctrl+J history reselect), populate the
    # current editor buffer immediately.
    BUFFER="${out}"
    CURSOR=${#BUFFER}
    AI_SHELL_PENDING_BUFFER=""
    zle redisplay 2>/dev/null || true
  else
    # When called from a normal shell function (e.g. `ai-run`), we can't edit
    # the current buffer, so push it to the next prompt.
    print -z -- "${out}"
    AI_SHELL_PENDING_BUFFER="${out}"
  fi
  if [[ "${auto_copy}" == "1" ]] && command -v pbcopy >/dev/null 2>&1; then
    print -rn -- "${out}" | pbcopy
  fi
}

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

  # Optional model selector suffix:
  #   <request...> | <alias>
  # Example: "list files | mimo"
  local requested_model_alias=""
  if [[ "${request}" == *"|"* ]]; then
    local _tail="${request##*|}"
    local _head="${request%|*}"
    local _cand="${_tail#"${_tail%%[![:space:]]*}"}"
    _cand="${_cand%"${_cand##*[![:space:]]}"}"
    if [[ -n "${_cand}" ]] && [[ "${_cand}" =~ '^[A-Za-z0-9._-]+$' ]]; then
      requested_model_alias="${_cand}"
      request="${_head}"
      request="${request%$'\n'}"
      request="${request%"${request##*[![:space:]]}"}"
    fi
  fi

  # Runtime config (hot-reloaded each ai-run).
  local cfg_file="$(_ai_shell_config_file)"
  local default_model="" fallback_model="" cmd_comment="request" auto_copy="1"
  local history_size="200" history_file=""
  local resolved_model="" alias_found="0" default_model_cfg="" fallback_model_cfg=""
  local default_model_is_alias="0" fallback_model_is_alias="0"
  if [[ -f "${cfg_file}" ]]; then
    local cfg_kv
    cfg_kv="$(
      python3 - "${cfg_file}" "${requested_model_alias}" <<'PY'
import shlex
import sys

path = sys.argv[1]
requested_alias = (sys.argv[2] if len(sys.argv) > 2 else "").strip()

def parse_bool(s: str):
    s = s.strip().lower()
    if s in {"1", "true", "yes", "y", "on"}:
        return True
    if s in {"0", "false", "no", "n", "off"}:
        return False
    return None

cfg = {}
stack = []  # list[(indent:int, key:str)]
try:
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if ":" not in stripped:
                continue
            indent = len(line) - len(line.lstrip(" "))
            k, v = stripped.split(":", 1)
            k = k.strip()
            v = v.strip()
            if v and not (v.startswith("'") or v.startswith('"')) and " #" in v:
                v = v.split(" #", 1)[0].rstrip()
            if (len(v) >= 2) and ((v[0] == v[-1] == "'") or (v[0] == v[-1] == '"')):
                v = v[1:-1]
            while stack and stack[-1][0] >= indent:
                stack.pop()
            if v == "":
                stack.append((indent, k))
                continue
            prefix = ".".join([kk for _, kk in stack])
            full = f"{prefix}.{k}" if prefix else k
            cfg[full] = v
except Exception:
    cfg = {}

def get_any(*keys: str):
    for k in keys:
        if k in cfg:
            return cfg[k]
    return ""

auto_copy = None
for key in ("auto-copy", "auto_copy", "runtime.auto-copy", "runtime.auto_copy", "runtime.auto-copy"):
    if key in cfg:
        auto_copy = parse_bool(cfg[key])
        break

cmd_comment = get_any("cmd_comment", "runtime.cmd_comment").strip().lower()
if cmd_comment in {"raw_request"}:
    cmd_comment = "request"
if cmd_comment not in {"request", "why"}:
    cmd_comment = "request"

default_model_cfg = get_any("default_model", "runtime.default_model").strip()
fallback_model_cfg = get_any("fallback_model", "runtime.fallback_model").strip()
auto_copy_effective = True if auto_copy is None else bool(auto_copy)

history_size = get_any("history_size", "runtime.history_size").strip()
try:
    hs = int(history_size) if history_size else 200
except Exception:
    hs = 200
if hs <= 0:
    hs = 200
history_file = get_any("history_file", "runtime.history_file").strip()

def resolve_alias(alias: str):
    if not alias:
        return "", False
    candidates = (
        f"model_alias.{alias}",
        f"runtime.model_alias.{alias}",
        f"models.{alias}",
        f"runtime.models.{alias}",
    )
    for k in candidates:
        v = cfg.get(k)
        if v is not None and str(v).strip():
            return str(v).strip(), True
    return "", False

def resolve_model_name(name: str):
    n = (name or "").strip()
    if not n:
        return "", False
    # Treat explicit full names as-is.
    if "/" in n:
        return n, False
    # Otherwise, allow aliases (including for default_model/fallback_model).
    v, ok = resolve_alias(n)
    if ok and v.strip():
        return v.strip(), True
    return n, False

default_model, default_is_alias = resolve_model_name(default_model_cfg)
fallback_model, fallback_is_alias = resolve_model_name(fallback_model_cfg)
alias_model, found = resolve_alias(requested_alias)
resolved_model = alias_model if found else default_model

sys.stdout.write("default_model_cfg=" + shlex.quote(default_model_cfg) + "\n")
sys.stdout.write("fallback_model_cfg=" + shlex.quote(fallback_model_cfg) + "\n")
sys.stdout.write("default_model_is_alias=" + ("1" if default_is_alias else "0") + "\n")
sys.stdout.write("fallback_model_is_alias=" + ("1" if fallback_is_alias else "0") + "\n")
sys.stdout.write("default_model=" + shlex.quote(default_model) + "\n")
sys.stdout.write("fallback_model=" + shlex.quote(fallback_model) + "\n")
sys.stdout.write("cmd_comment=" + shlex.quote(cmd_comment) + "\n")
sys.stdout.write("auto_copy=" + ("1" if auto_copy_effective else "0") + "\n")
sys.stdout.write("history_size=" + shlex.quote(str(hs)) + "\n")
sys.stdout.write("history_file=" + shlex.quote(history_file) + "\n")
sys.stdout.write("resolved_model=" + shlex.quote(resolved_model) + "\n")
sys.stdout.write("alias_found=" + ("1" if found else "0") + "\n")
PY
    )"
    if [[ -n "${cfg_kv}" ]]; then
      eval "${cfg_kv}"
    fi
  fi

  local _model_label="${resolved_model:-default}"
  local _model_source="default_model"
  local _final_model_used="${_model_label}"
  if [[ -n "${requested_model_alias}" ]]; then
    if [[ "${alias_found}" == "1" ]] && [[ -n "${resolved_model}" ]]; then
      _model_source="alias:${requested_model_alias}"
    else
      _model_source="unknown-alias:${requested_model_alias}"
      resolved_model="${default_model}"
      _model_label="${resolved_model:-default}"
      _final_model_used="${_model_label}"
    fi
  elif [[ "${default_model_is_alias}" == "1" ]] && [[ -n "${default_model_cfg}" ]]; then
    _model_source="default_alias:${default_model_cfg}"
  fi

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
  if [[ -n "${resolved_model}" ]]; then
    _llm_args+=(-m "${resolved_model}")
  fi

  local status_note="fetching reply..."
  if [[ "${_model_source}" == unknown-alias:* ]]; then
    status_note="unknown model alias '${requested_model_alias}', using ${_model_label} ..."
  else
    status_note="fetching reply (${_model_source}) ..."
  fi
  _ai_shell_status_begin "${_model_label}" "${request}" "${status_note}"

  local _err1 _err2
  _err1="$(mktemp -t ai-shell-llm.XXXXXX 2>/dev/null || true)"
  json="$("${_AI_SHELL_LLM_CMD}" "${_llm_args[@]}" -- "${request}" 2> "${_err1}")"
  local _status=$?
  if (( _status != 0 )) && [[ -n "${fallback_model}" ]]; then
    local _fb_label="${fallback_model}"
    if [[ "${fallback_model_is_alias}" == "1" ]] && [[ -n "${fallback_model_cfg}" ]]; then
      _ai_shell_status_update_note "model failed, fetching from ${_fb_label} (alias:${fallback_model_cfg}) ..."
    else
      _ai_shell_status_update_note "model failed, fetching from ${_fb_label} ..."
    fi
    _llm_args=(--auto -m "${fallback_model}")
    _err2="$(mktemp -t ai-shell-llm.XXXXXX 2>/dev/null || true)"
    json="$("${_AI_SHELL_LLM_CMD}" "${_llm_args[@]}" -- "${request}" 2> "${_err2}")"
    _status=$?
    _final_model_used="${fallback_model}"
  fi

  # We have the response; clear the status block before continuing so it doesn't
  # end up in scrollback or interfere with fzf rendering.
  _ai_shell_status_end

  if [[ -z "${json//[[:space:]]/}" ]]; then
    local _err="${_err2:-${_err1}}"
    if [[ -n "${_err}" ]] && [[ -s "${_err}" ]]; then
      print -r -- "ai-shell: llm error: $(tail -n 1 "${_err}" 2>/dev/null)" > /dev/tty
    fi
    [[ -n "${_err1}" ]] && rm -f -- "${_err1}" 2>/dev/null || true
    [[ -n "${_err2}" ]] && rm -f -- "${_err2}" 2>/dev/null || true
    print -r -- "ai-shell: empty response" > /dev/tty
    return 1
  fi
  if (( _status != 0 )); then
    local _err="${_err2:-${_err1}}"
    if [[ -n "${_err}" ]] && [[ -s "${_err}" ]]; then
      print -r -- "ai-shell: llm error: $(tail -n 1 "${_err}" 2>/dev/null)" > /dev/tty
    fi
    [[ -n "${_err1}" ]] && rm -f -- "${_err1}" 2>/dev/null || true
    [[ -n "${_err2}" ]] && rm -f -- "${_err2}" 2>/dev/null || true
    print -r -- "ai-shell: request failed" > /dev/tty
    return 1
  fi

  [[ -n "${_err1}" ]] && rm -f -- "${_err1}" 2>/dev/null || true
  [[ -n "${_err2}" ]] && rm -f -- "${_err2}" 2>/dev/null || true

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
elif kind == "plan":
    sys.stdout.write("plan\n")
    for step in (obj.get("steps") or []):
        step = step or {}
        title = str(step.get("title") or "").replace("\t", " ").strip()
        cmd = str(step.get("cmd") or "").replace("\t", " ").strip()
        why = str(step.get("why") or "").replace("\t", " ").strip()
        if cmd:
            sys.stdout.write(f"{title}\t{cmd}\t{why}\n")
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

  # Save the raw reply so we can re-select later.
  _ai_shell_history_save "${_final_model_used}" "${request}" "${json}" "${kind}" 2>/dev/null || true

  if [[ "${kind}" == "shell" ]]; then
    if ! command -v fzf >/dev/null 2>&1; then
      print -r -- "ai-shell: missing 'fzf'" > /dev/tty
      return 1
    fi
    local selected
    selected="$(
      print -r -- "${rest}" | fzf \
        --ansi \
        --delimiter=$'\t' \
        --multi \
        --with-nth=1 \
        --preview='printf "\033[1mCMD:\033[0m\n%s\n\n\033[1mWHY:\033[0m\n%s\n" {1} {2}' \
        --preview-window=down:wrap \
        --prompt='cmd> ' \
        --height=40% \
        --layout=reverse 2> /dev/tty
    )"
    if [[ -z "${selected}" ]]; then
      print -r -- "ai-shell: cancelled" > /dev/tty
      return 0
    fi

    # fzf --multi returns multiple lines: cmd<TAB>why
    _ai_shell_inject_block "${request}" "${cmd_comment}" "${auto_copy}" "${selected}"
    return 0
  fi

  if [[ "${kind}" == "plan" ]]; then
    if ! command -v fzf >/dev/null 2>&1; then
      print -r -- "ai-shell: missing 'fzf'" > /dev/tty
      return 1
    fi
    local selected
	    selected="$(
	      print -r -- "${rest}" | fzf \
	        --ansi \
	        --delimiter=$'\t' \
	        --multi \
	        --with-nth=1 \
	        --preview='printf "\033[1mCMD:\033[0m\n%s\n\n\033[1mWHY:\033[0m\n%s\n\n\033[1mSTEP:\033[0m\n%s\n" {2} {3} {1}' \
	        --preview-window=down:wrap \
	        --prompt='step> ' \
	        --height=40% \
	        --layout=reverse 2> /dev/tty
	    )"
    if [[ -z "${selected}" ]]; then
      print -r -- "ai-shell: cancelled" > /dev/tty
      return 0
    fi
	    # Convert "title<TAB>cmd<TAB>why" -> "cmd<TAB>why" for injection.
	    local converted
	    converted="$(print -r -- "${selected}" | python3 -c '
import sys
out = []
for ln in sys.stdin.read().splitlines():
    parts = ln.split("\t")
    if len(parts) >= 3:
        _title, cmd, why = parts[0], parts[1], "\t".join(parts[2:])
        out.append(f"{cmd}\t{why}")
    elif len(parts) == 2:
        _title, cmd = parts[0], parts[1]
        out.append(f"{cmd}\t")
    elif len(parts) == 1 and parts[0].strip():
        out.append(parts[0].strip() + "\t")
sys.stdout.write("\n".join(out))
')"
	    _ai_shell_inject_block "${request}" "${cmd_comment}" "${auto_copy}" "${converted}"
	    return 0
	  fi

  if [[ "${auto_copy}" == "1" ]] && command -v pbcopy >/dev/null 2>&1; then
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

function ai-shell-reselect() {
  # Browse recent ai-run replies and re-select commands/steps.
  setopt localoptions nobraceexpand 2>/dev/null || true
  command -v python3 >/dev/null 2>&1 || return 0
  if ! command -v fzf >/dev/null 2>&1; then
    _ai_shell_tty_print "ai-shell: missing 'fzf'"
    return 0
  fi

  local cfg_file="$(_ai_shell_config_file)"
  local cmd_comment="request" auto_copy="1" history_size="200" history_file=""
  if [[ -f "${cfg_file}" ]]; then
    _ai_shell_load_runtime_config 2>/dev/null || true
  fi
  local file="${history_file:-$(_ai_shell_default_history_file)}"
  if [[ ! -f "${file}" ]]; then
    _ai_shell_tty_print "ai-shell: no history yet (${file})"
    return 0
  fi

  local list selected
  list="$(
    python3 - "${file}" <<'PY'
import base64
import json
import sys
import time

path = sys.argv[1]

def ts_to_str(ts: int) -> str:
    try:
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))
    except Exception:
        return str(ts)

try:
    with open(path, "r", encoding="utf-8") as f:
        lines = [ln.rstrip("\n") for ln in f if ln.strip()]
except Exception:
    lines = []

# Newest first for fzf.
for raw in reversed(lines):
    try:
        obj = json.loads(raw)
    except Exception:
        continue
    ts = int(obj.get("ts") or 0)
    typ = str(obj.get("type") or "unknown")
    model = str(obj.get("model") or "")
    req = str(obj.get("request") or "").replace("\n", " ").replace("\t", " ").strip()
    if len(req) > 120:
        req = req[:117] + "..."
    label = f"{ts_to_str(ts)}  [{typ}]  {model}  {req}".strip()
    b64 = base64.b64encode(raw.encode("utf-8")).decode("ascii")
    sys.stdout.write(label + "\t" + b64 + "\n")
PY
  )"

  selected="$(
    print -r -- "${list}" | fzf \
      --ansi \
      --delimiter=$'\t' \
      --with-nth=1 \
      --preview-window=down:wrap \
      --preview="${_AI_SHELL_ROOT}/bin/ai-shell-history-preview {2}" \
      --prompt='ai> ' \
      --height=60% \
      --layout=reverse 2> /dev/tty
  )"

  [[ -z "${selected}" ]] && return 0
  local b64="${selected#*$'\t'}"
  [[ -z "${b64}" ]] && return 0

  # Decode and decide what to do.
  local decoded kind request payload_json
  decoded="$(
    python3 - "${b64}" <<'PY'
import base64
import json
import sys

b64 = sys.argv[1]
raw = base64.b64decode(b64.encode("ascii")).decode("utf-8", errors="replace")
obj = json.loads(raw)
kind = str(obj.get("type") or "unknown")
request = str(obj.get("request") or "")
payload = obj.get("payload") or {}
print(kind)
print(json.dumps({"request": request, "payload": payload}, ensure_ascii=False))
PY
  )"

  kind="${decoded%%$'\n'*}"
  payload_json="${decoded#*$'\n'}"
  if [[ "${kind}" == "chat" ]]; then
    # User requested: do nothing for chat history entries.
    return 0
  fi

  if [[ "${kind}" == "shell" ]]; then
    local rest
    rest="$(python3 - "${payload_json}" <<'PY'
import json
import sys

obj = json.loads(sys.argv[1])
p = obj.get("payload") or {}
for item in (p.get("commands") or []):
    item = item or {}
    cmd = str(item.get("cmd") or "").replace("\t", " ").strip()
    why = str(item.get("why") or "").replace("\t", " ").strip()
    if cmd:
        sys.stdout.write(f"{cmd}\t{why}\n")
PY
)"
    local selected_cmds
    selected_cmds="$(print -r -- "${rest}" | fzf --ansi --delimiter=$'\t' --multi --with-nth=1 --preview='printf "\033[1mCMD:\033[0m\n%s\n\n\033[1mWHY:\033[0m\n%s\n" {1} {2}' --preview-window=down:wrap --prompt='cmd> ' --height=40% --layout=reverse 2> /dev/tty)"
    [[ -z "${selected_cmds}" ]] && return 0
    request="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("request",""))' "${payload_json}" 2>/dev/null)"
    AI_SHELL_FORCE_ZLE_INJECT=1
    _ai_shell_inject_block "${request}" "${cmd_comment}" "${auto_copy}" "${selected_cmds}"
    AI_SHELL_FORCE_ZLE_INJECT=0
    return 0
  fi

  if [[ "${kind}" == "plan" ]]; then
    local rest
    rest="$(python3 - "${payload_json}" <<'PY'
import json
import sys

obj = json.loads(sys.argv[1])
p = obj.get("payload") or {}
for step in (p.get("steps") or []):
    step = step or {}
    title = str(step.get("title") or "").replace("\t", " ").strip()
    cmd = str(step.get("cmd") or "").replace("\t", " ").strip()
    why = str(step.get("why") or "").replace("\t", " ").strip()
    if cmd:
        sys.stdout.write(f"{title}\t{cmd}\t{why}\n")
PY
)"
	    local selected_steps
	    selected_steps="$(print -r -- "${rest}" | fzf --ansi --delimiter=$'\t' --multi --with-nth=1 --preview='printf "\033[1mCMD:\033[0m\n%s\n\n\033[1mWHY:\033[0m\n%s\n\n\033[1mSTEP:\033[0m\n%s\n" {2} {3} {1}' --preview-window=down:wrap --prompt='step> ' --height=40% --layout=reverse 2> /dev/tty)"
	    [[ -z "${selected_steps}" ]] && return 0
	    local converted
	    converted="$(print -r -- "${selected_steps}" | python3 -c '
import sys
out = []
for ln in sys.stdin.read().splitlines():
    parts = ln.split("\t")
    if len(parts) >= 3:
        _title, cmd, why = parts[0], parts[1], "\t".join(parts[2:])
        out.append(f"{cmd}\t{why}")
    elif len(parts) == 2:
        _title, cmd = parts[0], parts[1]
        out.append(f"{cmd}\t")
    elif len(parts) == 1 and parts[0].strip():
        out.append(parts[0].strip() + "\t")
sys.stdout.write("\n".join(out))
')"
	    request="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("request",""))' "${payload_json}" 2>/dev/null)"
	    AI_SHELL_FORCE_ZLE_INJECT=1
	    _ai_shell_inject_block "${request}" "${cmd_comment}" "${auto_copy}" "${converted}"
	    AI_SHELL_FORCE_ZLE_INJECT=0
    return 0
  fi

  return 0
}

function _ai_shell_bind_wrap_key() {
  # Prompt plugins often rebind keys; re-apply on each prompt via precmd.
  bindkey -M emacs "${AI_SHELL_WRAP_KEY}" ai-shell-wrap-line
  bindkey -M viins "${AI_SHELL_WRAP_KEY}" ai-shell-wrap-line
  bindkey -M vicmd "${AI_SHELL_WRAP_KEY}" ai-shell-wrap-line
}

function _ai_shell_bind_reselect_key() {
  bindkey -M emacs "${AI_SHELL_RESELECT_KEY}" ai-shell-reselect
  bindkey -M viins "${AI_SHELL_RESELECT_KEY}" ai-shell-reselect
  bindkey -M vicmd "${AI_SHELL_RESELECT_KEY}" ai-shell-reselect
}

function _ai_shell_apply_pending_buffer() {
  if [[ -z "${AI_SHELL_PENDING_BUFFER}" ]]; then
    return 0
  fi
  BUFFER="${AI_SHELL_PENDING_BUFFER}"
  CURSOR=${#BUFFER}
  AI_SHELL_PENDING_BUFFER=""
  zle redisplay
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
  if zle -N ai-shell-reselect 2>/dev/null; then
    _ai_shell_bind_reselect_key
    add-zsh-hook precmd _ai_shell_bind_reselect_key
  fi

  # After `ai-run` finishes, populate the next prompt's editor buffer.
  autoload -Uz add-zle-hook-widget 2>/dev/null || true
  if (( $+functions[add-zle-hook-widget] )); then
    add-zle-hook-widget line-init _ai_shell_apply_pending_buffer 2>/dev/null || true
  fi
fi
