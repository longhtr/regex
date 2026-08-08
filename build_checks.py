#!/usr/bin/env python3
"""Check documentation links, source layout, and dependency boundaries."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "src"


def check_links(failures):
    link_pattern = re.compile(r"\[[^]]*\]\(([^)]+)\)")
    markdown = list(ROOT.glob("*.md"))
    markdown.extend(ROOT.glob("docs/*.md"))
    markdown.extend(path for path in (
        ROOT / "examples/README.md",
    ) if path.exists())
    markdown.extend(SOURCE.rglob("README.md"))
    for path in markdown:
        for target in link_pattern.findall(path.read_text(encoding="utf-8")):
            local = target.split("#", 1)[0]
            if local and "://" not in local and not (path.parent / local).resolve().exists():
                failures.append(f"broken link: {path.relative_to(ROOT)} -> {target}")


def check_source_readmes(failures):
    directories = [SOURCE]
    directories.extend(path for path in SOURCE.rglob("*") if path.is_dir())
    for directory in sorted(directories):
        readme = directory / "README.md"
        if not readme.exists():
            failures.append(
                f"source directory lacks README: {directory.relative_to(ROOT)}"
            )
            continue
        text = readme.read_text(encoding="utf-8")
        if not text.startswith("# "):
            failures.append(
                f"source README lacks title: {readme.relative_to(ROOT)}"
            )
        for module in sorted(directory.glob("*.zig")):
            if f"]({module.name})" not in text:
                failures.append(
                    f"source README omits module: {module.relative_to(ROOT)}"
                )


def check_ci(failures):
    attributes = ROOT / ".gitattributes"
    if (
        not attributes.exists()
        or "* text=auto eol=lf"
        not in attributes.read_text(encoding="utf-8").splitlines()
    ):
        failures.append("repository does not enforce portable LF line endings")

    workflow = ROOT / ".github/workflows/ci.yml"
    if not workflow.exists():
        return
    text = workflow.read_text(encoding="utf-8")
    manifest = (ROOT / "build.zig.zon").read_text(encoding="utf-8")
    version_match = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', manifest)
    if not version_match:
        failures.append("package manifest lacks minimum_zig_version")
    else:
        ci_versions = re.findall(
            r"uses:\s*mlugg/setup-zig@[^\n]+\n\s+with:\n\s+version:\s+\"?([^\"\s]+)",
            text,
        )
        if not ci_versions or any(
            version != version_match.group(1) for version in ci_versions
        ):
            failures.append("CI Zig version differs from minimum_zig_version")

    for action, revision in re.findall(r"uses:\s*([^@\s]+)@([^\s#]+)", text):
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            failures.append(f"CI action is not pinned to a commit: {action}@{revision}")

    for required in (
        "ubuntu-24.04",
        "macos-14",
        "windows-2022",
        "ci/package_smoke.py",
        "zig build test-all",
        "zig build test-all -Drace=true",
    ):
        if required not in text:
            failures.append(f"CI qualification missing: {required}")


def check_examples(failures):
    directory = ROOT / "examples"
    files = {path.name for path in directory.glob("*.zig")}
    readme = (directory / "README.md").read_text(encoding="utf-8")
    linked = set(re.findall(r"\[[^]]*\]\(([^)]+\.zig)\)", readme))
    if files != linked:
        failures.append(f"example catalog drift: {sorted(files ^ linked)}")
    build = (ROOT / "build.zig").read_text(encoding="utf-8")
    missing = [name for name in sorted(files) if f'"{name.removesuffix(".zig")}"' not in build]
    if missing:
        failures.append(f"examples not compiled by build.zig: {missing}")
    for path in sorted(directory.glob("*.zig")):
        lines = path.read_text(encoding="utf-8").splitlines()
        if not lines or not lines[0].startswith("//! #"):
            failures.append(f"example lacks a titled module lesson: {path.name}")
        if not any(line.startswith("//! Expected output") for line in lines):
            failures.append(f"example lacks documented output: {path.name}")
        local_comments = sum(
            line.lstrip().startswith("//") and not line.startswith("//!")
            for line in lines
        )
        if local_comments < 2:
            failures.append(f"example lacks instructional code comments: {path.name}")


def check_benchmarks(failures):
    test_cases = SOURCE / "testing/test_cases.zig"
    if not test_cases.exists():
        failures.append("typed test source missing: src/testing/test_cases.zig")
    for legacy in ("data.zig", "specification.zig", "cases.zig"):
        if (SOURCE / "testing" / legacy).exists():
            failures.append(f"legacy src/testing/{legacy} remains")

    expected = {
        "adapter.zig",
        "campaign.zig",
        "workloads.zig",
    }
    directory = SOURCE / "benchmark"
    actual = {path.name for path in directory.glob("*.zig")}
    if actual != expected:
        failures.append(f"benchmark source layout drift: {sorted(actual ^ expected)}")
    if (ROOT / "benchmark").exists():
        failures.append("legacy benchmark/ directory remains")
    if not (ROOT / "benchmark.py").exists():
        failures.append("root benchmark.py is missing")
    if not (ROOT / "testing.py").exists():
        failures.append("root testing.py is missing")
    build = (ROOT / "build.zig").read_text(encoding="utf-8")
    for required in (
        "src/benchmark/adapter.zig",
        "benchmark.py",
        "testing.py",
        'b.step("benchmark"',
        'b.step("test"',
        'b.step("test-all"',
    ):
        if required not in build:
            failures.append(f"benchmark build integration missing: {required}")


def dependency_graph(failures):
    files = sorted(SOURCE.rglob("*.zig"))
    graph = {path: [] for path in files}
    import_pattern = re.compile(r'@import\("([^"\n]+\.zig)"\)')
    allowed_targets = {
        "syntax": {"syntax", "unicode"},
        "literal": {"literal", "program", "syntax", "unicode"},
        "program": {"program", "optimize", "support", "syntax", "unicode"},
        "optimize": {"engine", "literal", "optimize", "program", "support", "syntax", "unicode"},
        "engine": {"engine", "literal", "optimize", "program", "root", "support", "syntax", "unicode"},
    }

    for path in files:
        relative = path.relative_to(SOURCE)
        production = (
            relative.parts[0] not in ("testing", "tools", "benchmark")
            and relative.name not in ("test_root.zig", "tool_main.zig")
        )
        text = path.read_text(encoding="utf-8")
        if production and not text.startswith("//!"):
            failures.append(f"missing module comment: src/{relative}")
        if production and re.search(r"\b[A-Za-z0-9_]+Api\b", text):
            failures.append(f"source-level Api alias: src/{relative}")
        if re.search(r"\b[A-Za-z0-9_]+_mod\b", text):
            failures.append(f"abbreviated module alias: src/{relative}")

        for imported in import_pattern.findall(text):
            target = (path.parent / imported).resolve()
            if target not in graph:
                continue
            graph[path].append(target)
            target_relative = target.relative_to(SOURCE)
            source_group = relative.parts[0] if len(relative.parts) > 1 else "root"
            target_group = (
                target_relative.parts[0]
                if len(target_relative.parts) > 1
                else "root"
            )
            if production and target_group in ("testing", "tools", "benchmark"):
                failures.append(
                    f"production imports {target_relative}: src/{relative}"
                )
            if relative.parts[0] == "engine" and imported.startswith("../engine/"):
                failures.append(
                    f"redundant engine import path in src/{relative}: {imported}"
                )
            if (
                source_group in allowed_targets
                and target_group not in allowed_targets[source_group]
            ):
                failures.append(
                    f"layer violation: src/{relative} imports src/{target_relative}"
                )
    return files, graph


def reachable(graph, start):
    found = set()
    pending = list(graph[start])
    while pending:
        path = pending.pop()
        if path in found:
            continue
        found.add(path)
        pending.extend(graph[path])
    return found


def check_engine_boundaries(files, graph, failures):
    accelerators = {
        path
        for path in files
        if path.relative_to(SOURCE).parts[:2] == ("engine", "accelerate")
    }
    complete_engines = {
        SOURCE / "engine/nfa.zig",
        SOURCE / "engine/capture_nfa.zig",
    }
    for complete in complete_engines:
        dependency = next(iter(reachable(graph, complete) & accelerators), None)
        if dependency is not None:
            failures.append(
                f"complete engine reaches accelerator {dependency.relative_to(SOURCE)}: "
                f"src/{complete.relative_to(SOURCE)}"
            )
    for accelerator in accelerators:
        dependency = next(iter(reachable(graph, accelerator) & complete_engines), None)
        if dependency is not None:
            failures.append(
                f"accelerator reaches complete engine {dependency.relative_to(SOURCE)}: "
                f"src/{accelerator.relative_to(SOURCE)}"
            )

    required_fallbacks = {
        "matcher.zig": "engine/nfa.zig",
        "execute/capture.zig": "engine/capture_nfa.zig",
        "collection/set.zig": "engine/nfa.zig",
        "collection/filtered.zig": "regex.zig",
    }
    for owner_relative, fallback_relative in required_fallbacks.items():
        owner = SOURCE / owner_relative
        fallback = SOURCE / fallback_relative
        if fallback not in graph[owner]:
            failures.append(
                f"semantic fallback missing: src/{owner_relative} -> "
                f"src/{fallback_relative}"
            )


def check_cycles(files, graph, failures):
    visiting = set()
    visited = set()
    stack = []

    def visit(path):
        if path in visiting:
            cycle_start = stack.index(path)
            cycle = stack[cycle_start:] + [path]
            failures.append(
                "import cycle: "
                + " -> ".join(str(item.relative_to(SOURCE)) for item in cycle)
            )
            return
        if path in visited:
            return
        visiting.add(path)
        stack.append(path)
        for target in graph[path]:
            visit(target)
        stack.pop()
        visiting.remove(path)
        visited.add(path)

    for path in files:
        visit(path)


def check_public_boundary(graph, failures):
    allowed_top = {
        "compiled.zig",
        "internal.zig",
        "match.zig",
        "matcher.zig",
        "regex.zig",
        "rewrite.zig",
        "root.zig",
        "test_root.zig",
        "tool_main.zig",
    }
    actual_top = {path.name for path in SOURCE.glob("*.zig")}
    if actual_top != allowed_top:
        failures.append(f"unexpected src/ files: {sorted(actual_top ^ allowed_top)}")
    root_text = (SOURCE / "root.zig").read_text(encoding="utf-8")
    exports = set(re.findall(r"^pub const (\w+)", root_text, re.MULTILINE))
    expected_exports = {
        "Regex",
        "Matcher",
        "Match",
        "SearchRange",
        "MatchKind",
        "Anchor",
        "CaptureView",
        "Captures",
        "Matches",
        "CompileOptions",
        "MatcherOptions",
        "Encoding",
        "Semantics",
        "Diagnostic",
        "Rewrite",
        "Set",
        "Filtered",
        "quoteMeta",
        "quoteMetaWithLimit",
    }
    if exports != expected_exports:
        failures.append(f"public API drift: {sorted(exports ^ expected_exports)}")

    if graph[SOURCE / "match.zig"]:
        failures.append("match.zig must not import another project module")
    match_text = (SOURCE / "match.zig").read_text(encoding="utf-8")
    semantic_types = (
        "Match",
        "CaptureView",
        "Captures",
        "SearchRange",
        "PossibleMatchRange",
        "PossibleMatchResult",
    )
    for semantic_type in semantic_types:
        if not re.search(rf"^pub const {semantic_type}\b", match_text, re.MULTILINE):
            failures.append(
                f"representation-independent type left match.zig: {semantic_type}"
            )
    regex_text = (SOURCE / "regex.zig").read_text(encoding="utf-8")
    if re.search(r"capture_nfa\.(CaptureView|Captures)", regex_text):
        failures.append("regex.zig exposes capture types through a concrete executor")


def main():
    failures = []
    check_links(failures)
    check_source_readmes(failures)
    check_ci(failures)
    check_examples(failures)
    check_benchmarks(failures)
    files, graph = dependency_graph(failures)
    check_engine_boundaries(files, graph, failures)
    check_cycles(files, graph, failures)
    check_public_boundary(graph, failures)
    if failures:
        raise RuntimeError("repository checks failed:\n" + "\n".join(failures))


if __name__ == "__main__":
    main()
