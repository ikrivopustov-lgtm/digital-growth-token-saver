#!/usr/bin/env bash
# codex-token-saver installer
#
#   bash install.sh --project <repo> [options]
#
# Глобально (один раз):  ~/.agents/skills/codex-token-saver, ~/.codex/token-saver/,
#                        профили ~/.codex/{fast,impl,deep}.config.toml
# В проект:              ai-factory, роли Astra/Luna в .codex/agents, слияние .codex/config.toml,
#                        хук .codex/hooks.json, блок в AGENTS.md
#
# Опции:
#   --project DIR            проект (по умолчанию .)
#   --astra PROFILE          pro | plus | pro-max-2-subagents | plus-max-2-subagents |
#                            GPT6-SolMax-LunaMax | GPT6-SolMedium-LunaMax   (по умолчанию pro)
#   --strong MODEL           сильная модель (по умолчанию gpt-6-astra)
#   --cheap MODEL            дешёвая модель (по умолчанию gpt-6-luna)
#   --aif-agents LIST        для ai-factory init (по умолчанию codex; можно codex,codex-app)
#   --role-effort E          effort ролей на дешёвой модели: medium (по умолч.) | low | high | max | keep
#   --align-aif-models       модели агентов ai-factory: планирование и security → strong, реализация и сайдкары → cheap
#   --keep-model             не менять model/model_reasoning_effort корня в .codex/config.toml
#   --with-orchestrator-skill  поставить $astra-orchestrator (вызывать только явно)
#   --skip-aif | --skip-astra | --skip-hooks
#   --default-model MODEL    [вариант 1] модель по умолчанию в ~/.codex/config.toml (напр. gpt-6-sol
#                            или gpt-6-luna); на сильную переходить вручную через /model
#   --default-effort E       effort к --default-model (по умолчанию medium)
#   --global-rules           [вариант 2] блок правил в ~/.codex/AGENTS.md и хук в ~/.codex/hooks.json —
#                            работают в любом чате, в т.ч. в чатах приложения вне проектов
#   --no-project             только глобальная часть, проект не трогать
#   --vendor-dir DIR         взять codex-astra-luna-orchestrator из локальной папки (без git clone)
#   --force                  перезаписывать существующие профили и роли
#   --yes                    не задавать вопросов
#   --dry-run                только показать, что будет сделано
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="."; ASTRA="pro"; STRONG="gpt-6-astra"; CHEAP="gpt-6-luna"; AIF_AGENTS="codex"
ROLE_EFFORT="medium"; ALIGN_AIF=0; KEEP_MODEL=0; WITH_ORCH=0; SKIP_AIF=0; SKIP_ASTRA=0; SKIP_HOOKS=0
VENDOR_DIR=""; FORCE=0; YES=0; DRY=0
DEFAULT_MODEL=""; DEFAULT_EFFORT="medium"; GLOBAL_RULES=0; NO_PROJECT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --astra) ASTRA="$2"; shift 2 ;;
    --strong) STRONG="$2"; shift 2 ;;
    --cheap) CHEAP="$2"; shift 2 ;;
    --aif-agents) AIF_AGENTS="$2"; shift 2 ;;
    --role-effort) ROLE_EFFORT="$2"; shift 2 ;;
    --align-aif-models) ALIGN_AIF=1; shift ;;
    --keep-model) KEEP_MODEL=1; shift ;;
    --with-orchestrator-skill) WITH_ORCH=1; shift ;;
    --skip-aif) SKIP_AIF=1; shift ;;
    --skip-astra) SKIP_ASTRA=1; shift ;;
    --skip-hooks) SKIP_HOOKS=1; shift ;;
    --vendor-dir) VENDOR_DIR="$2"; shift 2 ;;
    --default-model) DEFAULT_MODEL="$2"; shift 2 ;;
    --default-effort) DEFAULT_EFFORT="$2"; shift 2 ;;
    --global-rules) GLOBAL_RULES=1; shift ;;
    --no-project) NO_PROJECT=1; shift ;;
    --force) FORCE=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,"");print;next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
