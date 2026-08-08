#!/usr/bin/env python3
"""
gen_codemap.py — stack-agnostic, dependency-free code-map generator for software-start.

Scans a project and writes a modular CODEMAP:
  CODEMAP/index.md      (auto) areas, file counts, entrypoints, pointers to slices
  CODEMAP/<area>.md     (auto) files + best-effort extracted top-level symbols
  CODEMAP/INVARIANTS.md (hand-maintained) created from a stub ONLY if absent

It's best-effort, not a parser: the goal is a cheap, roughly-right map that beats
re-reading the tree. When it's wrong, fix INVARIANTS.md (the part that matters),
not the generated slices.

Usage:
    python gen_codemap.py --root . --out CODEMAP
"""
import argparse
import os
import re
import sys
from datetime import datetime

IGNORE_DIRS = {
    ".git", ".hg", ".svn", "node_modules", ".venv", "venv", "env",
    "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    "dist", "build", "target", "out", ".next", ".nuxt", ".svelte-kit",
    "coverage", ".nyc_output", "vendor", "bin", "obj", ".gradle",
    ".idea", ".vscode", "deps", "_build", ".terraform", ".cache",
    "CODEMAP",
}

# extension -> language label
LANGS = {
    ".js": "js", ".jsx": "js", ".mjs": "js", ".cjs": "js",
    ".ts": "ts", ".tsx": "ts",
    ".py": "py", ".go": "go", ".rs": "rs",
    ".java": "java", ".kt": "kotlin", ".kts": "kotlin",
    ".rb": "ruby", ".php": "php", ".cs": "csharp",
    ".ex": "elixir", ".exs": "elixir", ".swift": "swift",
    ".c": "c", ".h": "c", ".cpp": "cpp", ".hpp": "cpp", ".cc": "cpp",
    ".scala": "scala", ".dart": "dart", ".vue": "js", ".svelte": "js",
}

# per-language regexes for top-level symbols (best-effort)
SYMBOL_RES = {
    "js": [re.compile(r"export\s+(?:default\s+)?(?:async\s+)?(?:function|class|const|let|var|interface|type|enum)\s+([A-Za-z0-9_$]+)")],
    "ts": [re.compile(r"export\s+(?:default\s+)?(?:async\s+)?(?:function|class|const|let|var|interface|type|enum)\s+([A-Za-z0-9_$]+)")],
    "py": [re.compile(r"^(?:async\s+)?def\s+([A-Za-z0-9_]+)"), re.compile(r"^class\s+([A-Za-z0-9_]+)")],
    "go": [re.compile(r"^func\s+(?:\([^)]*\)\s*)?([A-Za-z0-9_]+)"), re.compile(r"^type\s+([A-Za-z0-9_]+)\s")],
    "rs": [re.compile(r"^\s*pub\s+(?:async\s+)?fn\s+([A-Za-z0-9_]+)"), re.compile(r"^\s*pub\s+(?:struct|enum|trait)\s+([A-Za-z0-9_]+)")],
    "java": [re.compile(r"(?:public|protected)\s+(?:final\s+|abstract\s+)?(?:class|interface|enum|record)\s+([A-Za-z0-9_]+)")],
    "kotlin": [re.compile(r"(?:^|\s)(?:class|interface|object|fun)\s+([A-Za-z0-9_]+)")],
    "ruby": [re.compile(r"^\s*(?:def|class|module)\s+([A-Za-z0-9_:?!]+)")],
    "php": [re.compile(r"^\s*(?:abstract\s+|final\s+)?(?:class|interface|trait)\s+([A-Za-z0-9_]+)"), re.compile(r"^\s*(?:public|private|protected|static|\s)*function\s+([A-Za-z0-9_]+)")],
    "csharp": [re.compile(r"(?:public|internal)\s+(?:sealed\s+|abstract\s+|static\s+)?(?:class|interface|enum|record|struct)\s+([A-Za-z0-9_]+)")],
    "elixir": [re.compile(r"^\s*def(?:module|p)?\s+([A-Za-z0-9_.?!]+)")],
}

COMMENT_PREFIXES = ("//", "#", "--", "/*", "*", '"""', "'''", ";;")
SRC_ROOTS = {"src", "app", "lib", "pkg", "cmd", "internal", "packages", "apps", "services"}
ENTRY_NAMES = {
    "main.py", "__main__.py", "manage.py", "app.py", "wsgi.py", "asgi.py",
    "index.js", "index.ts", "server.js", "server.ts", "main.js", "main.ts",
    "main.go", "main.rs", "Main.java", "Program.cs", "app.rb", "index.php",
}
MAX_BYTES = 512 * 1024      # skip huge/likely-generated files
MAX_SYMBOLS = 25            # cap symbols listed per file


def load_extra_ignores(root):
    """Add bare directory names from .gitignore to the skip set (light-touch)."""
    extra = set()
    gi = os.path.join(root, ".gitignore")
    if os.path.isfile(gi):
        try:
            for line in open(gi, encoding="utf-8", errors="ignore"):
                s = line.strip()
                if not s or s.startswith("#") or s.startswith("!"):
                    continue
                s = s.rstrip("/")
                if s and "/" not in s and "*" not in s and "." != s[0]:
                    extra.add(s)
        except OSError:
            pass
    return extra


def area_of(relpath):
    parts = relpath.replace("\\", "/").split("/")
    if len(parts) == 1:
        return "(root)"
    if parts[0] in SRC_ROOTS and len(parts) > 2:
        return f"{parts[0]}/{parts[1]}"
    return parts[0]


