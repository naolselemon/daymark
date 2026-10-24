#!/usr/bin/env python3
"""Read-only Omarchy theme projection and explicit-profile native Qt launcher."""

import argparse
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
QT_PACKAGES = ("Qt6Core", "Qt6Gui", "Qt6Qml", "Qt6Quick")
OMARCHY = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"))


def load_toml(path):
    with path.open("rb") as stream:
        return tomllib.load(stream)


def theme_sources(name="current"):
    directory = (Path.home() / ".local/state/omarchy/current/theme" if name == "current"
                 else OMARCHY / "themes" / name)
    paths = [directory / "colors.toml", directory / "shell.toml"]
    if name == "current":
        paths.append(Path.home() / ".config/omarchy/shell.toml")
    else:
        paths.append(OMARCHY / "default/themed/shell.toml.tpl")
    return paths


def source_versions(paths):
    versions = []
    for path in paths:
        try:
            stat = path.stat()
            versions.append((stat.st_dev, stat.st_ino, stat.st_size,
                             stat.st_mtime_ns, stat.st_ctime_ns))
        except FileNotFoundError:
            versions.append(None)
    return versions


def theme_snapshot(name="current", scale=1.0):
    """Project the observed flat-control subset, not the host's Commons runtime.

    Formula sources: installed Commons/Style.qml and Color.qml. Keep this adapter
    preview-only; final shell surfaces must bind to Commons and Ui directly.
    """
    current = name == "current"
    paths = theme_sources(name)
    versions = source_versions(paths)
    colors = load_toml(paths[0])
    shell_path = paths[1]
    shell = load_toml(shell_path if current or shell_path.exists()
                      else OMARCHY / "default/themed/shell.toml.tpl")
    if not shell:
        raise ValueError("The theme shell.toml is empty; waiting for a complete theme.")
    if current:
        override = Path.home() / ".config/omarchy/shell.toml"
        if override.exists():
            for section, values in load_toml(override).items():
                shell.setdefault(section, {}).update(values)

    palette = {"background": colors.get("background", colors.get("color0")),
               "foreground": colors.get("foreground", colors.get("color7")),
               "accent": colors.get("accent", colors.get("color4")),
               "urgent": colors.get("red", colors.get("color1")),
               "muted": colors.get("muted", colors.get("color8"))}

    def color(value):
        value = str(value).strip()
        template = re.fullmatch(r"\{\{\s*(\w+)\s*\}\}", value)
        if template:
            value = colors[template[1]]
        value = palette.get(value, value)
        if value is None:
            raise ValueError("The theme palette is incomplete.")
        if value == "transparent":
            return "#00000000"
        match = re.fullmatch(r"(?:#|rgba?\()([a-fA-F0-9]{3}|[a-fA-F0-9]{6}|[a-fA-F0-9]{8})\)?", value)
        if not match:
            raise ValueError(f"Preview supports flat control colors, not {value!r}; use the installed current/stock theme contract.")
        raw = match[1]
        if len(raw) == 3:
            raw = "".join(c * 2 for c in raw)
        return "#" + (raw[6:] + raw[:6] if len(raw) == 8 else "ff" + raw)

    def alpha(value, opacity):
        resolved = color(value)
        if not math.isfinite(float(opacity)):
            raise ValueError("Control opacity must be finite.")
        opacity = max(0.0, min(1.0, float(opacity)))
        return f"#{math.floor(int(resolved[1:3], 16) * opacity + 0.5):02x}" + resolved[3:]

    controls = shell.get("controls", {})
    defaults = {"normal": (0.04, 0.4, 1), "hover-cursor": (0.08, 0.25, 1),
                "focus": (0.08, 0.25, 1), "selected": (0.18, 1.0, 0),
                "pressed": (0.22, 0.25, 1), "selection": (0.35, 0.0, 0)}
    states = {}
    for state, (fill_alpha, border_alpha, border_width) in defaults.items():
        inherited = "hover-cursor" if state in ("pressed", "focus") else "normal"
        base = controls.get(state + "-color", controls.get(inherited + "-color", "foreground"))
        if base in ("hover", "hover-cursor", "inherit"):
            base = controls.get("hover-cursor-color", "foreground")
        width = controls.get(state + "-border-width", border_width)
        if not isinstance(width, (int, float)) or any(key.startswith(state + "-border-width-") for key in controls):
            raise ValueError("The isolated preview supports uniform control borders only; host border rendering is not substituted.")
        states[state] = {"fill": alpha(base, controls.get(state + "-fill-alpha", fill_alpha)),
                         "border": alpha(controls.get(state + "-border", base), controls.get(state + "-border-alpha", border_alpha)),
                         "width": width}

    font = shell.get("font", {})
    base = max(1, float(font.get("base-size", 12))) * scale
    sizes = {key: max(1, math.floor(float(font.get(key, base * mult)) + 0.5))
             for key, mult in {"caption": .833, "body-small": .917, "body": 1,
                               "subtitle": 1.083, "title": 1.167, "heading": 1.333,
                               "display": 2, "display-large": 2.333}.items()}
    spacing = shell.get("spacing", {})
    effective_scale = float(spacing.get("scale", 1)) * (base / 12 if spacing.get("scale-with-font", True) else scale)
    spaces = {key: max(1, math.floor(float(spacing.get(key, value * effective_scale)) + .5))
              for key, value in {"control-gap": 8, "control-padding-x": 10,
                                 "control-padding-y": 6, "input-padding-y": 7,
                                 "control-height": 28, "panel-padding": 18}.items()}
    radius = 0
    if current:
        result = subprocess.run(["hyprctl", "-j", "getoption", "decoration:rounding"],
                                capture_output=True, text=True, check=True, timeout=2)
        radius = json.loads(result.stdout)["int"]
    popups = shell.get("popups", {})
    snapshot = {"name": name, "background": color(popups.get("background", "background")),
            "foreground": color(popups.get("text", "foreground")),
            "accent": color("accent"), "urgent": color("urgent"),
            "states": states, "font": sizes, "spacing": spaces,
            "scale": effective_scale, "family": "monospace", "radius": radius}
    if versions != source_versions(paths):
        raise ValueError("Theme files changed while reading; retaining the last complete theme.")
    return snapshot


