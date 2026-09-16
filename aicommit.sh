# aicommit - opencode-based git commit message generator
# Loaded via source from ~/.tools/*.sh.
# Model: opencode/ling-3.0-flash-fin-free (free model, override with env AICOMMIT_MODEL)
#
# Usage:
#   aicommit                       # generate message, then wait for c/r/x/extra-prompt input
#   aicommit -c                    # generate then commit immediately (no confirmation)
#   aicommit -r "with more emoji"  # generate with extra prompt (stay interactive)
#   aicommit -c -r "with more emoji" # extra prompt + commit immediately
#   aicommit "with more emoji"      # positional args also treated as extra prompt
#   aicommit -h                    # help
#
# Interactive choices:
#   c             : commit immediately
#   r             : regenerate (same conditions)
#   x             : exit (q, quit, exit work too)
#   other input   : regenerate applying it as an extra prompt
#   empty input   : prompt again

# Model (override with export AICOMMIT_MODEL=... if needed)
: "${AICOMMIT_MODEL:=opencode/ling-3.0-flash-fin-free}"

_aicommit_usage() {
    cat <<'EOF'
Usage: aicommit [options] [extra prompt...]

Options:
  -c, --commit          Commit with the generated message immediately (no confirmation)
  -r, --reprompt TEXT   Extra requirement prompt (e.g. -r "with more emoji")
  -h, --help            Show help

Examples:
  aicommit
  aicommit -c
  aicommit -r "with more emoji"
  aicommit -c -r "with more emoji, in English"
  aicommit "subject in English, body in English"

Interactive (plain aicommit run):
  c             Commit immediately
  r             Regenerate
  x             Exit (q/quit/exit work too)
  <sentence>    Regenerate applying the typed requirement
  (empty)       Prompt again
EOF
}

