#!/usr/bin/env python3

from __future__ import annotations

import argparse
import pathlib
import re
import tomllib


def format_source(source: str | None) -> str:
    if not source:
        return "local"
    if source.startswith("registry+"):
        return "crates.io"
    if source.startswith("git+"):
        match = re.search(r"#([0-9a-fA-F]{7,40})$", source)
        if match:
            return f"git ({match.group(1)})"
        return "git"
    return source


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target-ref", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    repo_root = pathlib.Path(args.repo_root).resolve()
    cargo_toml_path = repo_root / "rust" / "Cargo.toml"
    cargo_lock_path = repo_root / "rust" / "Cargo.lock"

    cargo_toml = tomllib.loads(cargo_toml_path.read_text())
    cargo_lock = tomllib.loads(cargo_lock_path.read_text())

    direct_dependency_names = sorted(cargo_toml["dependencies"].keys())
    locked_packages = cargo_lock["package"]
    locked_packages_by_name = {package["name"]: package for package in locked_packages}

    lines = [
        f"Prebuilt HFAPI Rust artifactbundle for {args.target_ref}.",
        "",
        f"Artifact version: `{args.version}`",
        "",
        "## Direct Rust dependencies",
    ]

    for name in direct_dependency_names:
        package = locked_packages_by_name[name]
        version = package["version"]
        source = format_source(package.get("source"))
        lines.append(f"- `{name}` {version} ({source})")

    lines.extend(
        [
            "",
            f"## Full locked Rust dependency graph ({len(locked_packages)} packages)",
        ]
    )

    for package in sorted(locked_packages, key=lambda package: (package["name"], package["version"])):
        name = package["name"]
        version = package["version"]
        source = format_source(package.get("source"))
        lines.append(f"- `{name}` {version} ({source})")

    pathlib.Path(args.output).write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
