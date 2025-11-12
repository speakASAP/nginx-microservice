# Nginx Microservice Implementation Plan

## Architecture Overview

This nginx microservice provides a centralized reverse proxy solution for managing multiple domains and subdomains. All configuration files, certificates, and logs are stored on the host filesystem and mounted into Docker containers for reliability and persistence.

## Key Principles

1. **Host-First Storage**: All files stored on host filesystem, mounted into containers
2. **DNS-Based Discovery**: Container discovery via Docker DNS
3. **Smart Certificate Management**: Cache certificates locally, request only when needed
4. **Automated Renewal**: Certificates renewed automatically via cron/systemd
5. **Script-Based Management**: Domain management via scripts (add-domain.sh, etc.)

## Project Structure

```text
nginx-microservice/
├── docker-compose.yml
├── .env.example
├── .env (gitignored)
├── README.md
├── PLAN.md
├── nginx/
│   ├── Dockerfile
│   ├── nginx.conf (main config - copied to container)
│   ├── conf.d/ (mounted from host)
│   │   ├── statex.cz.conf
│   │   └── crypto-ai-agent.statex.cz.conf
│   └── templates/
│       └── domain.conf.template
├── certbot/
│   ├── Dockerfile
│   └── scripts/ (copied to container)
│       ├── request-cert.sh
│       ├── check-cert-expiry.sh
│       └── renew-cert.sh
├── scripts/ (host-based scripts)
│   ├── add-domain.sh
│   ├── remove-domain.sh
│   ├── list-domains.sh
│   ├── reload-nginx.sh
│   └── setup-cert-renewal.sh
├── certificates/ (host storage)
│   ├── statex.cz/
│   │   ├── fullchain.pem
│   │   └── privkey.pem
│   └── crypto-ai-agent.statex.cz/
│       ├── fullchain.pem
│       └── privkey.pem
├── logs/ (host storage)
│   ├── nginx/
│   │   ├── access.log
│   │   └── error.log
│   └── certbot/
│       └── certbot.log
└── .gitignore
```

## File Storage Strategy

### Host Filesystem Locations (on server)

- Configs: `/home/statex/nginx-microservice/nginx/conf.d/`
- Certificates: `/home/statex/nginx-microservice/certificates/`
- Logs: `/home/statex/nginx-microservice/logs/`
- Webroot: `/home/statex/nginx-microservice/webroot/`

### Docker Volume Mounts

- Configs: Host `conf.d/` → Container `/etc/nginx/conf.d/`
- Certificates: Host `certificates/` → Container `/etc/nginx/certs/`
- Logs: Host `logs/` → Container `/var/log/nginx/` and `/var/log/certbot/`
- Webroot: Host `webroot/` → Container `/var/www/html/`

## Implementation Checklist

### Phase 1: Project Setup

- [x] Create project directory structure
- [ ] Initialize git repository
- [ ] Create docker-compose.yml
- [ ] Create .env.example and .env
- [ ] Create .gitignore

### Phase 2: Nginx Configuration

- [ ] Create nginx/Dockerfile
- [ ] Create nginx/nginx.conf (main config)
- [ ] Create nginx/templates/domain.conf.template
- [ ] Create nginx/conf.d/statex.cz.conf
- [ ] Create nginx/conf.d/crypto-ai-agent.statex.cz.conf

### Phase 3: Certbot Configuration

- [ ] Create certbot/Dockerfile
- [ ] Create certbot/scripts/request-cert.sh
- [ ] Create certbot/scripts/check-cert-expiry.sh
- [ ] Create certbot/scripts/renew-cert.sh

### Phase 4: Management Scripts

- [ ] Create scripts/add-domain.sh
- [ ] Create scripts/remove-domain.sh
- [ ] Create scripts/list-domains.sh
- [ ] Create scripts/reload-nginx.sh
- [ ] Create scripts/setup-cert-renewal.sh

### Phase 5: Certificate Renewal Automation

- [ ] Create systemd timer/cron configuration
- [ ] Test renewal process

### Phase 6: Documentation

- [ ] Create README.md
- [ ] Document usage examples
- [ ] Create troubleshooting guide

### Phase 7: Testing

- [ ] Test statex.cz configuration
- [ ] Test crypto-ai-agent.statex.cz configuration
- [ ] Test add-domain.sh script
- [ ] Test certificate requesting
- [ ] Test certificate renewal
- [ ] Test DNS-based container discovery
- [ ] Verify logging

## Configuration Details

### DNS-Based Container Discovery

Containers are discovered via Docker DNS using container names:

- Format: `http://container-name:port`
- Example: `http://statex.cz:3000`
- Example: `http://crypto-ai-agent-frontend:3100`

All containers must be on the same Docker network (`nginx-network`).

### Certificate Management Flow

1. **Request Certificate**:
   - Check if certificate exists in host `certificates/domain/`
   - Check expiration date (request if < 30 days)
   - Request via certbot container
   - Store in both Docker volume and host filesystem
   - Copy to nginx accessible location

2. **Renew Certificate**:
   - Check all certificates in host `certificates/`
   - Find certificates expiring in < 30 days
   - Renew via certbot
   - Update both storage locations
   - Reload nginx

3. **Certificate Storage**:
   - Primary: Host filesystem `/home/statex/nginx-microservice/certificates/`
   - Secondary: Docker volume (for container access)
   - Symlink: Nginx container `/etc/nginx/certs/domain/` → Host `certificates/domain/`

### Domain Configuration Template

Each domain config includes:

- HTTP server block (port 80) → Redirect to HTTPS
- HTTPS server block (port 443) with SSL
- Proxy configuration using DNS-based container discovery
- Security headers
- Logging configuration

### Add Domain Process

1. Run `./scripts/add-domain.sh domain.com container-name [port]`
2. Script validates inputs
3. Creates config file from template
4. Checks certificate status
5. Requests certificate if needed
6. Tests nginx configuration
7. Reloads nginx
8. Verifies container accessibility

## Network Configuration

- Network Name: `nginx-network` (created by docker-compose)
- Network Type: Bridge
- All application containers must join this network

## Logging

- Nginx Access Logs: `/logs/nginx/access.log`
- Nginx Error Logs: `/logs/nginx/error.log`
- Certbot Logs: `/logs/certbot/certbot.log`
- Log Rotation: Configured via nginx logrotate

## Security Considerations

1. Certificate private keys: 600 permissions, root ownership
2. Config files: 644 permissions
3. Scripts: 755 permissions
4. No secrets in git repository
5. Environment variables in .env (gitignored)

## Deployment Steps

1. Clone repository to server
2. Copy .env.example to .env and configure
3. Copy existing certificates to certificates/ directory
4. Run `docker-compose up -d`
5. Setup certificate renewal: `./scripts/setup-cert-renewal.sh`
6. Verify nginx is running: `docker-compose ps`
7. Test domains: `curl https://statex.cz`

## Maintenance

- Add new domain: `./scripts/add-domain.sh domain.com container port`
- Remove domain: `./scripts/remove-domain.sh domain.com`
- List domains: `./scripts/list-domains.sh`
- Reload nginx: `./scripts/reload-nginx.sh`
- Check certificates: `docker-compose run certbot check-cert-expiry.sh`
- Manual renewal: `docker-compose run certbot renew-cert.sh`