# Generate one commit message via opencode. Prints only the message to stdout. Returns 1 on failure.
# $1 = extra prompt string (may be empty)
_aicommit_generate() {
    local extra="$1"
    local status_out stat_out diff_out log_out prompt_out raw_json msg

    status_out="$(git status --short --branch 2>/dev/null)"
    stat_out="$(git diff --stat HEAD 2>/dev/null | head -n 30)"
    # Prefer staged diff; fall back to full diff against HEAD when nothing is staged
    if git diff --cached --quiet 2>/dev/null; then
        diff_out="$(git diff HEAD 2>/dev/null)"
    else
        diff_out="$(git diff --cached 2>/dev/null)"
    fi
    log_out="$(git log --oneline -5 2>/dev/null)"

    # Include untracked file list as a hint (not their full contents)
    local untracked
    untracked="$(git ls-files --others --exclude-standard 2>/dev/null | head -n 20)"

    # Truncate huge diffs (save tokens, ~12000 chars)
    if [ "${#diff_out}" -gt 12000 ]; then
        diff_out="$(printf '%s' "$diff_out" | head -c 12000)
... (truncated)"
    fi

    # If untracked content is missing from the diff, add a preview of up to 3 files
    if [ -n "$untracked" ] && git diff --cached --quiet 2>/dev/null; then
        local f preview
        preview=""
        for f in $untracked; do
            [ -f "$f" ] || continue
            preview="${preview}
--- untracked: $f ---
$(head -c 3000 "$f" 2>/dev/null)"
            # up to 3 files
            if [ "$(printf '%s' "$preview" | wc -l)" -gt 120 ]; then break; fi
        done
        if [ -n "$preview" ]; then
            if [ "${#preview}" -gt 6000 ]; then
                preview="$(printf '%s' "$preview" | head -c 6000)
... (truncated)"
            fi
            diff_out="${diff_out}${preview}"
        fi
    fi

    prompt_out="You are a git commit message generator. Read the info below and write a Conventional Commits message.
Rules:
- Output only the commit message body. No explanations, greetings, or code fences (\`\`\`).
- Format: <type>: <subject> + blank line if needed + body bullets (- ).
- type must be one of feat/fix/docs/style/refactor/perf/test/build/ci/chore.
- subject: max 50 chars, imperative mood, no trailing period, concise English.
- If there are multiple changes, subject covers the single most representative change, the rest go in body bullets.
- Keep the whole message under 4 lines (max 3 lines including the title) as a brief summary. Body bullets only when needed, max 2, one line each, concise.
- Mention filenames and core changes concretely. No speculation.
- No emoji by default. Use emoji only when the user asks.
"
    if [ -n "$extra" ]; then
        prompt_out="${prompt_out}- Additional requirement (highest priority): ${extra}
"
    fi
    prompt_out="${prompt_out}
[git status]
${status_out}

[git diff --stat]
${stat_out}

[recent commit style reference]
${log_out}

[diff]
${diff_out}"

    # < /dev/null: block interactive input (c/r/x) piped in from reaching opencode via stdin
    raw_json="$(opencode run --format json -m "$AICOMMIT_MODEL" "$prompt_out" </dev/null 2>/dev/null)"
    if [ $? -ne 0 ] || [ -z "$raw_json" ]; then
        echo "aicommit: opencode execution failed" >&2
        return 1
    fi

    msg="$(printf '%s' "$raw_json" | python3 -c '
import sys, json
texts = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("type") == "text":
        texts.append(obj.get("part", {}).get("text", ""))
out = "".join(texts).strip()
# Strip code fences if the model wrapped the output
if out.startswith("```"):
    lines = out.splitlines()
    lines = lines[1:]
    if lines and lines[-1].strip().startswith("```"):
        lines = lines[:-1]
    out = "\n".join(lines).strip()
print(out)
')"
    if [ -z "$msg" ]; then
        echo "aicommit: empty message generated (failed to parse opencode response)" >&2
        return 1
    fi
    printf '%s\n' "$msg"
}

# Perform the actual commit. $1 = message. Stage everything first when nothing is staged.
_aicommit_do_commit() {
    local msg="$1" tmp
    if git diff --cached --quiet 2>/dev/null; then
        # Nothing staged but working tree has changes: stage everything
        if git diff --quiet 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard)" ]; then
            echo "aicommit: nothing to commit." >&2
            return 1
        fi
        echo "aicommit: no staged changes, staging all changes (git add -A)."
        git add -A || return 1
    fi
    tmp="$(mktemp)" || return 1
    printf '%s\n' "$msg" > "$tmp"
    git commit -F "$tmp"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

aicommit() {
    local auto_commit=0 extra="" show_help=0 arg
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) show_help=1; shift ;;
            -c|--commit) auto_commit=1; shift ;;
            -r|--reprompt|--prompt|-p)
                shift
                if [ $# -eq 0 ]; then
                    echo "aicommit: -r requires a prompt string." >&2
                    return 1
                fi
                if [ -n "$extra" ]; then extra="$extra $1"; else extra="$1"; fi
                shift
                ;;
            -r=*|--reprompt=*|--prompt=*|-p=*)
                arg="${1#*=}"
                if [ -n "$extra" ]; then extra="$extra $arg"; else extra="$arg"; fi
                shift
                ;;
            -*) echo "aicommit: unknown option: $1 (see aicommit -h)" >&2; return 1 ;;
            *)  if [ -n "$extra" ]; then extra="$extra $1"; else extra="$1"; fi
                shift
                ;;
        esac
    done

    if [ "$show_help" -eq 1 ]; then
        _aicommit_usage
        return 0
    fi

    # 1) Check git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "aicommit: current directory is not a git repository." >&2
        return 1
    fi

    # 2) Check for changes
    if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard)" ]; then
        echo "aicommit: nothing to commit (working tree clean)." >&2
        return 1
    fi

    command -v opencode >/dev/null 2>&1 || { echo "aicommit: opencode command not found." >&2; return 1; }
    command -v python3 >/dev/null 2>&1 || { echo "aicommit: python3 command not found." >&2; return 1; }

    echo "aicommit: generating message with model [$AICOMMIT_MODEL]..."
    if [ -n "$extra" ]; then
        echo "aicommit: extra requirement: $extra"
    fi

    local msg
    msg="$(_aicommit_generate "$extra")" || return 1

    # 3) -c: commit immediately
    if [ "$auto_commit" -eq 1 ]; then
        echo "----------------------------------------"
        printf '%s\n' "$msg"
        echo "----------------------------------------"
        _aicommit_do_commit "$msg"
        return $?
    fi

    # 4) Interactive loop: c(commit) / r(regenerate) / x(exit) / extra-prompt->regenerate
    local input
    while true; do
        echo "----------------------------------------"
        printf '%s\n' "$msg"
        echo "----------------------------------------"
        printf '%s' "[c] commit / [r] regenerate / [x] exit (type an extra requirement to regenerate with it): "
        if ! read -r input; then
            echo
            echo "aicommit: exiting."
            return 0
        fi
        # Trim leading/trailing whitespace
        input="$(printf '%s' "$input" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$input" in
            c|C)
                _aicommit_do_commit "$msg" && return 0
                return 1
                ;;
            r|R)
                echo "aicommit: regenerating..."
                msg="$(_aicommit_generate "$extra")" || return 1
                ;;
            x|X|q|Q|quit|exit)
                echo "aicommit: exiting. (not committed)"
                return 0
                ;;
            "")
                echo "aicommit: enter c / r / x, or type an extra requirement."
                ;;
            *)
                if [ -n "$extra" ]; then extra="$extra $input"; else extra="$input"; fi
                echo "aicommit: regenerating with extra requirement... ($extra)"
                msg="$(_aicommit_generate "$extra")" || return 1
                ;;
        esac
    done
}

# Support direct execution: ./aicommit.sh -c ...
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    # zsh compatibility: without BASH_SOURCE, do not assume exec mode (source-safe)
    case "$0" in
        *aicommit.sh) aicommit "$@" ;;
    esac
fi
