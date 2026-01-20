# ai-shell-config: shared config loader for zsh integrations.
#
# Reads a small YAML file from ~/.config so users can change behavior without
# editing the scripts.

typeset -g AI_SHELL_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ai-shell"
typeset -g AI_SHELL_CONFIG_FILE="${AI_SHELL_CONFIG_DIR}/config.yaml"

# Defaults (can be overridden by YAML if present).
typeset -g AI_SHELL_AUTO_WRAP="${AI_SHELL_AUTO_WRAP:-1}"               # 1/0
typeset -g AI_SHELL_AUTO_COPY="${AI_SHELL_AUTO_COPY:-1}"               # 1/0 (pbcopy)
typeset -g AI_SHELL_DEFAULT_MODEL="${AI_SHELL_DEFAULT_MODEL:-}"        # empty => use ai-shell-llm default/env
typeset -g AI_SHELL_FALLBACK_MODEL="${AI_SHELL_FALLBACK_MODEL:-}"      # empty => no fallback retry
typeset -g AI_SHELL_CMD_COMMENT_SOURCE="${AI_SHELL_CMD_COMMENT_SOURCE:-request}" # request|why

function _ai_shell_load_config() {
  # Best-effort parsing of a simple YAML mapping (key: value). We intentionally
  # avoid external deps like yq/PyYAML.
  if [[ ! -f "${AI_SHELL_CONFIG_FILE}" ]]; then
    return 0
  fi

  local cfg
  cfg="$(
    python3 - "${AI_SHELL_CONFIG_FILE}" <<'PY'
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
try:
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if ":" not in stripped:
                continue
            k, v = stripped.split(":", 1)
            k = k.strip()
            v = v.strip()
            # Support inline comments only when the value is unquoted.
            if v and not (v.startswith("'") or v.startswith('"')) and " #" in v:
                v = v.split(" #", 1)[0].rstrip()
            if (len(v) >= 2) and ((v[0] == v[-1] == "'") or (v[0] == v[-1] == '"')):
                v = v[1:-1]
            cfg[k] = v
except Exception:
    # Best-effort: if config can't be read/parsed, keep defaults.
    pass

out = []

if "auto" in cfg:
    b = parse_bool(cfg["auto"])
    if b is not None:
        out.append(f"AI_SHELL_AUTO_WRAP={'1' if b else '0'}")

for key in ("auto-copy", "auto_copy"):
    if key in cfg:
        b = parse_bool(cfg[key])
        if b is not None:
            out.append(f"AI_SHELL_AUTO_COPY={'1' if b else '0'}")
        break

if "default_model" in cfg and cfg["default_model"]:
    out.append("AI_SHELL_DEFAULT_MODEL=" + shlex.quote(cfg["default_model"]))

if "fallback_model" in cfg and cfg["fallback_model"]:
    out.append("AI_SHELL_FALLBACK_MODEL=" + shlex.quote(cfg["fallback_model"]))

if "cmd_comment" in cfg and cfg["cmd_comment"]:
    v = cfg["cmd_comment"].strip().lower()
    if v in {"request", "raw_request"}:
        out.append("AI_SHELL_CMD_COMMENT_SOURCE=" + shlex.quote("request"))
    elif v in {"why"}:
        out.append("AI_SHELL_CMD_COMMENT_SOURCE=" + shlex.quote("why"))

sys.stdout.write("\n".join(out))
PY
  )"

  if [[ -n "${cfg}" ]]; then
    eval "${cfg}"
  fi
}
