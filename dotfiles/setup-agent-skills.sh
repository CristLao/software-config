#!/usr/bin/bash
# 全局安装 Agent Skills
#
# 用法:
#   bash setup-agent-skills.sh              # 仅安装尚未全局安装的 Skill
#   bash setup-agent-skills.sh -f|--force   # 强制重新安装全部 Skill
#
# 默认通过 `skills list -g --json` 检查全局安装状态.
# 同一仓库仅有部分 Skill 缺失时, 只安装缺失项.
# 依赖: vercel-labs/skills CLI
# Eve 和 PromptScript 不支持全局安装, 会失败, 属于预期行为
set -Eeuo pipefail

FORCE=0
while (($#)); do
  case "$1" in
    -f | --force) FORCE=1 ;;
    -h | --help)
      echo "Usage: bash setup-agent-skills.sh [-f|--force]"
      echo "  -f, --force  Reinstall all skills."
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# 目录映射:
#   --agent zed -> ~/.agents/skills/  (兼容 omp, snow ...)
#   --agent pi  -> ~/.pi/agent/skills/
AGENT_ARGS=()
declare -A INSTALLED_SKILLS=()
declare -A INSTALLED_SOURCES=()

if ((FORCE == 0)); then
  installed_json="$(skills list -g --json)"

  while IFS= read -r skill; do
    [[ -n "$skill" ]] && INSTALLED_SKILLS["$skill"]=1
  done < <(sed -n 's/^[[:space:]]*"name":[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$installed_json")

  while IFS= read -r source; do
    [[ -n "$source" ]] && INSTALLED_SOURCES["$source"]=1
  done < <(sed -n 's/^[[:space:]]*"source":[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$installed_json")
fi

agents() { AGENT_ARGS=(); for a in "$@"; do AGENT_ARGS+=(--agent "$a"); done; }
add_skills() {
  local repo="$1"; shift
  local -a requested_skills=()
  local -a other_args=()
  local -a skills_to_install=()

  while (($#)); do
    case "$1" in
      -s | --skill)
        shift
        while (($#)) && [[ "$1" != -* ]]; do
          requested_skills+=("$1")
          shift
        done
        ;;
      *)
        other_args+=("$1")
        shift
        ;;
    esac
  done

  if ((${#requested_skills[@]})); then
    local skill
    for skill in "${requested_skills[@]}"; do
      if ((FORCE)) || [[ ! -v "INSTALLED_SKILLS[$skill]" ]]; then
        skills_to_install+=("$skill")
      else
        echo "Skipping ${skill}: already installed."
      fi
    done

    ((${#skills_to_install[@]})) || return 0

    local -a skill_args=()
    for skill in "${skills_to_install[@]}"; do
      skill_args+=(-s "$skill")
    done

    echo "Installing ${repo} (${skills_to_install[*]})..."
    skills add "$repo" -g "${AGENT_ARGS[@]}" "${other_args[@]}" "${skill_args[@]}" -y

    for skill in "${skills_to_install[@]}"; do
      INSTALLED_SKILLS["$skill"]=1
    done
    return
  fi

  local owner repo_name _
  IFS=/ read -r owner repo_name _ <<<"$repo"
  local source="${owner}/${repo_name%.git}"
  if ((FORCE == 0)) && [[ -v "INSTALLED_SOURCES[$source]" ]]; then
    echo "Skipping ${repo}: source already installed."
    return
  fi

  echo "Installing ${repo}..."
  skills add "$repo" -g "${AGENT_ARGS[@]}" "${other_args[@]}" -y
  INSTALLED_SOURCES["$source"]=1
}

# === Base ===
agents pi zed
add_skills vercel-labs/skills -s find-skills
add_skills iOfficeAI/OfficeCLI
# add_skills ogulcancelik/herdr --s herdr
add_skills browser-act/skills -s browser-act -s browser-act-skill-forge
add_skills stablyai/orca -s orca-cli -s computer-use -s orchestration

add_skills Snailclimb/AIGuide/skills/drawio-chart -s drawio-chart
add_skills JuliusBrussee/caveman -s cavecrew -s caveman -s caveman-commit -s caveman-compress -s caveman-help -s caveman-review -s caveman-stats
add_skills uview-pro/skills

# === Development ===
agents zed
add_skills t8y2/dbx -s dbx
add_skills upstash/context7 -s context7-cli
add_skills anthropics/skills -s frontend-design
add_skills mattpocock/skills -s grill-me -s grill-with-docs
# add_skills obra/superpowers --all

echo "Skills setup done."
