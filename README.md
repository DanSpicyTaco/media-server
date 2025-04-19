# Media Server

This project sets up a media server on a virtual private server. It allows you to create Plex, Radarr, Sonarr, Prowlarr
and qBittorrent services automatically through Ansible.

> **⚠️WARNING⚠️** I do not condone the use of this technology for downloading illegal or copyrighted content. This is
> purely for fun and not for doing anything illegal.

## Deployment

If you haven't already, install [Ansible](https://docs.ansible.com/ansible/latest/index.html) on your local machine. Next, create an inventory file, `inventory.ini`. It should look like:

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

   # Secrets
   plex_token=<XXXX>
   qbittorrent_password=<XXXX>
   prowlarr_api_key=<XXXX>
   radarr_api_key=<XXXX>
   sonarr_api_key=<XXXX>
```

> **Note**: the deployment assumes you already have a VPS set up with a user NOT in root. Running everything in root
> creates a lot of security issues. Please don't do this!

Then, run the Ansible playbook to set up the server:

```zsh
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml
```

If you would like to skip any of the steps (e.g. setup), you can run specific tasks with the `tags` command like so:

```zsh
ansible-playbook -i inventory.ini setup-media-server.playbook.yaml  --tags frontend
```

### Prowlarr

Prowlarr can be set up with indexers to search torrenting websites. To do so, set up port forwarding to the Prowlarr
port and head to `http://localhost:{prowlar_port}`. Clicking on "Add Indexers" brings up a page for this.

 Generally, just filter for public, US language indexers and add a few. The more, the better the chance of finding a torrent.

## Customisation

You can customise the application, such as having a different port number, by overwriting the `vars.yml` file.