TS_HOME="$CODEX_HOME/token-saver"
SKILL_HOME="$HOME/.agents/skills/codex-token-saver"
# Копия установщика в ~/.codex/token-saver/ лежит без SKILL.md и templates/ — берём их из скилла
if [ ! -f "$SRC/SKILL.md" ] || [ ! -d "$SRC/templates" ]; then
  if [ -f "$SKILL_HOME/SKILL.md" ] && [ -d "$SKILL_HOME/templates" ]; then SRC="$SKILL_HOME"
  else echo "Не найдены файлы скилла (SKILL.md, templates/) ни в $SRC, ни в $SKILL_HOME. Запусти install.sh из клона репозитория." >&2; exit 1; fi
fi
PROJECT="$(cd "$PROJECT" && pwd)"
DRYFLAG=""; [ "$DRY" = 1 ] && DRYFLAG="--dry-run"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
run()  { if [ "$DRY" = 1 ]; then info "[dry-run] $*"; else "$@"; fi; }
confirm() {
  [ "$YES" = 1 ] && return 0
  [ "$DRY" = 1 ] && return 0
  read -r -p "  $1 [y/N] " ans; [[ "$ans" =~ ^[YyДд] ]]
}

# ---------------------------------------------------------------- preflight
say "0. Проверка окружения"
info "! Закрой приложение Codex перед установкой: оно само пишет в ~/.codex/config.toml"
PY=""
for c in python3.13 python3.12 python3.11 python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys,tomllib; sys.exit(0 if sys.version_info>=(3,11) else 1)' 2>/dev/null; then
    PY="$(command -v "$c")"; break
  fi
