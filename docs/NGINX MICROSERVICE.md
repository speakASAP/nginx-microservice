# Nginx Microservice Implementation Plan

## Architecture Overview

This nginx microservice provides a centralized reverse proxy solution for managing multiple domains and subdomains. All configuration files, certificates, and logs are stored on the host filesystem and mounted into Docker containers for reliability and persistence.

## Key Principles

1. **Host-First Storage**: All files stored on host filesystem, mounted into containers
2. **DNS-Based Discovery**: Container discovery via Docker DNS
3. **Smart Certificate Management**: Cache certificates locally, request only when needed
4. **Automated Renewal**: Certificates renewed automatically via cron/systemd
5. **Script-Based Management**: Domain management via scripts (add-domain.sh, etc.)
6. **Validated Config Pipeline**: All nginx configs are generated to a staging directory, validated in isolation with existing configs, and only then applied via blue/green configs and symlinks. Invalid configs are rejected and never break a running nginx instance.

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
│   ├── nginx.conf                  # main config - copied to container
│   ├── conf.d/                     # mounted from host (only symlinks are included by nginx)
│   │   ├── staging/                # new configs before validation
│   │   ├── blue-green/             # validated configs (active)
│   │   ├── rejected/               # invalid configs (for debugging)
│   │   └── {domain}.conf           # symlink to blue-green/{domain}.{color}.conf
│   └── templates/
│       ├── domain.conf.template             # simple single-backend template
│       └── domain-blue-green.conf.template  # blue/green template generated from service registry
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
- [ ] Create nginx/templates/domain-blue-green.conf.template
- [ ] Initialize nginx/conf.d/staging/, nginx/conf.d/blue-green/, nginx/conf.d/rejected/ (managed by scripts)

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

### Nginx Config Validation Workflow

Nginx configs are managed by a **validated pipeline** that guarantees nginx keeps running even when a new config is broken.

Directory structure:

```text
nginx/conf.d/
├── staging/               # New configs before validation
│   └── {domain}.{color}.conf
├── blue-green/            # Validated configs (active)
│   └── {domain}.{color}.conf
├── rejected/              # Invalid configs (for debugging)
│   └── {domain}.{color}.conf.{timestamp}
└── {domain}.conf          # Symlink to blue-green/{domain}.{color}.conf
```

Validation flow:

1. **Generate to staging**: New configs are written to `nginx/conf.d/staging/`.
2. **Isolated validation**: Each new config is tested together with all existing validated configs in an isolated environment.
3. **Apply if valid**: Valid configs are moved to `nginx/conf.d/blue-green/` and the `{domain}.conf` symlink is updated.
4. **Reject if invalid**: Invalid configs are moved to `nginx/conf.d/rejected/` with a timestamp. Nginx continues running with existing valid configs.

Guarantees:

- Nginx can start and run independently of container state (missing containers produce 502s, not startup failures).
- A single bad config is rejected and **cannot break** nginx or other services.

### Add Domain Process

`add-domain.sh` uses the same validated pipeline to safely add domains.

1. Run `./scripts/add-domain.sh domain.com container-name [port] [email]`.
2. Script validates inputs (domain format, required arguments).
3. Script generates an nginx config from `nginx/templates/domain.conf.template` into `nginx/conf.d/staging/domain.com.blue.conf`.
4. Script calls the central validation helpers to test the new config **in isolation** together with all existing validated configs.
5. If validation **fails**:
   - The config is moved to `nginx/conf.d/rejected/domain.com.blue.conf.<timestamp>`.
   - Nginx continues running with existing configs from `nginx/conf.d/blue-green/`.
   - The script exits with a non-zero status and instructs you to inspect the rejected file and logs.
6. If validation **passes**:
   - The config is moved to `nginx/conf.d/blue-green/domain.com.blue.conf`.
   - The symlink `nginx/conf.d/domain.com.conf` is created or updated to point to `blue-green/domain.com.blue.conf`.
7. The script checks certificate status and, if necessary, requests a certificate via the certbot container.
8. The script performs a **safe reload** via the shared `reload_nginx` helper, which:
   - Tests configuration using a tolerant helper.
   - Starts nginx if it is not running.
   - Reloads configs while preserving existing connections.
9. Finally, the script attempts to verify container accessibility over `nginx-network` (for diagnostics only).

**Safety guarantee**: A bad config generated by `add-domain.sh` is always rejected into `nginx/conf.d/rejected/` and **cannot break** a running nginx instance.

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
  Uses the validated staging → blue-green → symlink pipeline; invalid configs are rejected into `nginx/conf.d/rejected/` and nginx continues running.
- Remove domain: `./scripts/remove-domain.sh domain.com`  
  Removes the domain symlink and associated validated config, tests nginx configuration, and safely reloads nginx.
- List domains: `./scripts/list-domains.sh`  
  Lists current `{domain}.conf` symlinks, backing containers, and certificates.
- Reload nginx: `./scripts/reload-nginx.sh`  
  Runs a tolerant config test and reloads nginx, assuming configs were already validated by the pipeline.
- Check certificates: `docker-compose run certbot check-cert-expiry.sh`
- Manual renewal: `docker-compose run certbot renew-cert.sh`
