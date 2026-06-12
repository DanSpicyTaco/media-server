# Media Server

This project deploys a self-hosted media server on a VPS using Ansible for bootstrap and Docker Compose for the stack.

**Stack:** Traefik, Jellyfin, Seerr, Radarr, Sonarr, Prowlarr, qBittorrent

> **WARNING** I do not condone the use of this technology for downloading illegal or copyrighted content. This is purely for fun and not for doing anything illegal.

## Architecture

```
Users → Traefik (HTTPS)
          ├── Seerr      (https://your-domain)
          └── Jellyfin   (https://jellyfin.your-domain)

Internal (media-network):
  Seerr → Jellyfin, Radarr, Sonarr
  Prowlarr → Radarr, Sonarr
  Radarr/Sonarr → qBittorrent → /content/torrents
  Radarr/Sonarr/Jellyfin → /content/media
```

Ansible handles VPS bootstrap (Docker, firewall, directories, config templating). Docker Compose runs all services from a single [`compose.yaml.j2`](compose.yaml.j2). A one-shot [`scripts/init-services.sh`](scripts/init-services.sh) configures Jellyfin libraries, *arr apps, and Seerr via their APIs.

## Prerequisites

- A VPS with a non-root user and SSH access
- [Ansible](https://docs.ansible.com/ansible/latest/index.html) on your local machine
- DNS A records for `your-domain` and `jellyfin.your-domain` pointing at the VPS

Install the required Ansible collection:

```zsh
ansible-galaxy collection install -r requirements.yml
```

## Deployment

Copy the example inventory and fill in your values:

```zsh
cp inventory.example.ini inventory.ini
```

```ini
[media]
<ip_address>

[media:vars]
ansible_user=<user>
ansible_ssh_private_key_file=<private_key>

# Server
server_domain=<server_domain>
admin_email=<admin_email>
server_name=<server_name>
frontend_title=<name_in_website>
timezone=<your_timezone>

# Optional — see .env.example. Passwords and *arr API keys are auto-generated
# when omitted; set them here to choose your own.
# qbittorrent_password=<XXXX>
# jellyfin_password=<XXXX>
```

The passwords and *arr API keys are optional: when omitted they are
auto-generated and stored in `.credentials/` next to your inventory
(gitignored), so re-runs reuse the same values. Seerr has no separate login —
it reuses the Jellyfin username/password. If your VPS uses a non-standard SSH
port, set
`ssh_port` in the inventory **before** the first run — the firewall only
allows the configured port.

> **Note:** Deployment assumes a VPS with a non-root user. Running everything as root creates security issues.

Run the playbook:

```zsh
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml
```

### Partial runs (tags)

```zsh
# Bootstrap only (Docker, firewall, directories, config)
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml --tags setup

# Start/restart containers
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml --tags compose

# Re-run API initialisation (idempotent)
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml --tags init
```

### Updates

On the server, after the initial deploy:

```zsh
cd ~/{{ server_name }}
docker compose pull
docker compose up -d
```

## Prowlarr

Prowlarr is not pre-configured with indexers. After deploy, set up SSH port forwarding to Prowlarr and add indexers manually:

```zsh
ssh -L 9696:127.0.0.1:9696 <user>@<ip_address>
```

Open `http://localhost:9696`, go to **Indexers → Add Indexer**, and add a few public indexers.

## Customisation

Override defaults in [`vars.yml`](vars.yml) (ports, paths, usernames, pinned image versions). Secrets belong in `inventory.ini`, not in the repo.

## Streaming profiles

The init script enforces a **streaming profile** in Radarr and Sonarr — a named
set of release rules that keeps grabs playable on your target client without
server-side transcoding (important on a low-power VPS with no GPU). Each profile
is a list of "blocked" custom formats scored `-10000`, so matching releases are
never grabbed.

Select one with `streaming_profile` in `inventory.ini` (default
`chromecast-2018`):

| Profile | Effect |
| --- | --- |
| `chromecast-2018` | H.264, ≤1080p, progressive only — blocks HEVC, DTS/TrueHD, 4K, and interlaced/raw (`1080i`/`Raw-HD`) captures so a 2018 Chromecast direct-plays everything. |
| `none` | No restrictions. Lifts any blocks a previous profile applied. |

Profiles are defined under `streamingProfiles` in
[`config/init/radarr.json.j2`](config/init/radarr.json.j2) and
[`config/init/sonarr.json.j2`](config/init/sonarr.json.j2) — add a key there to
define your own. The init step is a reconciler: changing the profile and
re-running propagates the switch (including removing old blocks).

```zsh
# Switch profile after editing inventory.ini
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml --tags config,init
```

> Matching is by release title (except 4K, which uses the parsed resolution), so
> it is best-effort — the same trade-off as any *arr custom format. It only
> affects **future** grabs; replace existing incompatible files to have them
> re-fetched.

## DNS

Traefik obtains TLS certificates via ACME. Ensure these hostnames resolve to your VPS before the first deploy:

- `{{ server_domain }}` — Seerr
- `jellyfin.{{ server_domain }}` — Jellyfin
