# aicommit - opencode 기반 git commit message 자동 생성기
# ~/.tools/*.sh 자동 로드 방식 (source) 으로 사용.
# 모델: opencode/muse-spark-1.3-contributor-free (무료 모델, env AICOMMIT_MODEL 로 변경 가능)
#
# 사용법:
#   aicommit                       # 메시지 생성 후 c/r/x/추가프롬프트 입력 대기
#   aicommit -c                    # 생성 후 바로 커밋 (확인 없음)
#   aicommit -r "이모지 풍부하게"   # 추가 프롬프트 반영해서 생성 (대화형 계속)
#   aicommit -c -r "이모지 풍부하게" # 추가 프롬프트 반영 + 바로 커밋
#   aicommit "이모지 풍부하게"       # 위치 인자도 추가 프롬프트로 취급
#   aicommit -h                    # 도움말
#
# 대화형 선택:
#   c   : 바로 커밋
#   r   : 다시 생성 (같은 조건)
#   x   : 종료 (끝, q, exit 도 동일)
#   그 외 입력 : 추가 프롬프트로 반영해서 다시 생성
#   끝  : 종료

# 모델 (필요시 export AICOMMIT_MODEL=... 로 변경)
: "${AICOMMIT_MODEL:=opencode/muse-spark-1.3-contributor-free}"

_aicommit_usage() {
    cat <<'EOF'
사용법: aicommit [옵션] [추가 프롬프트...]

옵션:
  -c, --commit          생성된 메시지로 바로 커밋 (확인 없음)
  -r, --reprompt TEXT   추가 요구사항 프롬프트 (예: -r "이모지 풍부하게")
  -h, --help            도움말 출력

예시:
  aicommit
  aicommit -c
  aicommit -r "이모지 풍부하게"
  aicommit -c -r "이모지 풍부하게, 한국어로"
  aicommit "제목은 영어로, 본문은 한국어로"

대화형 (그냥 aicommit 실행 시):
  c          바로 커밋
  r          다시 생성
  x          종료 (끝/q/exit 동일)
  <문장 입력> 입력한 요구사항을 반영해서 다시 생성
  끝         종료
EOF
}

