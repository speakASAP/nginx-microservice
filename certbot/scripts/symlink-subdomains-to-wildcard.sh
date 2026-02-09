#!/bin/sh
# One-time: replace subdomain cert dirs with symlinks to wildcard base (e.g. sgipreal.com or statex.cz).
# Run from nginx-microservice: docker compose run --rm certbot /scripts/symlink-subdomains-to-wildcard.sh [base_domain]
# Example: .../symlink-subdomains-to-wildcard.sh statex.cz
# Example: .../symlink-subdomains-to-wildcard.sh sgipreal.com  (or no arg for backward compat)
set -e
cd /etc/letsencrypt
BASE="${1:-sgipreal.com}"

if [ "$BASE" = "statex.cz" ]; then
  SUBDOMAINS="allegro.statex.cz auth.statex.cz ai.statex.cz beauty.statex.cz crypto-ai-agent.statex.cz \
    flipflop.statex.cz logging.statex.cz marathon.statex.cz notifications.statex.cz payments.statex.cz \
    shop-assistant.statex.cz speakasap.statex.cz warehouse.statex.cz catalog.statex.cz supplier.statex.cz \
    orders.statex.cz heureka.statex.cz aukro.statex.cz bazos.statex.cz messenger.statex.cz \
    leads.statex.cz docs.statex.cz status.statex.cz"
elif [ "$BASE" = "sgipreal.com" ]; then
  SUBDOMAINS="database-server.sgipreal.com auth.sgipreal.com logging.sgipreal.com"
elif [ "$BASE" = "alfares.cz" ]; then
  SUBDOMAINS="ai.alfares.cz auth.alfares.cz leads.alfares.cz logging.alfares.cz marathon.alfares.cz \
    messenger.alfares.cz notifications.alfares.cz payments.alfares.cz speakasap.alfares.cz"
else
  echo "Usage: symlink-subdomains-to-wildcard.sh [sgipreal.com|statex.cz|alfares.cz]"
  exit 1
fi

for d in $SUBDOMAINS; do
  if [ -d "$d" ] && [ ! -L "$d" ]; then
    rm -rf "$d"
    ln -s "$BASE" "$d"
    echo "Symlinked $d -> $BASE"
  fi
done
echo "Done. Reload nginx to use wildcard cert for subdomains."