done
[ -n "$PY" ] || { echo "Нужен python >= 3.11 (tomllib). macOS: brew install python@3.12" >&2; exit 1; }
info "python: $PY"
if command -v codex >/dev/null; then info "codex: $(codex --version 2>/dev/null | head -1)"; else info "codex: не найден в PATH (установка продолжится)"; fi
if [ "$NO_PROJECT" = 0 ]; then
  case "$PROJECT" in "$SRC"|"$SRC"/*) echo "Проект не должен быть папкой скилла" >&2; exit 2 ;; esac
  [ -d "$PROJECT/.git" ] || info "! $PROJECT не git-репозиторий — ai-factory и откаты удобнее с git"
  info "проект: $PROJECT"
fi
info "модели: strong=$STRONG cheap=$CHEAP · профиль Astra/Luna: $ASTRA · effort ролей: $ROLE_EFFORT"

# ---------------------------------------------------------------- global
say "1. Глобальная часть (скилл, рантайм, профили)"
if [ "$SRC" != "$SKILL_HOME" ]; then
  run mkdir -p "$SKILL_HOME"
  run cp -R "$SRC/SKILL.md" "$SRC/references" "$SRC/templates" "$SRC/scripts" "$SKILL_HOME/"
  [ -f "$SRC/README.md" ] && run cp "$SRC/README.md" "$SKILL_HOME/"
  info "скилл → $SKILL_HOME"
fi
run mkdir -p "$TS_HOME/state"
for f in tsctl.py context_guard.py delegate.sh install.sh; do run cp "$SRC/scripts/$f" "$TS_HOME/$f"; done
run chmod +x "$TS_HOME/delegate.sh" "$TS_HOME/install.sh" "$TS_HOME/tsctl.py" "$TS_HOME/context_guard.py"
if [ "$DRY" = 1 ]; then info "[dry-run] обёртка $TS_HOME/tsctl → $PY"; else
  printf '#!/usr/bin/env bash\nexec "%s" "%s/tsctl.py" "$@"\n' "$PY" "$TS_HOME" > "$TS_HOME/tsctl"; chmod +x "$TS_HOME/tsctl"
  info "✓ обёртка ~/.codex/token-saver/tsctl (python $("$PY" -c 'import sys;print(sys.version.split()[0])'))"
fi
SETTINGS="$TS_HOME/settings.json"
if [ ! -f "$SETTINGS" ] || [ "$FORCE" = 1 ]; then
  if [ "$DRY" = 1 ]; then info "[dry-run] settings.json (strong=$STRONG cheap=$CHEAP)"; else
    "$PY" - "$SETTINGS" "$STRONG" "$CHEAP" <<'PYEOF'
import json, sys
path, strong, cheap = sys.argv[1:4]
json.dump({"strong_model": strong, "cheap_model": cheap, "thresholds": [60, 75, 85],
           "reset_below": 40, "baseline_tokens": 12000, "context_window_fallback": 0,
           "profile_hints": True}, open(path, "w"), indent=2)
PYEOF
    info "✓ settings.json"
  fi
else info "= settings.json уже есть (--force чтобы перезаписать)"; fi

for prof in fast impl deep; do
  dst="$CODEX_HOME/$prof.config.toml"
  if [ -f "$dst" ] && [ "$FORCE" != 1 ]; then info "= профиль $prof уже есть"; continue; fi
  if [ "$DRY" = 1 ]; then info "[dry-run] профиль $dst"; continue; fi
  [ -f "$dst" ] && cp "$dst" "$dst.bak-$(date +%Y%m%d-%H%M%S)"
  sed -e "s/{{STRONG_MODEL}}/$STRONG/g" -e "s/{{CHEAP_MODEL}}/$CHEAP/g" "$SRC/templates/profiles/$prof.config.toml" > "$dst"
  info "✓ профиль $prof → $dst"
done

# ---------------------------------------------------------------- global defaults (варианты 1 и 2)
if [ -n "$DEFAULT_MODEL" ] || [ "$GLOBAL_RULES" = 1 ]; then
  say "1b. Глобальные настройки Codex (~/.codex)"
  GC=()
  [ -n "$DEFAULT_MODEL" ] && GC+=(--model "$DEFAULT_MODEL" --effort "$DEFAULT_EFFORT")
  [ "$GLOBAL_RULES" = 1 ] && GC+=(--hooks)
  "$PY" "$SRC/scripts/tsctl.py" global-config "${GC[@]}" $DRYFLAG
  if [ "$GLOBAL_RULES" = 1 ]; then
    PYH="$(command -v python3 || echo "$PY")"
    "$PY" "$SRC/scripts/tsctl.py" hooks --global --guard-cmd "$PYH $TS_HOME/context_guard.py" $DRYFLAG
    "$PY" "$SRC/scripts/tsctl.py" agents-md --global --template "$SRC/templates/AGENTS.global.md" $DRYFLAG
    info "! В Codex один раз одобри хук: /hooks"
  fi
fi

if [ "$NO_PROJECT" = 1 ]; then
  say "Готово (только глобальная часть)"
  [ "$DRY" = 1 ] && info "Это был dry-run — ничего не изменено."
  info "Проверка: ~/.codex/token-saver/tsctl status"
  exit 0
fi

# ---------------------------------------------------------------- vendor
ASTRA_SRC=""
if [ "$SKIP_ASTRA" = 0 ]; then
  say "2. codex-astra-luna-orchestrator"
  if [ -n "$VENDOR_DIR" ]; then ASTRA_SRC="$(cd "$VENDOR_DIR" && pwd)"
  else
    ASTRA_SRC="$TS_HOME/vendor/codex-astra-luna-orchestrator"
    if [ -d "$ASTRA_SRC/.git" ]; then run git -C "$ASTRA_SRC" pull --ff-only -q || info "! git pull не удался, использую текущую копию"
    else run mkdir -p "$TS_HOME/vendor"; run git clone -q --depth 1 https://github.com/donvito/codex-astra-luna-orchestrator.git "$ASTRA_SRC"; fi
  fi
  [ "$DRY" = 1 ] || [ -d "$ASTRA_SRC/profiles/$ASTRA" ] || { echo "Профиль $ASTRA не найден в $ASTRA_SRC/profiles" >&2; exit 1; }
  [ -d "$ASTRA_SRC/.git" ] && info "commit: $(git -C "$ASTRA_SRC" rev-parse --short HEAD 2>/dev/null || echo '?')"
fi

# ---------------------------------------------------------------- ai-factory
if [ "$SKIP_AIF" = 0 ]; then
  say "3. ai-factory (plan-first)"
  run mkdir -p "$PROJECT/.agents/skills"   # чтобы Codex CLI и App делили .agents/skills
  if ! command -v ai-factory >/dev/null; then
    if confirm "ai-factory не установлен. Выполнить npm install -g ai-factory?"; then run npm install -g ai-factory
    else info "пропущено — поставь позже: npm i -g ai-factory && ai-factory init --agents $AIF_AGENTS"; SKIP_AIF=1; fi
  fi
  if [ "$SKIP_AIF" = 0 ]; then
    if [ -f "$PROJECT/.ai-factory.json" ]; then
      info "ai-factory уже инициализирован — обновляю"
      (cd "$PROJECT" && run ai-factory update)
    else
      info "ai-factory init --agents $AIF_AGENTS (мастер может задать вопросы)"
      (cd "$PROJECT" && run ai-factory init --agents "$AIF_AGENTS")
    fi
  fi
fi

if [ "$ALIGN_AIF" = 1 ] && [ -d "$PROJECT/.codex/agents" ]; then
  say "3b. Модели агентов ai-factory"
  for f in "$PROJECT"/.codex/agents/{plan-coordinator,implement-coordinator,plan-polisher,implement-worker,review-sidecar,review-validator,security-sidecar,best-practices-sidecar,commit-preparer,docs-auditor}.toml; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in plan-coordinator.toml|plan-polisher.toml|security-sidecar.toml) m="$STRONG" ;; *) m="$CHEAP" ;; esac
    if [ "$DRY" = 1 ]; then info "[dry-run] $(basename "$f") → $m"; continue; fi
    sed -i.tmp -e "s/^model = .*/model = \"$m\"/" "$f" && rm -f "$f.tmp"
    info "✓ $(basename "$f") → $m"
  done
