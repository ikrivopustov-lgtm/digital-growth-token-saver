#!/usr/bin/env bash
# codex-token-saver: делегировать рутину отдельному codex exec на дешёвом профиле
# и проверить, какая модель реально отработала.
#
#   delegate.sh [-p fast|impl|<profile>] [-w] [-o out.md] "задача"
#     -p  профиль (по умолчанию fast)
#     -w  разрешить запись в рабочую папку (по умолчанию read-only)
#     -o  куда сохранить итоговый ответ (по умолчанию .codex/delegate/<время>.md)
set -euo pipefail

PROFILE="fast"; SANDBOX="read-only"; OUT=""
while getopts ":p:wo:h" opt; do
  case "$opt" in
    p) PROFILE="$OPTARG" ;;
    w) SANDBOX="workspace-write" ;;
    o) OUT="$OPTARG" ;;
    h) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "неизвестный флаг -$OPTARG" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
TASK="${*:-}"
[ -n "$TASK" ] || { echo "Нужна задача: delegate.sh \"...\"" >&2; exit 2; }
command -v codex >/dev/null || { echo "codex не найден в PATH" >&2; exit 1; }

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
PROFILE_FILE="$CODEX_HOME/$PROFILE.config.toml"
[ -f "$PROFILE_FILE" ] || { echo "Нет профиля $PROFILE_FILE — запусти install.sh" >&2; exit 1; }
EXPECTED_MODEL="$(sed -n 's/^model *= *"\(.*\)"/\1/p' "$PROFILE_FILE" | head -1)"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-.codex/delegate/$STAMP.md}"
mkdir -p "$(dirname "$OUT")"
MARKER="$(mktemp)"; trap 'rm -f "$MARKER"' EXIT

PROMPT="$TASK

Правила: работай только в рамках задачи; не спавни субагентов; вывод команд держи узким,
но при ошибке показывай её целиком. Верни кратко: результат, изменённые файлы (если есть),
чем проверено, что осталось неясным."

echo "→ codex exec -p $PROFILE --sandbox $SANDBOX (ожидаемая модель: ${EXPECTED_MODEL:-?})"
set +e
codex exec -p "$PROFILE" --sandbox "$SANDBOX" -c 'agents.max_depth=0' \
  --output-last-message "$OUT" "$PROMPT" >/dev/null
RC=$?
set -e

# найти rollout, созданный этим запуском, и проверить модель
ROLLOUT="$(find "$CODEX_HOME/sessions" -name 'rollout-*.jsonl' -newer "$MARKER" 2>/dev/null | sort | tail -1 || true)"
ACTUAL=""
if [ -n "$ROLLOUT" ]; then
  ACTUAL="$(grep '"turn_context"' "$ROLLOUT" | tail -1 | sed -n 's/.*"model" *: *"\([^"]*\)".*/\1/p')"
fi

echo "← код выхода: $RC · ответ: $OUT"
if [ -n "$ACTUAL" ]; then
  if [ -n "$EXPECTED_MODEL" ] && [ "$ACTUAL" != "$EXPECTED_MODEL" ]; then
    echo "MODEL MISMATCH: ожидалась $EXPECTED_MODEL, отработала $ACTUAL" >&2
  else
    echo "модель: $ACTUAL ✓"
  fi
else
  echo "модель: не удалось определить (rollout не найден)"
fi
[ -f "$OUT" ] && head -c 1500 "$OUT" && echo
exit "$RC"
