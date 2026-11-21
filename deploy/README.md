# Deploy: uzaromessenger.uz

Server: shared VPS, project in `/opt/sado` (docker compose `sado`). Public traffic goes through the shared
Caddy container `nurbozor-caddy-1`; its config is `/opt/NurBozor/deploy/Caddyfile`.

- `uzaromessenger.uz` — the site (`uzaro-web`, nginx, read-only `/opt/sado/web`) plus the API routes
  `/v1 /admin /media /download /privacy /health` (`sado-api:8080`). Block: [caddy/uzaromessenger.uz.caddy](caddy/uzaromessenger.uz.caddy).
- `www.uzaromessenger.uz` redirects to the apex. `sado.voxo.uz` still serves the API for older app builds.

Update the site:

    tar czf - -C web . | ssh root@169.58.135.28 'rm -rf /opt/sado/web.new && mkdir /opt/sado/web.new && tar xzf - -C /opt/sado/web.new && mv /opt/sado/web /opt/sado/web.old-$(date +%s) && mv /opt/sado/web.new /opt/sado/web'

Then `docker restart sado-uzaro-web-1`: the bind mount keeps pointing at the renamed old folder until the container restarts.

Update the API: copy `server/` to `/opt/sado/server`, then `cd /opt/sado && docker compose build api && docker compose up -d api`.

Caddy changes: edit the Caddyfile, then
`docker exec nurbozor-caddy-1 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile` and, only if valid,
`docker exec nurbozor-caddy-1 caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`. It serves other projects too.

Caveat: the Caddyfile is bind-mounted read-only as a single file. Edit it in place (`cat >>`, an editor that keeps the
inode); `sed -i` writes a new file the running container never sees. If that happened, load it without a restart:
`docker cp /opt/NurBozor/deploy/Caddyfile nurbozor-caddy-1:/tmp/Caddyfile.live` and
`docker exec nurbozor-caddy-1 caddy reload --config /tmp/Caddyfile.live --adapter caddyfile`.

Site build: `node deploy/build-site.js` regenerates /ru/, /en/, JSON-LD and sitemap.xml from the Uzbek pages and
web/js/i18n.js. Run it before every upload.
