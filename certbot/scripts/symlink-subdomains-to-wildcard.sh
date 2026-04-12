#!/bin/sh
# One-time: point subdomain certificate dirs at the shared wildcard base (e.g. alfares.cz).
# Run from nginx-microservice: docker compose run --rm certbot /scripts/symlink-subdomains-to-wildcard.sh [base_domain]
# Example: .../symlink-subdomains-to-wildcard.sh statex.cz
# Example: .../symlink-subdomains-to-wildcard.sh sgipreal.com  (or no arg for backward compat)
#
# After issuing *.BASE + BASE (see request-cert-wildcard.sh and README "Wildcard certificates"):
# - Nginx still references /etc/nginx/certs/<hostname>/fullchain.pem per vhost.
# - Each <hostname> under certificates/ should symlink to BASE so all hostnames use one LE cert.
# When you add a new *.alfares.cz (or other zone) vhost, add the hostname to SUBDOMAINS below
# and re-run this script, then reload nginx.
set -e
cd /etc/letsencrypt
BASE="${1:-sgipreal.com}"

if [ "$BASE" = "statex.cz" ]; then
  SUBDOMAINS="allegro.statex.cz auth.statex.cz ai.statex.cz beauty.statex.cz crypto-ai-agent.statex.cz \
    flipflop.statex.cz logging.statex.cz marathon.statex.cz notifications.statex.cz payments.statex.cz \
    shop-assistant.statex.cz speakasap-assessment.statex.cz speakasap-certification.statex.cz speakasap.statex.cz warehouse.statex.cz catalog.statex.cz supplier.statex.cz \
    orders.statex.cz heureka.statex.cz aukro.statex.cz bazos.statex.cz messenger.statex.cz \
    leads.statex.cz docs.statex.cz status.statex.cz"
elif [ "$BASE" = "sgipreal.com" ]; then
  SUBDOMAINS="database-server.sgipreal.com auth.sgipreal.com logging.sgipreal.com"
elif [ "$BASE" = "alfares.cz" ]; then
  # Keep in sync with nginx vhosts under nginx-microservice/nginx/conf.d/*.alfares.cz.conf
  # and any symlinked names under certificates/ on alfares. Order: alphabetical by first label.
  SUBDOMAINS="aeps.alfares.cz agentic-email-processing-system.alfares.cz ai.alfares.cz allegro.alfares.cz \
    aukro.alfares.cz auth.alfares.cz catalog.alfares.cz flipflop.alfares.cz leads.alfares.cz \
    logging.alfares.cz marathon.alfares.cz messenger.alfares.cz minio.alfares.cz notifications.alfares.cz \
    orchestrator.alfares.cz orders.alfares.cz payments.alfares.cz rehtani.alfares.cz shop-assistant.alfares.cz \
    speakasap.alfares.cz statex-ecosystem.alfares.cz suppliers.alfares.cz warehouse.alfares.cz"
else
  echo "Usage: symlink-subdomains-to-wildcard.sh [sgipreal.com|statex.cz|alfares.cz]"
  exit 1
fi

for d in $SUBDOMAINS; do
  if [ "$d" = "$BASE" ]; then
    continue
  fi
  if [ -L "$d" ]; then
    if [ "$(readlink "$d")" = "$BASE" ]; then
      echo "OK (already): $d -> $BASE"
      continue
    fi
    rm -f "$d"
  elif [ -d "$d" ]; then
    rm -rf "$d"
  elif [ -e "$d" ]; then
    echo "Skip $d: exists and is not a directory (fix manually)"
    continue
  fi
  ln -s "$BASE" "$d"
  echo "Symlinked $d -> $BASE"
done
echo "Done. Reload nginx to use wildcard cert for subdomains."
