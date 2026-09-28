#!/usr/bin/env bash
# Smoke-тест: установка в песочницу (фейковый HOME), идемпотентность, хук контекста,
# delegate.sh с фейковым codex. Сеть не нужна. Запуск: bash tests/smoke.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.codex" "$T/proj" "$T/bin"
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }

echo "1. Установка"
cd "$T/proj" && git init -q && printf '# Project\n\nexisting rules\n' > AGENTS.md
mkdir -p .codex && printf '[agents]\nmax_threads = 6\nmax_depth = 2\n' > .codex/config.toml
bash "$ROOT/scripts/install.sh" --project . --skip-aif --skip-astra --yes > "$T/install.log" 2>&1 || { cat "$T/install.log"; fail "install.sh"; }
[ -x "$HOME/.codex/token-saver/tsctl" ] && pass "обёртка tsctl" || fail "нет tsctl"
for p in fast impl deep; do [ -f "$HOME/.codex/$p.config.toml" ] || fail "нет профиля $p"; done; pass "профили fast/impl/deep"
grep -q "max_depth = 2" .codex/config.toml && grep -q "hooks = true" .codex/config.toml && pass "config.toml слит, ключи ai-factory сохранены" || fail "config.toml"
grep -q "context_guard.py" .codex/hooks.json && pass "хук подключён" || fail "hooks.json"
grep -q "existing rules" AGENTS.md && grep -q "codex-token-saver:start" AGENTS.md && pass "AGENTS.md: блок добавлен, старое сохранено" || fail "AGENTS.md"

echo "2. Идемпотентность"
cp -r "$T/proj" "$T/snap"
bash "$ROOT/scripts/install.sh" --project . --skip-aif --skip-astra --yes > /dev/null 2>&1
diff -rq --exclude='*.bak-*' --exclude=.git "$T/snap" "$T/proj" > /dev/null && pass "повторный запуск ничего не меняет" || fail "повторный запуск изменил файлы"

echo "3. Хук контекста"
G="$HOME/.codex/token-saver/context_guard.py"
roll() { python3 - "$1" "$2" "$3" > "$T/roll.jsonl" <<'EOF'
import json, sys
used, model, effort = int(sys.argv[1]), sys.argv[2], sys.argv[3]
print(json.dumps({"type": "turn_context", "payload": {"model": model, "effort": effort}}))
print(json.dumps({"type": "event_msg", "payload": {"type": "token_count", "info": {
    "last_token_usage": {"input_tokens": used, "output_tokens": 0, "reasoning_output_tokens": 0, "total_tokens": used},
    "model_context_window": 272000}}}))
EOF
}
ev() { printf '{"session_id":"%s","transcript_path":"%s","model":"%s","prompt":"%s"}' "$1" "$T/roll.jsonl" "$2" "$3" | python3 "$G"; }
roll 175000 gpt-6-astra high; ev s1 gpt-6-astra "продолжай" | grep -q "Контекст ~6" && pass "порог 60%" || fail "60%"
ev s1 gpt-6-astra "продолжай" | grep -q . && fail "повтор на том же пороге" || pass "без повторов"
roll 241000 gpt-6-astra high; ev s1 gpt-6-astra "дальше" | grep -q "/compact сейчас" && pass "порог 85%" || fail "85%"
roll 60000 gpt-6-astra high; ev s1 gpt-6-astra "ок" >/dev/null; roll 210000 gpt-6-astra high
ev s1 gpt-6-astra "ок" | grep -q "Контекст ~7" && pass "перевзвод после /compact" || fail "перевзвод"
roll 50000 gpt-6-astra high; ev s2 gpt-6-astra "переименуй переменную userName" | grep -q "codex -p fast" && pass "подсказка: рутина → fast" || fail "to_fast"
roll 50000 gpt-6-luna low; ev s3 gpt-6-luna "разберись почему падает оплата" | grep -q "codex -p deep" && pass "подсказка: сложное → deep" || fail "to_deep"
echo 'garbage' | python3 "$G" >/dev/null && pass "мусор на входе не ломает хук" || fail "exit code"

