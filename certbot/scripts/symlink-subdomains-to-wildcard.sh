#!/bin/sh
# One-time: replace subdomain cert dirs with symlinks to sgipreal.com (wildcard cert).
# Run from nginx-microservice: docker compose run --rm certbot /scripts/symlink-subdomains-to-wildcard.sh
set -e
cd /etc/letsencrypt
for d in database-server.sgipreal.com auth.sgipreal.com logging.sgipreal.com; do
  if [ -d "$d" ] && [ ! -L "$d" ]; then
    rm -rf "$d"
    ln -s sgipreal.com "$d"
    echo "Symlinked $d -> sgipreal.com"
  fi
done
ls -la database-server.sgipreal.com auth.sgipreal.com logging.sgipreal.com 2>/dev/null || true
echo "Done. Reload nginx to use wildcard cert for subdomains."