fi

# ---------------------------------------------------------------- astra roles + config
if [ "$SKIP_ASTRA" = 0 ]; then
  say "4. Роли Astra/Luna и .codex/config.toml"
  PROF_DIR="$ASTRA_SRC/profiles/$ASTRA"
  run mkdir -p "$PROJECT/.codex/agents"
  for f in "$PROF_DIR"/codex/agents/*.toml; do
    [ -e "$f" ] || continue
    dst="$PROJECT/.codex/agents/$(basename "$f")"
    if [ -f "$dst" ] && [ "$FORCE" != 1 ]; then info "= роль $(basename "$f") уже есть"; continue; fi
    if [ "$DRY" = 1 ]; then info "[dry-run] роль $(basename "$f")"; continue; fi
    sed -e "s/gpt-6-astra/$STRONG/g" -e "s/gpt-6-luna/$CHEAP/g" "$f" > "$dst"
    if [ "$ROLE_EFFORT" != keep ] && grep -q "^model = \"$CHEAP\"" "$dst"; then
      sed -i.tmp -e "s/^model_reasoning_effort = .*/model_reasoning_effort = \"$ROLE_EFFORT\"/" "$dst" && rm -f "$dst.tmp"
    fi
    info "✓ роль $(basename "$f") ($(sed -n 's/^model = "\(.*\)"/\1/p' "$dst") / $(sed -n 's/^model_reasoning_effort = "\(.*\)"/\1/p' "$dst"))"
  done
  TMP_OVERLAY="$(mktemp)"
  if [ -f "$PROF_DIR/codex/config.toml" ]; then
    sed -e "s/gpt-6-astra/$STRONG/g" -e "s/gpt-6-luna/$CHEAP/g" "$PROF_DIR/codex/config.toml" > "$TMP_OVERLAY"
    if [ "$ROLE_EFFORT" != keep ]; then
      sed -i.tmp -e "s/^default_subagent_reasoning_effort = .*/default_subagent_reasoning_effort = \"$ROLE_EFFORT\"/" "$TMP_OVERLAY" && rm -f "$TMP_OVERLAY.tmp"
    fi
  fi
  KM=""; [ "$KEEP_MODEL" = 1 ] && KM="--keep-model"
  "$PY" "$SRC/scripts/tsctl.py" merge-config --project "$PROJECT" --overlay "$TMP_OVERLAY" $KM $DRYFLAG
  rm -f "$TMP_OVERLAY"
  if [ "$WITH_ORCH" = 1 ]; then
    SK_DST="$PROJECT/.agents/skills/astra-orchestrator"
    run mkdir -p "$SK_DST"
    if [ "$DRY" = 1 ]; then info "[dry-run] \$astra-orchestrator → $SK_DST"; else
      sed -e "s/gpt-6-astra/$STRONG/g" -e "s/gpt-6-luna/$CHEAP/g" "$PROF_DIR/agents/skills/astra-orchestrator/SKILL.md" > "$SK_DST/SKILL.md"
      # вызывать только явно: убираем автотриггер по сложным задачам
      "$PY" - "$SK_DST/SKILL.md" <<'PYEOF'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = re.sub(r"^description:.*$", "description: Explicit-only multi-agent orchestration with pinned Astra/Luna roles. Use ONLY when the user explicitly invokes $astra-orchestrator or asks to orchestrate with subagents. Never select automatically.", s, count=1, flags=re.M)