# opencode 호출로 커밋 메시지 1건 생성. stdout으로 메시지만 출력. 실패시 1 반환.
# $1 = 추가 프롬프트 문자열 (없을 수 있음)
_aicommit_generate() {
    local extra="$1"
    local status_out stat_out diff_out log_out prompt_out raw_json msg

    status_out="$(git status --short --branch 2>/dev/null)"
    stat_out="$(git diff --stat HEAD 2>/dev/null | head -n 30)"
    # staged 우선, 없으면 HEAD 대비 전체
    if git diff --cached --quiet 2>/dev/null; then
        diff_out="$(git diff HEAD 2>/dev/null)"
    else
        diff_out="$(git diff --cached 2>/dev/null)"
    fi
    log_out="$(git log --oneline -5 2>/dev/null)"

    # untracked 파일 목록도 힌트로 포함 (내용까지는 포함하지 않음)
    local untracked
    untracked="$(git ls-files --others --exclude-standard 2>/dev/null | head -n 20)"

    # 너무 큰 diff 잘라내기 (토큰 절약, 약 12000자)
    if [ "${#diff_out}" -gt 12000 ]; then
        diff_out="$(printf '%s' "$diff_out" | head -c 12000)
... (truncated)"
    fi

    # untracked 파일 내용이 diff에 없으면 최대 3개까지 미리보기 추가
    if [ -n "$untracked" ] && git diff --cached --quiet 2>/dev/null; then
        local f preview
        preview=""
        for f in $untracked; do
            [ -f "$f" ] || continue
            preview="${preview}
--- untracked: $f ---
$(head -c 3000 "$f" 2>/dev/null)"
            # 3개까지만
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

    prompt_out="너는 git commit message 생성기다. 아래 정보를 보고 Conventional Commits 형식으로 커밋 메시지를 작성하라.
규칙:
- 출력은 커밋 메시지 본문만. 설명, 인사, 코드펜스(\`\`\`) 없이 출력.
- 형식: <type>: <subject> + 필요시 빈 줄 + 본문 불릿(- ).
- type은 feat/fix/docs/style/refactor/perf/test/build/ci/chore 중 하나.
- subject는 50자 이내, 명령문, 마침표 없음, 한국어 간결체 기본.
- 변경이 여러 개면 subject는 대표 변경 1개, 나머지는 본문 불릿으로.
- 파일명·핵심 변경 내용을 구체적으로 적는다. 추측 금지.
- 이모지는 기본적으로 사용하지 않는다. 사용자가 요구할 때만 사용.
"
    if [ -n "$extra" ]; then
        prompt_out="${prompt_out}- 추가 요구사항 (최우선 반영): ${extra}
"
    fi
    prompt_out="${prompt_out}
[git status]
${status_out}

[git diff --stat]
${stat_out}

[최근 커밋 스타일 참고]
${log_out}

[diff]
${diff_out}"

    # < /dev/null: 파이프로 들어온 대화형 입력(c/r/x)이 opencode에 먹히지 않도록 stdin 차단
    raw_json="$(opencode run --format json -m "$AICOMMIT_MODEL" "$prompt_out" </dev/null 2>/dev/null)"
    if [ $? -ne 0 ] || [ -z "$raw_json" ]; then
        echo "aicommit: opencode 실행 실패" >&2
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
# 모델이 코드펜스로 감싸면 벗기기
if out.startswith("```"):
    lines = out.splitlines()
    lines = lines[1:]
    if lines and lines[-1].strip().startswith("```"):
        lines = lines[:-1]
    out = "\n".join(lines).strip()
print(out)
')"
    if [ -z "$msg" ]; then
        echo "aicommit: 빈 메시지가 생성됨 (opencode 응답 파싱 실패)" >&2
        return 1
    fi
    printf '%s\n' "$msg"
}

# 실제 커밋 수행. $1 = 메시지. staged 없으면 전체 스테이징 후 커밋.
_aicommit_do_commit() {
    local msg="$1" tmp
    if git diff --cached --quiet 2>/dev/null; then
        # 스테이징된 게 없는데 변경은 있으면 전체 스테이징
        if git diff --quiet 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard)" ]; then
            echo "aicommit: 커밋할 변경사항이 없습니다." >&2
            return 1
        fi
        echo "aicommit: 스테이징된 변경이 없어 전체 변경을 스테이징합니다 (git add -A)."
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
                    echo "aicommit: -r 뒤에 프롬프트 문자열이 필요합니다." >&2
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
            -*) echo "aicommit: 알 수 없는 옵션: $1 (aicommit -h 참조)" >&2; return 1 ;;
            *)  if [ -n "$extra" ]; then extra="$extra $1"; else extra="$1"; fi
                shift
                ;;
        esac
    done

    if [ "$show_help" -eq 1 ]; then
        _aicommit_usage
        return 0
    fi

    # 1) git repository 확인
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "aicommit: 현재 디렉토리는 git repository가 아닙니다." >&2
        return 1
    fi

    # 2) 변경사항 확인
    if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard)" ]; then
        echo "aicommit: 커밋할 변경사항이 없습니다 (working tree clean)." >&2
        return 1
    fi

    command -v opencode >/dev/null 2>&1 || { echo "aicommit: opencode 명령을 찾을 수 없습니다." >&2; return 1; }
    command -v python3 >/dev/null 2>&1 || { echo "aicommit: python3 명령을 찾을 수 없습니다." >&2; return 1; }

    echo "aicommit: 모델 [$AICOMMIT_MODEL] 로 메시지 생성 중..."
    if [ -n "$extra" ]; then
        echo "aicommit: 추가 요구사항: $extra"
    fi

    local msg
    msg="$(_aicommit_generate "$extra")" || return 1

    # 3) -c: 바로 커밋
    if [ "$auto_commit" -eq 1 ]; then
        echo "----------------------------------------"
        printf '%s\n' "$msg"
        echo "----------------------------------------"
        _aicommit_do_commit "$msg"
        return $?
    fi

    # 4) 대화형 루프: c(커밋) / r(다시생성) / x(종료) / 추가프롬프트→재생성 / 끝→종료
    local input
    while true; do
        echo "----------------------------------------"
        printf '%s\n' "$msg"
        echo "----------------------------------------"
        printf '%s' "[c] 커밋 / [r] 다시 생성 / [x] 종료 (추가 요구사항 입력 시 반영 후 재생성, '끝' 입력 시 종료): "
        if ! read -r input; then
            echo
            echo "aicommit: 종료합니다."
            return 0
        fi
        # 앞뒤 공백 제거
        input="$(printf '%s' "$input" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$input" in
            c|C)
                _aicommit_do_commit "$msg" && return 0
                return 1
                ;;
            r|R)
                echo "aicommit: 다시 생성 중..."
                msg="$(_aicommit_generate "$extra")" || return 1
                ;;
            x|X|q|Q|quit|exit|끝)
                echo "aicommit: 종료합니다. (커밋하지 않음)"
                return 0
                ;;
            "")
                echo "aicommit: c / r / x 중 하나를 입력하거나 추가 요구사항을 입력하세요."
                ;;
            *)
                if [ -n "$extra" ]; then extra="$extra $input"; else extra="$input"; fi
                echo "aicommit: 추가 요구사항 반영하여 다시 생성 중... ($extra)"
                msg="$(_aicommit_generate "$extra")" || return 1
                ;;
        esac
    done
}

# 직접 실행도 지원: ./aicommit.sh -c ...
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    # zsh 호환: BASH_SOURCE가 없으면 그냥 실행 모드로 간주하지 않음 (source 안전)
    case "$0" in
        *aicommit.sh) aicommit "$@" ;;
    esac
fi
