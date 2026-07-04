#!/usr/bin/env python3
"""Check pinned Docker image tags against registry semver tags."""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

SEMVER_RE = re.compile(r"^v?\d+(?:\.\d+){1,3}$")
IMAGE_RE = re.compile(r"^\s{4}image:\s+(.+?):\s*\{\{\s*(\w+)\s*\}\}")
SERVICE_RE = re.compile(r"^\s{2}([A-Za-z0-9_-]+):\s*$")
VAR_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*[\"']?([^\"'#\n]+)[\"']?")


@dataclass(frozen=True)
class StackImage:
    service: str
    repository: str
    version_var: str
    current_tag: str


@dataclass(frozen=True)
class ImageComparison:
    image: StackImage
    latest_tag: str | None
    status: str
    error: str = ""


def parse_version(tag: str) -> tuple[int, ...]:
    return tuple(int(part) for part in tag.lstrip("v").split("."))


def parse_vars(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        match = VAR_RE.match(line.strip())
        if match:
            values[match.group(1)] = match.group(2).strip()
    return values


def parse_stack_images(compose_template: Path, vars_file: Path) -> list[StackImage]:
    values = parse_vars(vars_file)
    images: list[StackImage] = []
    current_service: str | None = None

    for line in compose_template.read_text().splitlines():
        service_match = SERVICE_RE.match(line)
        if service_match:
            current_service = service_match.group(1)
            continue

        image_match = IMAGE_RE.match(line)
        if not image_match or current_service is None:
            continue

        repository, version_var = image_match.groups()
        current_tag = values.get(version_var)
        if current_tag is None:
            raise ValueError(f"{version_var} is used by {current_service} but is missing from {vars_file}")
        images.append(StackImage(current_service, repository, version_var, current_tag))

    return images


def latest_semver_tag(tags: Iterable[str], current_tag: str) -> str | None:
    semver_tags = {tag for tag in tags if SEMVER_RE.match(tag)}
    if not semver_tags:
        return None

    latest = max(semver_tags, key=parse_version)
    if current_tag.startswith("v") and not latest.startswith("v"):
        prefixed = f"v{latest}"
        if prefixed in semver_tags:
            return prefixed
    if not current_tag.startswith("v") and latest.startswith("v"):
        unprefixed = latest[1:]
        if unprefixed in semver_tags:
            return unprefixed
    return latest


def dockerhub_tags(repository: str, pages: int = 5) -> list[str]:
    if "/" not in repository:
        namespace, name = "library", repository
    else:
        namespace, name = repository.split("/", 1)

    url = f"https://hub.docker.com/v2/repositories/{namespace}/{name}/tags?page_size=100&ordering=last_updated"
    tags: list[str] = []
    for _ in range(pages):
        with urllib.request.urlopen(url, timeout=20) as response:
            payload = json.load(response)
        tags.extend(tag["name"] for tag in payload.get("results", []))
        url = payload.get("next")
        if not url:
            break
    return tags


def ghcr_tags(repository: str) -> list[str]:
    repo = repository.removeprefix("ghcr.io/")
    token_url = "https://ghcr.io/token?" + urllib.parse.urlencode(
        {"service": "ghcr.io", "scope": f"repository:{repo}:pull"}
    )
    with urllib.request.urlopen(token_url, timeout=20) as response:
        token = json.load(response)["token"]

    url = f"https://ghcr.io/v2/{repo}/tags/list?n=100"
    tags: list[str] = []
    for _ in range(20):
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.load(response)
            link = response.headers.get("Link")
        tags.extend(payload.get("tags", []))
        if not link:
            break
        match = re.search(r"<([^>]+)>", link)
        if not match:
            break
        next_url = match.group(1)
        url = f"https://ghcr.io{next_url}" if next_url.startswith("/") else next_url
    return tags


def registry_tags(image: StackImage) -> list[str]:
    if image.repository.startswith("ghcr.io/"):
        return ghcr_tags(image.repository)
    if "." in image.repository.split("/", 1)[0]:
        raise ValueError(f"unsupported registry for {image.repository}")
    return dockerhub_tags(image.repository)


def compare_images(
    images: Iterable[StackImage],
    tag_provider: Callable[[StackImage], list[str]] = registry_tags,
) -> list[ImageComparison]:
    rows: list[ImageComparison] = []
    for image in images:
        try:
            latest = latest_semver_tag(tag_provider(image), image.current_tag)
            if latest is None:
                rows.append(ImageComparison(image, None, "no-semver-tags"))
            elif parse_version(latest) > parse_version(image.current_tag):
                rows.append(ImageComparison(image, latest, "update"))
            else:
                rows.append(ImageComparison(image, latest, "current"))
        except Exception as exc:  # noqa: BLE001 - CLI should report every image, not abort on the first one.
            rows.append(ImageComparison(image, None, "error", str(exc)))
    return rows


def format_rows(rows: list[ImageComparison]) -> str:
    headers = ("service", "image", "current", "latest", "status")
    table: list[tuple[str, str, str, str, str]] = [headers]
    for row in rows:
        table.append(
            (
                row.image.service,
                row.image.repository,
                row.image.current_tag,
                row.latest_tag or "-",
                row.error if row.error else row.status,
            )
        )

    widths = [max(len(item[i]) for item in table) for i in range(len(headers))]
    lines = []
    for idx, item in enumerate(table):
        lines.append("  ".join(value.ljust(widths[col]) for col, value in enumerate(item)))
        if idx == 0:
            lines.append("  ".join("-" * width for width in widths))
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compose", type=Path, default=Path("compose.yaml.j2"))
    parser.add_argument("--vars", type=Path, default=Path("vars.yml"))
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    parser.add_argument("--fail-on-updates", action="store_true", help="exit 1 when newer tags exist")
    args = parser.parse_args(argv)

    rows = compare_images(parse_stack_images(args.compose, args.vars))
    if args.json:
        print(
            json.dumps(
                [
                    {
                        "service": row.image.service,
                        "image": row.image.repository,
                        "version_var": row.image.version_var,
                        "current": row.image.current_tag,
                        "latest": row.latest_tag,
                        "status": row.status,
                        "error": row.error,
                    }
                    for row in rows
                ],
                indent=2,
            )
        )
    else:
        print(format_rows(rows))

    if any(row.status == "error" for row in rows):
        return 2
    if args.fail_on_updates and any(row.status == "update" for row in rows):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
