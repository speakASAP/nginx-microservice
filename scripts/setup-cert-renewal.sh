#!/bin/bash
# Setup Certificate Renewal Script
# Creates systemd timer or cron job for automatic certificate renewal

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RENEWAL_SCRIPT="${PROJECT_DIR}/certbot/scripts/renew-cert.sh"

echo "Setting up certificate renewal automation..."
echo ""

# Detect system type
if [ -d /etc/systemd/system ]; then
    # Systemd system
    echo "Detected systemd. Creating systemd timer..."
    
    SERVICE_FILE="/etc/systemd/system/nginx-certbot-renew.service"
    TIMER_FILE="/etc/systemd/system/nginx-certbot-renew.timer"
    
    # Create service file
    sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Renew Let's Encrypt certificates for nginx
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${PROJECT_DIR}
ExecStart=/usr/bin/docker compose -f ${PROJECT_DIR}/docker-compose.yml run --rm certbot /scripts/renew-cert.sh
EOF

    # Create timer file
    sudo tee "$TIMER_FILE" > /dev/null <<EOF
[Unit]
Description=Renew Let's Encrypt certificates daily
Requires=nginx-certbot-renew.service

[Timer]
OnCalendar=daily
OnCalendar=weekly
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Enable and start timer
    sudo systemctl daemon-reload
    sudo systemctl enable nginx-certbot-renew.timer
    sudo systemctl start nginx-certbot-renew.timer
    
    echo "✅ Systemd timer created and enabled"
    echo ""
    echo "Status:"
    sudo systemctl status nginx-certbot-renew.timer --no-pager -l || true
    echo ""
    echo "To check timer status:"
    echo "  sudo systemctl status nginx-certbot-renew.timer"
    echo ""
    echo "To check service logs:"
    echo "  sudo journalctl -u nginx-certbot-renew.service"
    
elif command -v crontab >/dev/null 2>&1; then
    # Cron system
    echo "Detected cron. Creating cron job..."
    
    CRON_JOB="0 3 * * * cd ${PROJECT_DIR} && docker compose -f ${PROJECT_DIR}/docker-compose.yml run --rm certbot /scripts/renew-cert.sh >> ${PROJECT_DIR}/logs/certbot/renewal.log 2>&1"
    
    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -q "renew-cert.sh"; then
        echo "⚠️  Cron job already exists"
        read -p "Do you want to replace it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            (crontab -l 2>/dev/null | grep -v "renew-cert.sh"; echo "$CRON_JOB") | crontab -
            echo "✅ Cron job updated"
        else
            echo "Aborted."
            exit 0
        fi
    else
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
        echo "✅ Cron job created"
    fi
    
    echo ""
    echo "Current cron jobs:"
    crontab -l | grep -E "(renew-cert|nginx)" || echo "  (none found)"
    echo ""
    echo "Cron job will run daily at 3:00 AM"
    
else
    echo "❌ Could not detect systemd or cron. Please set up renewal manually."
    echo ""
    echo "Manual renewal:"
    echo "  cd ${PROJECT_DIR}"
    echo "  docker compose run --rm certbot /scripts/renew-cert.sh"
    exit 1
fi

echo ""
echo "✅ Certificate renewal automation setup complete!"