open(p, "w", encoding="utf-8").write(s)
PYEOF
      info "✓ \$astra-orchestrator (только явный вызов)"
    fi
  fi
else
  "$PY" "$SRC/scripts/tsctl.py" merge-config --project "$PROJECT" --keep-model $DRYFLAG
fi

# ---------------------------------------------------------------- hooks
if [ "$SKIP_HOOKS" = 0 ]; then
  say "5. Хук контроля контекста"
  PYH="$(command -v python3 || echo "$PY")"
  "$PY" "$SRC/scripts/tsctl.py" hooks --project "$PROJECT" --guard-cmd "$PYH $TS_HOME/context_guard.py" $DRYFLAG
fi

# ---------------------------------------------------------------- AGENTS.md
say "6. AGENTS.md"
"$PY" "$SRC/scripts/tsctl.py" agents-md --project "$PROJECT" --template "$SRC/templates/AGENTS.token-discipline.md" $DRYFLAG

# ---------------------------------------------------------------- gitignore
GI="$PROJECT/.gitignore"
if ! grep -qs "codex-token-saver" "$GI"; then
  if [ "$DRY" = 1 ]; then info "[dry-run] .gitignore: бэкапы и .codex/delegate/"; else
    printf '\n# codex-token-saver\n.codex/*.bak-*\n.codex/delegate/\nAGENTS.md.bak-*\n' >> "$GI"; info "✓ .gitignore"; fi
fi

# ---------------------------------------------------------------- done
say "Готово${DRY:+}"
[ "$DRY" = 1 ] && info "Это был dry-run — ничего не изменено."
cat <<EOF
  Дальше:
  1. cd "$PROJECT" && codex        — при первом запуске отметь проект как trusted
  2. /status                      — проверь модель и effort
  3. \$aif                         — ai-factory опишет проект (один раз)
  4. Рутина:  codex -p fast   ·   план:  codex -p deep → \$aif-plan   ·   реализация:  codex -p impl → \$aif-implement
  5. Состояние: ~/.codex/token-saver/tsctl status --project "$PROJECT"
EOF
