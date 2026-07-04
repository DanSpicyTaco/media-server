import importlib.util
import sys
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "check-image-updates.py"


def load_module():
    spec = importlib.util.spec_from_file_location("check_image_updates", SCRIPT_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_parse_stack_images_maps_services_to_version_vars(tmp_path):
    module = load_module()
    compose = tmp_path / "compose.yaml.j2"
    vars_file = tmp_path / "vars.yml"
    compose.write_text(
        """
services:
  traefik:
    image: traefik:{{ traefik_version }}
  seerr:
    image: ghcr.io/seerr-team/seerr:{{ seerr_version }}
""".lstrip()
    )
    vars_file.write_text(
        """
traefik_version: "v3.7.6"
seerr_version: "v3.3.0"
""".lstrip()
    )

    images = module.parse_stack_images(compose, vars_file)

    assert [(image.service, image.repository, image.current_tag) for image in images] == [
        ("traefik", "traefik", "v3.7.6"),
        ("seerr", "ghcr.io/seerr-team/seerr", "v3.3.0"),
    ]


def test_latest_semver_tag_prefers_current_prefix():
    module = load_module()

    assert module.latest_semver_tag(["3.7.6", "v3.7.7", "v3.7.6"], current_tag="v3.7.6") == "v3.7.7"
    assert module.latest_semver_tag(["5.2.1", "5.2.2", "latest"], current_tag="5.2.1") == "5.2.2"


def test_compare_images_reports_updates_without_network():
    module = load_module()
    image = module.StackImage(
        service="sonarr",
        repository="linuxserver/sonarr",
        version_var="sonarr_version",
        current_tag="4.0.17",
    )

    rows = module.compare_images([image], tag_provider=lambda img: ["4.0.17", "4.0.19"])

    assert rows[0].latest_tag == "4.0.19"
    assert rows[0].status == "update"
