#!/usr/bin/env python3
"""codex-token-saver control tool.

Subcommands:
  merge-config  слить профиль Astra/Luna в .codex/config.toml, сохранив ai-factory и ваши ключи
  agents-md     вставить/обновить блок token discipline в AGENTS.md
  hooks         подключить context_guard в .codex/hooks.json
  status        показать состояние сетапа

Требует python >= 3.11 (tomllib). Только стандартная библиотека.
Любая запись делает бэкап <file>.bak-<timestamp>.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    sys.exit("tsctl.py требует python >= 3.11 (нужен tomllib). Установите: brew install python@3.12")

HOME = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
TS_HOME = Path(os.environ.get("CODEX_TOKEN_SAVER_HOME", HOME / "token-saver"))
MARK_START = "<!-- codex-token-saver:start -->"
MARK_END = "<!-- codex-token-saver:end -->"

# ---------------------------------------------------------------- TOML writer

BARE = re.compile(r"^[A-Za-z0-9_-]+$")


def _key(k: str) -> str:
    return k if BARE.match(k) else json.dumps(k, ensure_ascii=False)


def _str(s: str) -> str:
    if "\n" in s and "'''" not in s:
        return "'''\n" + s + ("" if s.endswith("\n") else "\n") + "'''"
    out = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")
    return f'"{out}"'


def _val(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return _str(v)
    if isinstance(v, (dt.datetime, dt.date, dt.time)):
        return v.isoformat()
    if isinstance(v, list):
        return "[" + ", ".join(_inline(x) for x in v) + "]"
    if isinstance(v, dict):
        return _inline(v)
    raise TypeError(f"unsupported TOML value {type(v)}")


def _inline(v) -> str:
    if isinstance(v, dict):
        return "{ " + ", ".join(f"{_key(k)} = {_inline(x)}" for k, x in v.items()) + " }"
    if isinstance(v, str) and "\n" in v:
        return json.dumps(v, ensure_ascii=False)
    return _val(v)


def _is_aot(v) -> bool:
    return isinstance(v, list) and v and all(isinstance(x, dict) for x in v)


def dump_toml(data: dict) -> str:
    lines: list[str] = []

    def emit(table: dict, path: list[str], header: str | None):
        scalars = [(k, v) for k, v in table.items() if not isinstance(v, dict) and not _is_aot(v)]
        subs = [(k, v) for k, v in table.items() if isinstance(v, dict)]
        aots = [(k, v) for k, v in table.items() if _is_aot(v)]
        if header is not None and (scalars or not (subs or aots)):
            if lines:
                lines.append("")
            lines.append(header)
        for k, v in scalars:
            lines.append(f"{_key(k)} = {_val(v)}")
        for k, v in subs:
            p = path + [k]
            emit(v, p, "[" + ".".join(_key(x) for x in p) + "]")
        for k, v in aots:
            p = path + [k]
            for item in v:
                lines.append("")
                lines.append("[[" + ".".join(_key(x) for x in p) + "]]")
                inner = [(ik, iv) for ik, iv in item.items()]
                for ik, iv in inner:
                    if isinstance(iv, dict) or _is_aot(iv):
                        lines.append(f"{_key(ik)} = {_inline(iv) if isinstance(iv, dict) else _val(iv)}")
                    else:
                        lines.append(f"{_key(ik)} = {_val(iv)}")

    emit(data, [], None)
    return "\n".join(lines).strip() + "\n"


# ---------------------------------------------------------------- helpers


def load_toml(p: Path) -> dict:
    if not p.exists():
        return {}
    with p.open("rb") as f:
        return tomllib.load(f)


def backup(p: Path) -> Path | None:
    if not p.exists():
        return None
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    b = p.with_name(f"{p.name}.bak-{stamp}")
    n = 1
    while b.exists():
        b = p.with_name(f"{p.name}.bak-{stamp}-{n}")
        n += 1
    shutil.copy2(p, b)
    return b


def write(p: Path, text: str, dry: bool, label: str) -> None:
    if p.exists() and p.read_text(encoding="utf-8") == text:
        print(f"  = {label}: без изменений")
        return
    if dry:
        print(f"  ~ {label}: будет записан ({p})")
        return
    p.parent.mkdir(parents=True, exist_ok=True)
    b = backup(p)
    p.write_text(text, encoding="utf-8")
    print(f"  ✓ {label}: записан" + (f" (бэкап {b.name})" if b else ""))


def deep_merge(base: dict, overlay: dict, keep: set[str], prefix: str = "") -> dict:
    out = dict(base)
    for k, v in overlay.items():
        dotted = f"{prefix}{k}"
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v, keep, dotted + ".")
        elif dotted in keep and k in out:
            continue
        else:
            out[k] = v
    return out


def validate_roundtrip(text: str) -> None:
    tomllib.loads(text)


# ---------------------------------------------------------------- merge-config


def cmd_merge_config(a) -> int:
    proj = Path(a.project).resolve()
    cfg = proj / ".codex" / "config.toml"
    base = load_toml(cfg)
    overlay = load_toml(Path(a.overlay)) if a.overlay else {}
    # ai-factory relies on its own agent depth/threads; user-set model keys win if --keep-model
    keep = {"agents.max_depth", "agents.max_threads", "agents.job_max_runtime_seconds"}
    if a.keep_model:
        keep |= {"model", "model_reasoning_effort"}
    merged = deep_merge(base, overlay, keep)
    merged.setdefault("features", {})
    merged["features"]["hooks"] = True
    text = "# Managed in part by ai-factory and codex-token-saver. Backups: config.toml.bak-*\n" + dump_toml(merged)
    validate_roundtrip(text)
    write(cfg, text, a.dry_run, ".codex/config.toml")
    return 0


# ---------------------------------------------------------------- agents-md

ASTRA_LINE = re.compile(r"^.*use the `astra-orchestrator` skill when its trigger conditions match.*\n?", re.M)


def cmd_agents_md(a) -> int:
    proj = Path(a.project).resolve()
    p = proj / "AGENTS.md"
    block = Path(a.template).read_text(encoding="utf-8").strip() + "\n"
    cur = p.read_text(encoding="utf-8") if p.exists() else "# Project instructions\n"
    cur = ASTRA_LINE.sub("", cur)
    if MARK_START in cur and MARK_END in cur:
        pre, rest = cur.split(MARK_START, 1)
        _, post = rest.split(MARK_END, 1)
        new = pre + block.strip() + post
    else:
        new = cur.rstrip() + "\n\n" + block
    write(p, new if new.endswith("\n") else new + "\n", a.dry_run, "AGENTS.md (блок token discipline)")
    size = len(new.encode())
    if size > 24_000:
        print(f"  ! AGENTS.md {size} байт — он читается каждый ход. Вынеси длинные разделы в docs/ со ссылками.")
    return 0


# ---------------------------------------------------------------- hooks


def cmd_hooks(a) -> int:
    proj = Path(a.project).resolve()
    p = proj / ".codex" / "hooks.json"
    data = {}
    if p.exists():
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            print(f"  ! {p} не JSON — пропускаю, поправь вручную")
            return 1
    hooks = data.setdefault("hooks", {})
    ups = hooks.setdefault("UserPromptSubmit", [])
    already = any("context_guard.py" in h.get("command", "") for grp in ups for h in grp.get("hooks", []))
    if not already:
        ups.append({"hooks": [{
            "type": "command",
            "command": a.guard_cmd,
            "statusMessage": "token-saver: контекст",
            "timeout": 10,
        }]})
    write(p, json.dumps(data, ensure_ascii=False, indent=2) + "\n", a.dry_run, ".codex/hooks.json")
    return 0


# ---------------------------------------------------------------- status


def cmd_status(a) -> int:
    proj = Path(a.project).resolve()
    ok = lambda b: "✓" if b else "✗"
    print(f"Проект: {proj}")
    s = {}
    try:
        s = json.loads((TS_HOME / "settings.json").read_text())
    except Exception:
        pass
    print(f"  {ok(bool(s))} settings: strong={s.get('strong_model','?')} cheap={s.get('cheap_model','?')}")
    for prof in ("fast", "impl", "deep"):
        p = HOME / f"{prof}.config.toml"
        d = load_toml(p) if p.exists() else {}
        print(f"  {ok(p.exists())} профиль {prof}: {d.get('model','—')} / {d.get('model_reasoning_effort','—')}")
    cfg = load_toml(proj / ".codex" / "config.toml")
    ag = cfg.get("agents", {})
    print(f"  {ok(bool(cfg))} .codex/config.toml: root={cfg.get('model','(глобальный)')}/{cfg.get('model_reasoning_effort','—')} "
          f"subagent={ag.get('default_subagent_model','—')} depth={ag.get('max_depth','—')} hooks={cfg.get('features',{}).get('hooks',False)}")
    roles = sorted((proj / ".codex" / "agents").glob("*.toml"))
    if roles:
        print("  ✓ роли:")
        for r in roles:
            d = load_toml(r)
            print(f"      {d.get('name', r.stem):24} {d.get('model','inherit'):16} {d.get('model_reasoning_effort','—'):8} {d.get('sandbox_mode','')}")
    else:
        print("  ✗ роли .codex/agents/ не найдены")
    hj = proj / ".codex" / "hooks.json"
    hooked = hj.exists() and "context_guard.py" in hj.read_text()
    print(f"  {ok(hooked)} хук context_guard")
    agents = proj / "AGENTS.md"
    txt = agents.read_text(encoding="utf-8") if agents.exists() else ""
    print(f"  {ok(MARK_START in txt)} AGENTS.md блок ({len(txt.encode())} байт)")
    print(f"  {ok((proj / '.ai-factory').exists() or (proj / '.ai-factory.json').exists())} ai-factory")
    skill_dirs = [proj / ".agents" / "skills", proj / ".codex" / "skills"]
    aif = any((d / "aif-plan").exists() for d in skill_dirs)
    astra = any((d / "astra-orchestrator").exists() for d in skill_dirs)
    print(f"  {ok(aif)} скиллы $aif-*   {'✓' if astra else '·'} $astra-orchestrator")
    return 0


# ---------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser(prog="tsctl")
    sub = ap.add_subparsers(dest="cmd", required=True)

    m = sub.add_parser("merge-config"); m.add_argument("--project", default="."); m.add_argument("--overlay")
    m.add_argument("--keep-model", action="store_true"); m.add_argument("--dry-run", action="store_true")
    m.set_defaults(fn=cmd_merge_config)

    g = sub.add_parser("agents-md"); g.add_argument("--project", default="."); g.add_argument("--template", required=True)
    g.add_argument("--dry-run", action="store_true"); g.set_defaults(fn=cmd_agents_md)

    h = sub.add_parser("hooks"); h.add_argument("--project", default="."); h.add_argument("--guard-cmd", required=True)
    h.add_argument("--dry-run", action="store_true"); h.set_defaults(fn=cmd_hooks)


    s = sub.add_parser("status"); s.add_argument("--project", default="."); s.set_defaults(fn=cmd_status)

    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