echo "4. delegate.sh"
cat > "$T/bin/codex" <<'EOF'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do case "$1" in --output-last-message) out="$2"; shift 2;; *) shift;; esac; done
d="$HOME/.codex/sessions/2026/01/01"; mkdir -p "$d"; sleep 1
printf '{"type":"turn_context","payload":{"model":"%s"}}\n' "$FAKE_MODEL" > "$d/rollout-$RANDOM.jsonl"
echo "ok" > "$out"
EOF
chmod +x "$T/bin/codex"; export PATH="$T/bin:$PATH"
FAKE_MODEL=gpt-6-luna bash "$HOME/.codex/token-saver/delegate.sh" "task" 2>&1 | grep -q "модель: gpt-6-luna ✓" && pass "модель подтверждена" || fail "delegate ok"
FAKE_MODEL=gpt-6-astra bash "$HOME/.codex/token-saver/delegate.sh" "task" 2>&1 | grep -q "MODEL MISMATCH" && pass "подмена модели поймана" || fail "delegate mismatch"

echo "5. Глобально: модель по умолчанию (вариант 1) и правила/хук для всех чатов (вариант 2)"
printf '# my comment\nmodel = "gpt-6-astra"\napproval_policy = "on-request"\n\n[mcp_servers.x]\ncommand = "x"\n' > "$HOME/.codex/config.toml"
printf '# Мои глобальные правила\n' > "$HOME/.codex/AGENTS.md"
bash "$ROOT/scripts/install.sh" --no-project --default-model gpt-6-sol --global-rules --yes > "$T/g.log" 2>&1 || { cat "$T/g.log"; fail "install --no-project"; }
python3 - "$HOME/.codex/config.toml" <<'EOF2' && pass "config.toml: model=sol/medium, hooks=true, остальное сохранено" || fail "global config.toml"
import sys, tomllib; d = tomllib.load(open(sys.argv[1], "rb"))
assert d["model"] == "gpt-6-sol" and d["model_reasoning_effort"] == "medium"
assert d["features"]["hooks"] is True and d["approval_policy"] == "on-request" and d["mcp_servers"]["x"]["command"] == "x"
EOF2
ls "$HOME/.codex"/config.toml.bak-* >/dev/null 2>&1 && pass "бэкап config.toml" || fail "нет бэкапа"
grep -q context_guard.py "$HOME/.codex/hooks.json" && pass "глобальный хук" || fail "~/.codex/hooks.json"
grep -q "Мои глобальные правила" "$HOME/.codex/AGENTS.md" && grep -q "codex-token-saver:start" "$HOME/.codex/AGENTS.md" && pass "~/.codex/AGENTS.md: блок добавлен, старое сохранено" || fail "global AGENTS.md"
[ "$(du -b "$HOME/.codex/AGENTS.md" | cut -f1)" -lt 4000 ] && pass "глобальный блок компактный" || fail "блок слишком большой"
cp -r "$HOME/.codex" "$T/gsnap"
bash "$ROOT/scripts/install.sh" --no-project --default-model gpt-6-sol --global-rules --yes > /dev/null 2>&1
diff -rq --exclude="*.bak-*" --exclude=state --exclude=sessions "$T/gsnap" "$HOME/.codex" && pass "глобально: повтор ничего не меняет" || fail "глобальный повтор изменил файлы"
mkdir -p "$T/proj2" && cd "$T/proj2" && git init -q
bash "$ROOT/scripts/install.sh" --project . --skip-aif --skip-astra --yes > /dev/null 2>&1
[ ! -f .codex/hooks.json ] && pass "новый проект не дублирует глобальный хук" || fail "хук продублирован"
roll 50000 gpt-6-sol medium; ev g1 gpt-6-sol "разберись почему падает оплата" | grep -q "/model gpt-6-astra" && pass "Sol на сложной задаче → подсказка про Astra" || fail "sol to_deep"
roll 50000 gpt-6-sol medium; ev g2 gpt-6-sol "переименуй переменную x" | grep -q . && fail "лишняя подсказка на Sol" || pass "Sol на рутине — без подсказок"
roll 175000 gpt-6-sol medium; a="$(ev g3 gpt-6-sol "дальше")"; b="$(ev g3 gpt-6-sol "дальше")"
[ -n "$a" ] && [ -z "$b" ] && pass "хук в проекте и глобально — сообщение одно" || fail "дубль сообщения"
"$HOME/.codex/token-saver/tsctl" status --project "$T/proj2" > "$T/st.txt" && grep -q "✓ глобальный хук" "$T/st.txt" && pass "tsctl status видит глобальную часть" || fail "status"
cd "$T/proj"; roll 50000 gpt-6-astra high
bash "$ROOT/scripts/install.sh" --no-project --dry-run --default-model gpt-6-luna --global-rules --yes > /dev/null 2>&1
grep -q '"gpt-6-sol"' "$HOME/.codex/config.toml" && pass "dry-run ничего не пишет" || fail "dry-run записал"

echo; echo "Все проверки пройдены."
