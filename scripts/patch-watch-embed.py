#!/usr/bin/env python3
"""Keep the watch app in Contents/Watch.

XcodeGen 2.46.0 (the version CI installs) emits an "Embed Watch Content"
phase with dstSubfolderSpec 16 and dstPath $(CONTENTS_FOLDER_PATH)/Watch
when the iOS target depends on the watch app with embed: true. App Store
Connect rejects a watch app under PlugIns (error 90680). This script
rewrites that phase back to Watch if a generator or an older patch pointed
it at PlugIns, then checks an .app bundle the same way.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "WatchRemote.xcodeproj" / "project.pbxproj"
PHASE_NAME = 'name = "Embed Watch Content";'
WATCH_PATH = 'dstPath = "$(CONTENTS_FOLDER_PATH)/Watch";'
WATCH_SPEC = "dstSubfolderSpec = 16;"
PLUGINS_PATH = 'dstPath = "";'
PLUGINS_SPEC = "dstSubfolderSpec = 13;"
WATCH_APP = "WatchRemoteWatch.app"


def phase_span(text: str) -> tuple[int, int]:
    index = text.find(PHASE_NAME)
    if index < 0:
        raise SystemExit('Missing the "Embed Watch Content" copy phase.')
    start = text.rfind("{", 0, index)
    end = text.find("};", index)
    if start < 0 or end < 0:
        raise SystemExit("Could not read the Embed Watch Content phase.")
    return start, end + 2


def enforce_phase(text: str) -> str:
    start, end = phase_span(text)
    block = text[start:end]
    if WATCH_PATH in block and WATCH_SPEC in block and PLUGINS_SPEC not in block:
        return text
    if PLUGINS_PATH not in block or PLUGINS_SPEC not in block:
        raise SystemExit(
            "Embed Watch Content must use "
            'dstPath = "$(CONTENTS_FOLDER_PATH)/Watch" and dstSubfolderSpec = 16.'
        )
    block = block.replace(PLUGINS_PATH, WATCH_PATH, 1)
    block = block.replace(PLUGINS_SPEC, WATCH_SPEC, 1)
    updated = text[:start] + block + text[end:]
    start, end = phase_span(updated)
    block = updated[start:end]
    if WATCH_PATH not in block or WATCH_SPEC not in block or PLUGINS_SPEC in block:
        raise SystemExit("Failed to point Embed Watch Content at Contents/Watch.")
    return updated


def assert_archived_app(app: Path, watch_name: str = WATCH_APP) -> None:
    if not app.is_dir():
        raise SystemExit(f"App bundle does not exist: {app}")
    watch = app / "Watch" / watch_name
    if not watch.is_dir():
        nested = sorted(path.relative_to(app).as_posix() for path in app.rglob("*.app"))
        found = ", ".join(nested) if nested else "no nested apps"
        raise SystemExit(f"Expected Watch/{watch_name} in {app}. Found: {found}")
    plugins = app / "PlugIns"
    if plugins.is_dir():
        extra = sorted(path.name for path in plugins.glob("*.app"))
        if extra:
            raise SystemExit(
                "PlugIns must not contain the watch app. Found: " + ", ".join(extra)
            )


def _expect_failure(action) -> None:
    try:
        action()
    except SystemExit:
        return
    raise SystemExit("self-test expected a failure")


def self_test() -> None:
    watch_phase = """
\t\tABCDEF /* Embed Watch Content */ = {
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tdstPath = "$(CONTENTS_FOLDER_PATH)/Watch";
\t\t\tdstSubfolderSpec = 16;
\t\t\tname = "Embed Watch Content";
\t\t};
"""
    if enforce_phase(watch_phase) != watch_phase:
        raise SystemExit("self-test rewrote a Watch embed phase")
    plugins_phase = watch_phase.replace(WATCH_PATH, PLUGINS_PATH).replace(WATCH_SPEC, PLUGINS_SPEC)
    enforced = enforce_phase(plugins_phase)
    if WATCH_PATH not in enforced or WATCH_SPEC not in enforced or PLUGINS_SPEC in enforced:
        raise SystemExit("self-test did not restore the Watch embed phase")
    other = """
\t\tname = "Embed Foundation Extensions";
\t\tdstPath = "";
\t\tdstSubfolderSpec = 13;
"""
    _expect_failure(lambda: enforce_phase(other + watch_phase.replace(PHASE_NAME, 'name = "Other";')))

    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        good = root / "WatchRemote.app"
        (good / "Watch" / "WatchRemoteWatch.app").mkdir(parents=True)
        (good / "PlugIns").mkdir()
        assert_archived_app(good)
        bad = root / "Bad.app"
        (bad / "PlugIns" / "WatchRemoteWatch.app").mkdir(parents=True)
        _expect_failure(lambda: assert_archived_app(bad))
        both = root / "Both.app"
        (both / "Watch" / "WatchRemoteWatch.app").mkdir(parents=True)
        (both / "PlugIns" / "WatchRemoteWatch.app").mkdir(parents=True)
        _expect_failure(lambda: assert_archived_app(both))
    print("patch-watch-embed self-test ok")


def main() -> None:
    if "--self-test" in sys.argv:
        self_test()
        return
    if "--check-app" in sys.argv:
        index = sys.argv.index("--check-app")
        if index + 1 >= len(sys.argv):
            raise SystemExit("Usage: patch-watch-embed.py --check-app path/to/App.app")
        app = Path(sys.argv[index + 1])
        assert_archived_app(app)
        print(f"Watch embed ok: {app / 'Watch' / WATCH_APP}")
        return
    if not PROJECT.is_file():
        raise SystemExit(f"Missing {PROJECT}. Run xcodegen generate first.")
    original = PROJECT.read_text()
    updated = enforce_phase(original)
    if updated != original:
        PROJECT.write_text(updated)
        print(f"Pointed Embed Watch Content at Contents/Watch in {PROJECT}")
    else:
        print(f"Embed Watch Content already targets Contents/Watch in {PROJECT}")


if __name__ == "__main__":
    main()
