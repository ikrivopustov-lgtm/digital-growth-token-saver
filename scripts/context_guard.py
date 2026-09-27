#!/usr/bin/env python3
"""codex-token-saver: UserPromptSubmit hook.

1. Считает заполненность контекста по последнему событию token_count в rollout
   (transcript_path) и на порогах (по умолчанию 60/75/85%) показывает пользователю
   рекомендацию /compact, а модели — инструкцию зафиксировать прогресс.
2. Ловит явное несоответствие профиля задаче: дорогая модель на рутине или
   дешёвая / low effort на сложной задаче. Каждое сообщение — не чаще раза за сессию.

Никогда не блокирует запрос: при любой ошибке молча выходит с кодом 0.
Совместим с python3 >= 3.8, только стандартная библиотека.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path

HOME = Path(os.environ.get("CODEX_TOKEN_SAVER_HOME", Path.home() / ".codex" / "token-saver"))
SETTINGS_PATH = HOME / "settings.json"
STATE_DIR = HOME / "state"

DEFAULTS = {
    "strong_model": "gpt-6-astra",
    "cheap_model": "gpt-6-luna",
    "thresholds": [60, 75, 85],
    "reset_below": 40,
    "baseline_tokens": 12000,
    "context_window_fallback": 0,
    "profile_hints": True,
    "tail_bytes": 4_000_000,
}

ROUTINE_RE = re.compile(
    r"(переимен|rename|опечат|typo|форматир|format\b|prettier|lint|линт|bump|обнови верс|"
    r"docstring|комментари|перевед|translate|readme|changelog|поправь текст|замени текст|"
    r"sort imports|unused import|неиспользуем|добавь тест по образцу|snapshot)",
    re.IGNORECASE,
)
DEEP_RE = re.compile(
    r"(архитектур|architect|спроектир|design doc|race|гонк|deadlock|утечк|memory leak|"
    r"security|безопасн|уязвим|auth|авториз|аутентиф|оплат|платеж|payment|billing|"
    r"миграц|migration|схем[аыу] (бд|данных|базы)|schema change|конкурент|concurren|"
    r"flaky|root cause|почему не работает|не понимаю почему|разберись почему|"
    r"производительн|performance|refactor (the )?(whole|entire)|рефактор(инг)? (всего|модуля|проекта))",
    re.IGNORECASE,
)
STRONG_EFFORTS = {"high", "xhigh", "max", "ultra"}
WEAK_EFFORTS = {"minimal", "low"}


def load_settings() -> dict:
    s = dict(DEFAULTS)
    try:
        s.update(json.loads(SETTINGS_PATH.read_text(encoding="utf-8")))
    except Exception:
        pass
    return s


def tail_lines(path: Path, max_bytes: int):
    size = path.stat().st_size
    with path.open("rb") as f:
        if size > max_bytes:
            f.seek(size - max_bytes)
            f.readline()  # drop partial line
        data = f.read()
    for raw in reversed(data.splitlines()):
        try:
            yield json.loads(raw)
        except Exception:
            continue


def read_transcript(path: Path, max_bytes: int):
    """Return (used_tokens, window, effort, model) from the most recent events."""
    used = window = None
    effort = model = None
    for obj in tail_lines(path, max_bytes):
        kind = obj.get("type")
        payload = obj.get("payload") or {}
        if used is None and kind == "event_msg" and payload.get("type") == "token_count":
            info = payload.get("info") or {}
            last = info.get("last_token_usage") or {}
            if last:
                total = int(last.get("total_tokens") or 0)
                reasoning = int(last.get("reasoning_output_tokens") or 0)
                used = max(total - reasoning, int(last.get("input_tokens") or 0))
                window = info.get("model_context_window") or window
        if effort is None and kind == "turn_context":
            effort = payload.get("effort") or payload.get("reasoning_effort")
            model = payload.get("model")
        if used is not None and effort is not None:
            break
    return used, window, effort, model


def load_state(session: str) -> dict:
    try:
        return json.loads((STATE_DIR / f"{session}.json").read_text(encoding="utf-8"))
    except Exception:
        return {"fired": [], "hints": []}


def save_state(session: str, state: dict) -> None:
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        (STATE_DIR / f"{session}.json").write_text(json.dumps(state), encoding="utf-8")
        # garbage-collect state older than 14 days
        cutoff = time.time() - 14 * 86400
        for p in STATE_DIR.glob("*.json"):
            if p.stat().st_mtime < cutoff:
                p.unlink()
    except Exception:
        pass


def context_messages(pct: float, level: int):
    p = int(round(pct))
    if level >= 85:
        ui = (f"⚠ Контекст ~{p}%. Сделай /compact сейчас или начни новую сессию "
              f"(`codex -p impl` → `$aif-implement` продолжит план).")
        model = (f"Контекст заполнен примерно на {p}%. Не начинай новых крупных шагов. "
                 "Доведи текущий шаг до стабильной точки, отметь прогресс в плане .ai-factory "
                 "(или кратко в .ai-factory/RESEARCH.md, если плана нет) и первой строкой ответа "
                 "попроси пользователя выполнить /compact.")
    elif level >= 75:
        ui = f"Контекст ~{p}%. После текущего шага стоит сделать /compact."
        model = (f"Контекст заполнен примерно на {p}%. Заверши текущий шаг, зафиксируй прогресс "
                 "в плане .ai-factory и в конце ответа одной строкой предложи пользователю /compact.")
    else:
        ui = f"Контекст ~{p}%. Запланируй /compact после завершения текущей задачи или фазы плана."
        model = None
    return ui, model


def profile_hint(prompt: str, model: str, effort: str, s: dict):
    if not prompt or not s.get("profile_hints", True):
        return None
    strong, cheap = s["strong_model"], s["cheap_model"]
    effort = (effort or "").lower()
    is_strong = bool(model) and model == strong and effort not in WEAK_EFFORTS
    is_weak = (bool(model) and model == cheap) or effort in WEAK_EFFORTS
    deep = bool(DEEP_RE.search(prompt)) or len(prompt) > 1500
    routine = bool(ROUTINE_RE.search(prompt)) and not deep and len(prompt) < 400
    if routine and is_strong:
        return ("to_fast",
                f"Похоже на рутину, а сессия на {model}/{effort}. Дешевле: `codex -p fast` "
                f"или `/model {cheap}` c effort low.")
    if deep and is_weak:
        return ("to_deep",
                f"Похоже на сложную задачу, а сессия на {model or '?'}/{effort or '?'}. "
                f"Для качества: `codex -p deep` или `/model {strong}` c effort high.")
    return None


def main() -> int:
    try:
        data = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return 0
    s = load_settings()
    session = str(data.get("session_id") or "unknown")
    state = load_state(session)
    ui_parts, model_parts = [], []

    tpath = data.get("transcript_path")
    used = window = effort = tmodel = None
    if tpath:
        try:
            used, window, effort, tmodel = read_transcript(Path(tpath), int(s["tail_bytes"]))
        except Exception:
            pass
    window = window or s.get("context_window_fallback") or None

    if used and window:
        base = int(s.get("baseline_tokens", 0))
        denom = max(window - base, 1)
        pct = max(0.0, min(100.0, (used - base) * 100.0 / denom))
        if pct < float(s.get("reset_below", 40)):
            state["fired"] = []
        crossed = [t for t in sorted(s["thresholds"]) if pct >= t and t not in state["fired"]]
        if crossed:
            level = crossed[-1]
            state["fired"] = sorted(set(state["fired"]) | {t for t in s["thresholds"] if t <= level})
            ui, mdl = context_messages(pct, level)
            ui_parts.append(ui)
            if mdl:
                model_parts.append(mdl)

    hint = profile_hint(str(data.get("prompt") or ""), str(data.get("model") or tmodel or ""), effort or "", s)
    if hint and hint[0] not in state["hints"]:
        state["hints"].append(hint[0])
        ui_parts.append(hint[1])
        if hint[0] == "to_deep":
            model_parts.append("Сигнал хука: " + hint[1] + " Если задача действительно сложная "
                               "(безопасность, деньги, миграции, конкурентность, неясная причина бага) — "
                               "сначала спроси пользователя, переключиться ли, и не вноси изменений до ответа.")
        else:
            model_parts.append("Сигнал хука: " + hint[1] + " Упомяни это одной строкой и продолжай, "
                               "если пользователь не попросил иначе.")

    save_state(session, state)
    if not ui_parts and not model_parts:
        return 0
    out = {"continue": True}
    if ui_parts:
        out["systemMessage"] = " ".join(ui_parts)
    if model_parts:
        out["hookSpecificOutput"] = {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": " ".join(model_parts),
        }
    sys.stdout.write(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