def first_doc_line(lines):
    for ln in lines[:15]:
        s = ln.strip()
        if not s:
            continue
        for p in COMMENT_PREFIXES:
            if s.startswith(p):
                text = s.lstrip("/#-*;\"' ").strip()
                if text:
                    return text[:100]
    return ""


def extract_symbols(lang, lines):
    res = SYMBOL_RES.get(lang)
    if not res:
        return []
    found, seen = [], set()
    for ln in lines:
        if len(ln) > 400:  # skip minified lines
            continue
        for rx in res:
            m = rx.search(ln)
            if m:
                name = m.group(1)
                if name and name not in seen:
                    seen.add(name)
                    found.append(name)
        if len(found) >= MAX_SYMBOLS:
            break
    return found


def scan(root, ignore_dirs):
    files_by_area = {}
    entrypoints = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ignore_dirs and not d.startswith(".")
                       or d in (".github",)]
        for fn in filenames:
            ext = os.path.splitext(fn)[1].lower()
            if ext not in LANGS:
                continue
            full = os.path.join(dirpath, fn)
            try:
                if os.path.getsize(full) > MAX_BYTES:
                    continue
            except OSError:
                continue
            rel = os.path.relpath(full, root).replace("\\", "/")
            if fn in ENTRY_NAMES:
                entrypoints.append(rel)
            try:
                with open(full, encoding="utf-8", errors="ignore") as fh:
                    lines = fh.read().splitlines()
            except OSError:
                continue
            lang = LANGS[ext]
            symbols = extract_symbols(lang, lines)
            summary = "" if symbols else first_doc_line(lines)
            files_by_area.setdefault(area_of(rel), []).append(
                {"path": rel, "lang": lang, "symbols": symbols, "summary": summary, "loc": len(lines)}
            )
    return files_by_area, entrypoints


def slug(area):
    return re.sub(r"[^A-Za-z0-9]+", "-", area).strip("-").lower() or "root"


def write_map(files_by_area, entrypoints, out, project, regen_cmd):
    os.makedirs(out, exist_ok=True)
    date = datetime.now().strftime("%Y-%m-%d")
    header = (f"<!-- AUTO-GENERATED by software-start gen_codemap.py — do not hand-edit.\n"
              f"     Regenerate: {regen_cmd}\n"
              f"     Durable rules go in CODEMAP/INVARIANTS.md (hand-maintained). -->\n\n")
    areas = sorted(files_by_area.keys())

    # index.md
    idx = [header, f"# CODEMAP — {project}\n",
           f"\n_Generated {date}. Read this index, then the one slice you need._\n"]
    ep = ", ".join(f"`{e}`" for e in sorted(set(entrypoints))[:12]) or "_none detected_"
    idx.append(f"\n**Entrypoints:** {ep}\n\n## Areas\n\n| Area | Files | Symbols | Slice |\n|------|-------|---------|-------|\n")
    for area in areas:
        entries = files_by_area[area]
        nsym = sum(len(e["symbols"]) for e in entries)
        idx.append(f"| `{area}` | {len(entries)} | {nsym} | [{slug(area)}.md]({slug(area)}.md) |\n")
    idx.append("\n## Hand-maintained knowledge\n\n- [INVARIANTS.md](INVARIANTS.md) — rules that must stay true, "
               "cross-module contracts, the \"why\". **Read before changing anything structural.**\n")
    with open(os.path.join(out, "index.md"), "w", encoding="utf-8") as f:
        f.write("".join(idx))

    # area slices
    for area in areas:
        entries = sorted(files_by_area[area], key=lambda e: e["path"])
        body = [header, f"# {area}\n\n_{len(entries)} source file(s)._\n\n"]
        for e in entries:
            body.append(f"### `{e['path']}`  \n_{e['lang']} · {e['loc']} loc_\n")
            if e["symbols"]:
                body.append("\n" + ", ".join(f"`{s}`" for s in e["symbols"]) + "\n\n")
            elif e["summary"]:
                body.append(f"\n{e['summary']}\n\n")
            else:
                body.append("\n")
        with open(os.path.join(out, f"{slug(area)}.md"), "w", encoding="utf-8") as f:
            f.write("".join(body))

    # INVARIANTS.md — never clobber
    inv = os.path.join(out, "INVARIANTS.md")
    if not os.path.exists(inv):
        with open(inv, "w", encoding="utf-8") as f:
            f.write(
                "# CODEMAP — Invariants (hand-maintained)\n\n"
                "_The generator never touches this file. Put here what a code scan can't see:_\n\n"
                "## Rules that must stay true\n-\n\n"
                "## Cross-module contracts\n-\n\n"
                "## State machine / legal transitions\n-\n\n"
                "## \"If you change X, also change Y\"\n-\n\n"
                "## Why (design decisions worth remembering)\n-\n"
            )
    return len(areas), sum(len(v) for v in files_by_area.values())


def main():
    ap = argparse.ArgumentParser(description="Generate a modular CODEMAP.")
    ap.add_argument("--root", default=".")
    ap.add_argument("--out", default="CODEMAP")
    ap.add_argument("--project", default=None, help="project name (defaults to root dir name)")
    ap.add_argument("--regen-cmd", default="python scripts/gen_codemap.py --root . --out CODEMAP")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    project = args.project or os.path.basename(root)
    ignore = IGNORE_DIRS | load_extra_ignores(root)

    files_by_area, entrypoints = scan(root, ignore)
    if not files_by_area:
        print("No source files found — nothing to map (is this an empty project?).", file=sys.stderr)
        return 0
    n_areas, n_files = write_map(files_by_area, entrypoints, os.path.join(root, args.out)
                                 if not os.path.isabs(args.out) else args.out,
                                 project, args.regen_cmd)
    print(f"CODEMAP written to {args.out}/ — {n_files} files across {n_areas} areas.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