def build_native(output_dir) -> Path:
    """Build the development host into a caller-owned temporary directory."""
    output = Path(output_dir).resolve()
    if output.is_relative_to(ROOT):
        raise ValueError("Native build output must be outside the source tree.")
    compiler = shutil.which("c++")
    pkg_config = shutil.which("pkg-config")
    if not compiler or not pkg_config:
        raise ValueError("The installed c++ compiler and pkg-config are required; nothing will be installed.")
    flags = shlex.split(subprocess.check_output(
        [pkg_config, "--cflags", "--libs", *QT_PACKAGES], text=True))
    libexec = Path(subprocess.check_output(
        [pkg_config, "--variable=libexecdir", "Qt6Core"], text=True).strip())
    moc = libexec / "moc"
    if not moc.is_file():
        raise ValueError("The installed Qt 6 moc executable is unavailable.")
    output.mkdir(parents=True, exist_ok=True)
    source = ROOT / "tools/native_host.cpp"
    subprocess.run([str(moc), str(source), "-o", str(output / "native_host.moc")], check=True)
    executable = output / "native_host"
    subprocess.run([compiler, "-std=c++17", "-O2", "-fPIC", str(source),
                    "-I", str(output), *flags, "-o", str(executable)], check=True)
    return executable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--theme", choices=["current", "catppuccin", "catppuccin-latte"], default="current")
    parser.add_argument("--scale", type=float, default=1.0, help="Local preview font/spacing multiplier (0.75–2)")
    parser.add_argument("--snapshot", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--size", default="1040x700", help="Requested logical window size, e.g. 700x600")
    parser.add_argument("--scenario", choices=["timer", "today", "plan", "history", "detail", "long", "empty", "empty-history", "composer", "keyboard"], default="timer")
    parser.add_argument("--capture", type=Path, help="Capture only the native prototype item tree, then close")
    profiles = parser.add_mutually_exclusive_group()
    profiles.add_argument("--profile", type=Path, help="Explicit absolute persistent profile outside the source tree")
    profiles.add_argument("--temporary", action="store_true", help="Fresh empty temporary profile, deleted on exit")
    profiles.add_argument("--demo", action="store_true", help="Fresh synthetic demo profile, deleted on exit")
    parser.add_argument("--read-only", action="store_true", help="Open SQLite in genuine read-only mode")
    args = parser.parse_args()
    match = re.fullmatch(r"(\d+)x(\d+)", args.size)
    if not match or int(match[1]) < 560 or int(match[2]) < 480:
        parser.error("Use WIDTHxHEIGHT, at least 560x480 logical pixels.")
    if not math.isfinite(args.scale) or not .75 <= args.scale <= 2:
        parser.error("--scale must be between 0.75 and 2.")
    if args.snapshot:
        try:
            print(json.dumps(theme_snapshot(args.theme, args.scale), allow_nan=False))
            return 0
        except (OSError, ValueError, KeyError, TypeError, AttributeError,
                OverflowError, subprocess.SubprocessError) as error:
            print(f"Theme projection failed: {error}", file=sys.stderr)
            return 1
    if not (args.profile or args.temporary or args.demo):
        parser.error("Select --profile, --temporary or --demo.")
    if args.profile:
        if not args.profile.is_absolute():
            parser.error("--profile must be an absolute directory path.")
        args.profile = args.profile.resolve()
        if args.profile.is_relative_to(ROOT):
            parser.error("Profiles must be outside the source tree.")
        if args.profile.exists() and not args.profile.is_dir():
            parser.error("--profile must name a directory.")
    if args.capture and args.profile:
        parser.error("Captures require --demo or --temporary; existing profiles may contain personal data.")
    if args.scenario in ("empty", "empty-history") and args.profile:
        parser.error("Empty scenarios require --demo or --temporary and never reset an existing profile.")
    try:
        snapshot = theme_snapshot(args.theme, args.scale)
        capture = str(args.capture.resolve()) if args.capture else ""
        if capture and not Path(capture).parent.is_dir():
            parser.error("The capture directory must already exist.")
        with tempfile.TemporaryDirectory(prefix="daylog-preview-", dir="/tmp") as directory:
            temporary = Path(directory)
            profile = args.profile or temporary / "profile"
            if args.demo and args.scenario not in ("empty", "empty-history"):
                # Fixtures are never imported by the persistent-profile path.
                from seed_demo import seed
                seed(profile)
            mode = "Synthetic demo · temporary" if args.demo else (
                "Empty temporary profile" if args.temporary else "Explicit persistent profile")
            if args.read_only:
                mode += " · read-only"
            executable = build_native(temporary / "build")
            launcher = temporary / "Launch.qml"
            launcher.write_text(
                f'import {json.dumps((ROOT / "prototype").as_uri())} as Daymark\n'
                'Daymark.Preview {\n'
                f'    themeData: {json.dumps(snapshot)}\n'
                f'    width: {match[1]}; height: {match[2]}\n'
                f'    scenario: {json.dumps(args.scenario)}\n'
                f'    capturePath: {json.dumps(capture)}\n'
                f'    profileLabel: {json.dumps(mode)}\n'
                f'    demoMode: {json.dumps(args.demo)}\n'
                f'    temporaryProfile: {json.dumps(args.profile is None)}\n'
                '}\n', encoding="utf-8")
            environment = dict(os.environ, QML_DISABLE_DISK_CACHE="1", QT_FORCE_STDERR_LOGGING="1",
                               XDG_CACHE_HOME=str(temporary / "cache"))
            print(f"Daymark M5 · {args.theme} tokens · {mode}", flush=True)
            command = [str(executable), str(launcher), sys.executable,
                       str(ROOT / "backend/helper.py"), str(profile)]
            if args.read_only:
                command.append("--read-only")
            if args.theme == "current":
                command.extend(["--theme-script", str(Path(__file__).resolve()),
                                "--theme-scale", str(args.scale)])
                for path in theme_sources():
                    command.extend(["--theme-watch", str(path)])
            return subprocess.run(command, env=environment, check=False).returncode
    except (OSError, ValueError, KeyError, TypeError, AttributeError,
            OverflowError, subprocess.SubprocessError) as error:
        print(f"Preview could not start: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
