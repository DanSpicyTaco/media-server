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

# Secrets — see .env.example for descriptions
qbittorrent_password=<XXXX>
jellyfin_password=<XXXX>
seerr_admin_password=<XXXX>
```

The *arr API keys are optional: when omitted they are auto-generated and
stored in `.credentials/` next to your inventory (gitignored), so re-runs
reuse the same keys. If your VPS uses a non-standard SSH port, set
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

## DNS

Traefik obtains TLS certificates via ACME. Ensure these hostnames resolve to your VPS before the first deploy:

- `{{ server_domain }}` — Seerr
- `jellyfin.{{ server_domain }}` — Jellyfin
