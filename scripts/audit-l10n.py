#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""文案审计：保证界面上永远不会出现裸 key（否则会显示 devices.mount 这类内部标识）。

用法：
    python3 scripts/audit-l10n.py              # 审计，有问题退出码非 0
    python3 scripts/audit-l10n.py --verbose    # 同时列出未被引用的条目
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT_DIR = os.path.join(REPO_ROOT, "swift")
LOCALES_DIR = os.path.join(SWIFT_DIR, "Sources", "NTFSMountCore", "Resources", "locales")
SOURCES_DIR = os.path.join(SWIFT_DIR, "Sources")

LANGUAGES = ["en", "zh-CN", "zh-TW", "ja", "de"]

# 动态 key 家族：源码里用插值/循环拼出的 key，静态扫描看不到，
# 但界面上同样必须命中，这里显式列出，避免审计出现盲区。
DYNAMIC_FAMILIES = [
    # (前缀模板, 序号范围或枚举取值来源说明)
    ("tabs.{value}", ["dependencies", "devices", "logs", "help"]),
    ("devices.{value}", ["mount", "unmount", "eject", "restoreReadOnly", "reset"]),
    ("help.about.{n}", range(1, 4)),
    ("help.trouble.{n}", range(1, 5)),
    ("help.quickStart.{n}", range(1, 4)),
]

# 标题分组：这些前缀下必须有 <key>._title
TITLE_GROUPS = [
    "help.quickStart",
    "help.macPorts",
    "help.about",
]


def flatten(node, prefix=""):
    out = {}
    for key, value in node.items():
        full = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            out.update(flatten(value, full))
        elif isinstance(value, str):
            out[full] = value
    return out


def load_packs():
    packs = {}
    for lang in LANGUAGES:
        path = os.path.join(LOCALES_DIR, f"{lang}.json")
        if not os.path.exists(path):
            raise SystemExit(f"✗ 语言包缺失：{path}")
        with open(path, encoding="utf-8") as handle:
            packs[lang] = flatten(json.load(handle))
    return packs


def scan_source_keys():
    """扫出源码中真正会发起的查表请求。

    只认 `t("…")` / `title("…")` 调用点，而非「所有像 key 的字符串字面量」——
    后者会把 SF Symbol 名、文件名一并卷进来制造误报，它们不会走查表逻辑。
    """
    lookup = re.compile(r'\b(?:t|title)\(\s*"((?:[^"\\]|\\.)*)"')
    found = collections.defaultdict(set)

    for root, _dirs, files in os.walk(SOURCES_DIR):
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(root, name)
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            for match in lookup.finditer(text):
                value = match.group(1)
                if "\\(" in value or not value:
                    continue
                found[value].add(name)
    return found


def expand_dynamic():
    keys = set()
    for template, values in DYNAMIC_FAMILIES:
        for value in values:
            keys.add(template.replace("{value}", str(value)).replace("{n}", str(value)))
    return keys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--verbose", action="store_true", help="列出未被引用的条目")
    args = parser.parse_args()

    packs = load_packs()
    en = packs["en"]
    used = scan_source_keys()
    dynamic = expand_dynamic()

    problems = []

    # --- 1. 源码引用的 key 必须存在 ---
    referenced = set(used) | dynamic
    missing_in_en = sorted(k for k in referenced if k not in en and f"{k}._title" not in en)
    for key in missing_in_en:
        problems.append(f"源码引用但 en.json 里没有：{key}  ← {sorted(used.get(key, []))}")

    # --- 2. 每个 key 在全部语言里都要有 ---
    per_lang_missing = collections.defaultdict(list)
    for lang, table in packs.items():
        for key in sorted(en):
            if key not in table:
                per_lang_missing[lang].append(key)
    for lang, keys in sorted(per_lang_missing.items()):
        problems.append(f"{lang}.json 缺少 {len(keys)} 条：{keys[:8]}{' …' if len(keys) > 8 else ''}")

    # --- 3. 空值 / 占位残留 ---
    for lang, table in packs.items():
        for key, value in table.items():
            if not value.strip():
                problems.append(f"{lang}.json 的 {key} 是空字符串")
            elif value.strip() in {"TODO", "TBD", "待翻译", "XXX"}:
                problems.append(f"{lang}.json 的 {key} 仍是占位符：{value!r}")

    # --- 4. 分组标题 ---
    for group in TITLE_GROUPS:
        for lang, table in packs.items():
            if f"{group}._title" not in table:
                problems.append(f"{lang}.json 缺少分组标题 {group}._title")

    # --- 报告 ---
    print(f"语言包：{LOCALES_DIR}")
    print(f"  英文条目 {len(en)} 条 · 源码引用 {len(referenced)} 条"
          f"（含动态拼装 {len(dynamic)} 条）")
    for lang in LANGUAGES:
        print(f"  {lang:<6} {len(packs[lang])} 条")

    if args.verbose:
        unused = sorted(k for k in en
                        if not k.endswith("._title")
                        and not any(k == u or k.startswith(u + ".")
                                    or u.startswith(k + ".") for u in referenced))
        groups = collections.defaultdict(list)
        for key in unused:
            groups[key.split(".")[0]].append(key)
        print(f"\n未被源码引用（{len(unused)} 条，可在后续接线时使用）：")
        for name in sorted(groups):
            print(f"  {name:<14} {len(groups[name]):>3} 条  例：{groups[name][0]}")

    if problems:
        print(f"\n✗ 发现 {len(problems)} 个问题：")
        for item in problems:
            print(f"    {item}")
        return 1

    print("\n✓ 文案审计通过：无缺失、无空值、无裸 key 风险")
    return 0


if __name__ == "__main__":
    sys.exit(main())
