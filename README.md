# Nginx Microservice

A centralized reverse proxy microservice for managing multiple domains and subdomains with automatic SSL certificate management via Let's Encrypt.

## Migration Note

**✅ Migration Complete** (October 31, 2024): SSL certificates and Let's Encrypt data have been migrated from `statex-infrastructure` to this nginx-microservice. The `certificates/` directory now contains:

- Let's Encrypt certificates from `statex-infrastructure/letsencrypt/`
- Let's Encrypt account data from `statex-infrastructure/letsencrypt-persistent/`
- Webroot content from `statex-infrastructure/webroot/`

All SSL management is now centralized in this microservice.

## Features

- 🚀 **DNS-Based Container Discovery**: Automatically discovers containers via Docker DNS
- 🔒 **Automatic SSL Certificates**: Smart certificate requesting and renewal via Let's Encrypt
- 📁 **Host-First Storage**: All files stored on host filesystem for reliability
- 🔄 **Dynamic Configuration**: Add domains by simply adding config files
- 📊 **Certificate Caching**: Reduces Let's Encrypt API calls by caching certificates locally
- 🤖 **Automated Renewal**: Certificates renewed automatically via systemd timer or cron
- 📝 **Comprehensive Logging**: Access and error logs for all domains
- 🎯 **Container Independence**: Nginx starts and runs independently of container state - configs generated from registry, not container state

## Architecture

```text
nginx-microservice/
├── nginx/              # Nginx configuration and Dockerfile
├── certbot/            # Certbot scripts for certificate management
├── scripts/            # Management scripts (add-domain, remove-domain, etc.)
├── certificates/       # SSL certificates (host storage)
├── logs/               # Log files (host storage)
└── webroot/            # Let's Encrypt challenge files
```

## Quick Start

### 1. Clone and Setup

```bash
git clone <repository-url>
cd nginx-microservice
cp .env.example .env
# Edit .env with your settings
```

### 2. Start Services

```bash
docker compose up -d
```

### 3. Add Your First Domain

```bash
./scripts/add-domain.sh statex.cz statex.cz 3000
```

### 4. Setup Certificate Renewal

```bash
./scripts/setup-cert-renewal.sh
```

## Usage

### Adding a Domain

```bash
./scripts/add-domain.sh <domain> <container-name> [port] [email]
```

**Examples:**

```bash
# Basic usage
./scripts/add-domain.sh example.com my-app

# With custom port
./scripts/add-domain.sh example.com my-app 8080

# With custom email
./scripts/add-domain.sh example.com my-app 3000 admin@example.com

# Subdomain
./scripts/add-domain.sh subdomain.example.com my-app 3000
```

### Removing a Domain

```bash
./scripts/remove-domain.sh <domain> [--remove-cert]
```

**Examples:**

```bash
# Remove domain config only
./scripts/remove-domain.sh example.com

# Remove domain config and certificate
./scripts/remove-domain.sh example.com --remove-cert
```

### Listing Domains

```bash
./scripts/list-domains.sh
```

### Reloading Nginx

```bash
./scripts/reload-nginx.sh
```

**Note**: The `restart-nginx.sh` script automatically syncs containers and symlinks before restarting. It prefers `reload` over `restart` when nginx is already running to avoid breaking existing connections.

### Container and Nginx Synchronization

The system includes an automated synchronization mechanism that ensures nginx configuration symlinks point to the correct active containers (blue/green) and generates configs from the service registry.

**Important**: Nginx is **independent of container state** - it can start and run even when containers are not running. Nginx will return 502 errors until containers become available, which is acceptable behavior. When containers start, nginx automatically connects to them.

**Automatic Sync (Recommended)**:

```bash
# restart-nginx.sh automatically syncs before restarting
./scripts/restart-nginx.sh
```

**Manual Sync**:

```bash
# Sync containers and symlinks (no restart)
./scripts/sync-containers-and-nginx.sh

# Sync and restart nginx
./scripts/sync-containers-and-nginx.sh --restart-nginx
```

**What it does**:

1. Scans all services in the registry
2. Generates nginx configs from registry (independent of container state)
3. Checks which containers are running (blue, green, or both) - for informational purposes
4. Updates symlinks to point to the expected color (from state) or running containers
5. Optionally starts missing containers (using deploy-smart.sh) - not required
6. Validates nginx configuration (may fail if nginx container is not running, which is acceptable)
7. Optionally reloads/restarts nginx

**Symlink Logic**:

- If containers match expected color → Symlink stays as-is ✅
- If containers don't match → Updates symlink to match running containers
- If no containers running → Keeps expected color, optionally tries to start them

**Key Principle**: Configs are generated from the service registry, not from container state. Nginx can start and run with configs pointing to non-existent containers - it will return 502 errors until containers are available.

For detailed information, see **[Container and Nginx Synchronization Guide](docs/CONTAINER_NGINX_SYNC.md)**.

### Manual Certificate Operations

```bash
# Request certificate
docker compose run --rm certbot /scripts/request-cert.sh <domain> [email]

# Check certificate expiry
docker compose run --rm certbot /scripts/check-cert-expiry.sh [domain]

# Renew certificates
docker compose run --rm certbot /scripts/renew-cert.sh
```

## Nginx Independence

**Key Principle**: Nginx is independent of container state. This means:

- ✅ **Nginx can start** even when no containers are running
- ✅ **Configs are generated** from the service registry, not from container state
- ✅ **Nginx will return 502 errors** until containers become available (acceptable behavior)
- ✅ **Nginx automatically connects** to containers when they start
- ✅ **No dependency** - containers can start/stop independently of nginx
- ✅ **Config Validation**: New configs are validated before being applied - invalid configs are rejected and nginx continues running with existing valid configs

### How It Works

Nginx resolves hostnames at runtime via DNS, not at startup. This allows:

1. **Config Generation**: Upstream blocks are always generated from the service registry, regardless of whether containers exist
2. **Config Validation**: New configs are generated to a staging directory, validated in isolation with existing configs, and only applied if validation passes
3. **Independent Startup**: Nginx starts successfully even if upstreams point to non-existent containers
4. **Runtime Resolution**: When containers start, nginx automatically resolves their hostnames and connects
5. **Graceful Degradation**: Nginx returns 502 errors for unavailable upstreams until containers are ready
6. **Fail-Safe**: Invalid configs are rejected and moved to `conf.d/rejected/` directory - nginx continues running with existing valid configs

### Benefits

- **No startup dependencies**: Nginx doesn't wait for containers to start
- **Flexible deployment**: Containers can be started/stopped without affecting nginx
- **Zero-downtime**: Nginx stays running during container deployments
- **Simplified operations**: No need to coordinate nginx and container startup
- **Config Safety**: Invalid configs are automatically rejected - one bad config won't break all services

### Config Validation System

The system includes a robust validation mechanism that ensures nginx always runs:

1. **Staging Directory**: New configs are generated to `nginx/conf.d/staging/` first
2. **Isolated Validation**: Each new config is tested with all existing valid configs to ensure compatibility
3. **Safe Application**: Only validated configs are moved to `nginx/conf.d/blue-green/`
4. **Rejection Handling**: Invalid configs are moved to `nginx/conf.d/rejected/` with timestamps for debugging
5. **Nginx Resilience**: Nginx continues running with existing valid configs even if new configs fail validation

**Example**: If you add a new service with a config that has a syntax error or conflicts with existing configs:

- The invalid config is rejected and moved to `rejected/` directory
- Nginx continues running with all existing valid configs
- RabbitMQ, database, and logging servers remain unaffected
- You can fix the config and try again

For more details, see the [Container and Nginx Synchronization Guide](docs/CONTAINER_NGINX_SYNC.md).

## Configuration

### Environment Variables

Edit `.env` file:

```bash
CERTBOT_EMAIL=admin@statex.cz    # Email for Let's Encrypt
CERTBOT_STAGING=false            # Use staging environment (for testing)
NETWORK_NAME=nginx-network       # Docker network name
LOG_LEVEL=info                   # Logging level
```

### Domain Configuration

Domain configurations are stored in `nginx/conf.d/` directory. Each domain has its own `.conf` file.

The configuration template (`nginx/templates/domain.conf.template`) includes:

- HTTP to HTTPS redirect
- SSL/TLS configuration
- Security headers
- Rate limiting
- Proxy configuration with DNS-based container discovery

### Container Requirements

1. **Same Docker Network**: All containers must be on the `nginx-network`
2. **Container Names**: Use container names (not service names) for DNS discovery
3. **Port Exposure**: Containers must expose ports internally on the network

**Example docker-compose.yml for your application:**

```yaml
services:
  my-app:
    image: my-app:latest
    container_name: my-app
    networks:
      - nginx-network
    # ... other config
```

**Connect existing container to network:**

```bash
docker network connect nginx-network <container-name>
```

## Certificate Management

### Certificate Storage Architecture

Certificates are stored in a three-tier system for reliability and persistence:

1. **Host filesystem** (Primary): `./certificates/<domain>/`
   - This is the **primary storage location** on the host
   - Files persist across container restarts and recreations
   - Contains actual certificate files (not symlinks)

2. **Certbot container**: `/etc/letsencrypt/live/<domain>/`
   - Symlinks pointing to `/etc/letsencrypt/archive/<domain>/`
   - Used by certbot for certificate management
   - Volume mount: `./certificates` → `/etc/letsencrypt` in certbot container

3. **Nginx container**: `/etc/nginx/certs/<domain>/`
   - Read-only access to certificates for SSL configuration
   - Volume mount: `./certificates` → `/etc/nginx/certs` in nginx container

**Important**: The `request-cert.sh` script automatically copies certificates from certbot's location to the host filesystem (`./certificates/<domain>/`). This ensures:

- Nginx can access certificates reliably
- Certificates survive container restarts
- Files are stored on persistent host storage

### Certificate Files

Each domain has two certificate files in `./certificates/<domain>/`:

- **`fullchain.pem`**: Complete certificate chain
  - Contains: Domain certificate + intermediate certificates
  - Required for SSL/TLS handshake
  - Permissions: `644` (readable by nginx)

- **`privkey.pem`**: Private key
  - Must be kept secure and never exposed
  - Required for SSL/TLS encryption
  - Permissions: `600` (only readable by owner)

### Certificate Request Flow

When requesting a certificate (via `add-domain.sh` or manually):

1. **Check existing certificate**: Script checks if certificate exists in `./certificates/<domain>/`
2. **Validate expiration**: If certificate exists, checks if it expires in < 30 days
3. **Request new certificate**: If needed, requests from Let's Encrypt using webroot validation
   - Certbot places challenge file in `/var/www/html/.well-known/acme-challenge/`
   - Nginx serves this file to prove domain ownership
   - Let's Encrypt validates and issues certificate
4. **Copy to host**: `request-cert.sh` copies certificate files to `./certificates/<domain>/`
   - Uses `cp -L` to follow symlinks and copy actual files
   - Sets proper file permissions (644 for fullchain, 600 for privkey)
5. **Nginx configuration**: Update nginx config to reference:

   ```nginx
   ssl_certificate /etc/nginx/certs/<domain>/fullchain.pem;
   ssl_certificate_key /etc/nginx/certs/<domain>/privkey.pem;
   ```

6. **Reload nginx**: Certificate is immediately available after nginx reload

### Certificate Renewal

Let's Encrypt certificates are valid for **90 days**. Renewal should happen when < 30 days remain.

**Automatic Renewal**:

- **Systemd**: Daily check via timer (if configured)
- **Cron**: Daily at 3:00 AM (if configured)
- Renewal automatically triggers nginx reload

**Manual Renewal**:

```bash
# Renew all certificates
docker compose run --rm certbot /scripts/renew-cert.sh

# Renew specific domain
docker compose run --rm certbot /scripts/request-cert.sh <domain>
```

**Check Certificate Expiry**:

```bash
# Check specific domain
docker compose run --rm certbot /scripts/check-cert-expiry.sh <domain>

# Check certificate on host
openssl x509 -enddate -noout -in certificates/<domain>/fullchain.pem
```

### Troubleshooting Certificate Issues

#### Certificate Not Found in Nginx

**Symptom**: `nginx: [emerg] cannot load certificate "/etc/nginx/certs/<domain>/fullchain.pem"`

**Solution**:

1. Verify certificate exists on host: `ls -la certificates/<domain>/`
2. If missing, copy from certbot container:

   ```bash
   docker exec nginx-certbot sh -c 'mkdir -p /etc/letsencrypt/<domain> && cp -L /etc/letsencrypt/live/<domain>/fullchain.pem /etc/letsencrypt/<domain>/ && cp -L /etc/letsencrypt/live/<domain>/privkey.pem /etc/letsencrypt/<domain>/ && chmod 644 /etc/letsencrypt/<domain>/fullchain.pem && chmod 600 /etc/letsencrypt/<domain>/privkey.pem'
   ```

3. Verify nginx config references correct path: `/etc/nginx/certs/<domain>/fullchain.pem`

#### Certificate Request Fails

**Common causes**:

- DNS not pointing to server: `dig <domain>` should return server IP
- Port 80 not accessible: Let's Encrypt needs HTTP access for validation
- Rate limiting: Let's Encrypt has rate limits (50 certs/week per domain)

**Debug steps**:

```bash
# Check DNS
dig <domain>

# Test HTTP access
curl http://<domain>/.well-known/acme-challenge/test

# Check certbot logs
docker compose logs certbot

# Use staging environment for testing
CERTBOT_STAGING=true docker compose run --rm certbot /scripts/request-cert.sh <domain>
```

#### Certificate Expired

**Symptom**: Browser shows "Certificate has expired" error

**Solution**:

```bash
# Renew certificate
docker compose run --rm certbot /scripts/request-cert.sh <domain>

# Verify new certificate
openssl x509 -enddate -noout -in certificates/<domain>/fullchain.pem

# Reload nginx
docker compose exec nginx nginx -s reload
```

## Logging

### Log Locations

- **Nginx Access Logs**: `logs/nginx/access.log`
- **Nginx Error Logs**: `logs/nginx/error.log`
- **Certbot Logs**: `logs/certbot/certbot.log`
- **Renewal Logs**: `logs/certbot/renewal.log` (if using cron)

### View Logs

```bash
# Nginx logs
docker compose logs nginx

# Certbot logs
docker compose logs certbot

# Follow logs
docker compose logs -f nginx
```

## Troubleshooting

### Certificate Not Found

```bash
# Request certificate manually
docker compose run --rm certbot /scripts/request-cert.sh <domain>

# Check certificate status
docker compose run --rm certbot /scripts/check-cert-expiry.sh <domain>
```

### Container Not Accessible

```bash
# Verify container is on the network
docker network inspect nginx-network

# Connect container to network
docker network connect nginx-network <container-name>

# Test container accessibility
docker run --rm --network nginx-network alpine/curl:latest curl http://<container-name>:<port>
```

### Nginx Configuration Errors

```bash
# Test configuration
docker compose exec nginx nginx -t

# View error logs
docker compose logs nginx | grep error
```

### Certificate Renewal Issues

```bash
# Check renewal status (systemd)
sudo systemctl status nginx-certbot-renew.timer

# Check renewal logs (systemd)
sudo journalctl -u nginx-certbot-renew.service

# Check renewal logs (cron)
cat logs/certbot/renewal.log
```

## Development

### Testing with Staging Certificates

Set in `.env`:

```bash
CERTBOT_STAGING=true
```

### Adding Custom Configuration

Edit domain config files in `nginx/conf.d/` or modify the template in `nginx/templates/domain.conf.template`.

## Security Considerations

1. **Certificate Private Keys**: Stored with 600 permissions
2. **Config Files**: Stored with 644 permissions
3. **No Secrets in Git**: `.env` file is gitignored
4. **Rate Limiting**: Configured per domain to prevent abuse
5. **Security Headers**: HSTS, X-Frame-Options, CSP, etc.

## License

MIT License

Copyright (c) 2025 Sergej

See [LICENSE](LICENSE) file for details.

## Blue/Green Deployment

The nginx-microservice includes a zero-downtime blue/green deployment system for services.

### Standardized Services

All services are now standardized and managed through the blue/green deployment system:

- **auth-microservice** - Authentication service
- **crypto-ai-agent** - Crypto AI agent application
- **database-server** - Database infrastructure (shared)
- **e-commerce** - E-commerce platform (heavy application with 10+ internal services)
- **logging-microservice** - Centralized logging service
- **nginx-microservice** - This reverse proxy service
- **notifications-microservice** - Notification service
- **payment-microservice** - Payment processing service
- **statex** - Main statex platform application

### Service Dependencies and Startup Order

All services have dependencies that must be respected when starting the system. See **[Service Dependencies Guide](docs/SERVICE_DEPENDENCIES.md)** for complete details.

**Quick Start - All Services:**

```bash
# Start all services in correct dependency order
./scripts/start-all-services.sh

# Start only infrastructure (database - nginx always starts)
./scripts/start-all-services.sh --skip-microservices --skip-applications

# Start only microservices (assumes infrastructure is running)
./scripts/start-all-services.sh --skip-infrastructure --skip-applications

# Start only applications (assumes infrastructure and microservices are running)
./scripts/start-all-services.sh --skip-infrastructure --skip-microservices

# Start a single service
./scripts/start-all-services.sh --service <service-name>
```

**Individual Scripts (for debugging and maintenance):**

```bash
# Start nginx only (always runs first - mandatory)
./scripts/start-nginx.sh

# Start infrastructure only (database-server)
./scripts/start-infrastructure.sh

# Start microservices only
./scripts/start-microservices.sh
./scripts/start-microservices.sh --service <service-name>

# Start applications only
./scripts/start-applications.sh
./scripts/start-applications.sh --service <service-name>
```

**Startup Order:**

1. **Nginx** (Phase 1 - always runs): nginx-network → nginx-microservice
2. **Infrastructure** (Phase 2): database-server (postgres + redis)
3. **Microservices** (Phase 3): logging-microservice → auth-microservice → payment-microservice → notifications-microservice
4. **Applications** (Phase 4): allegro → crypto-ai-agent → statex → e-commerce

**Note**: Nginx is the primary service and must always start. There is no `--skip-nginx` flag. Nginx will be restarted/reloaded when new services are added, which serves as an additional test point.

### Services Quick Start

```bash
# Deploy a service (full cycle) - RECOMMENDED: Use deploy-smart.sh for better performance
./scripts/blue-green/deploy-smart.sh crypto-ai-agent

# For heavy applications (e-commerce with 10+ services), deploy-smart.sh only rebuilds changed services
# This significantly speeds up deployment time

# Manual rollback if needed
./scripts/blue-green/rollback.sh crypto-ai-agent

# Check deployment status
cat state/crypto-ai-agent.json | jq .
```

### Service Features

- ✅ **Zero-downtime deployments**: Switch traffic with < 2 seconds downtime
- ✅ **Automatic rollback**: Auto-rollback on health check failure
- ✅ **Health monitoring**: Continuous health checks during deployment
- ✅ **Centralized management**: All deployments managed from one place
- ✅ **Service registry**: Easy service configuration via JSON

### Documentation

For detailed documentation, see:

- **[Blue/Green Deployment Guide](docs/BLUE_GREEN_DEPLOYMENT.md)** - Complete usage guide
- **[Service Registry Format](docs/BLUE_GREEN_DEPLOYMENT.md#service-registry-format)** - How to configure services
- **[Troubleshooting](docs/BLUE_GREEN_DEPLOYMENT.md#troubleshooting)** - Common issues and solutions

### Available Scripts

**Blue/Green Deployment Scripts** (in `scripts/blue-green/`):

- `deploy-smart.sh` - **RECOMMENDED**: Full deployment cycle (only rebuilds changed services)
- `prepare-green-smart.sh` - **RECOMMENDED**: Build and start new deployment (only rebuilds changed services)
- `prepare-green.sh` - Build and start new deployment (DEPRECATED: always rebuilds all services, use prepare-green-smart.sh)
- `switch-traffic.sh` - Switch traffic to new color (uses modern symlink-based switching)
- `migrate-to-symlinks.sh` - Migrate services to symlink-based blue/green system
- `health-check.sh` - Check service health
- `rollback.sh` - Rollback to previous deployment
- `cleanup.sh` - Remove old deployment

**Service Startup Scripts** (in `scripts/`):

- `start-all-services.sh` - **MASTER SCRIPT**: Starts all services in dependency order (calls the 4 phase scripts)
- `start-nginx.sh` - Phase 1: Starts nginx-network and nginx-microservice (always runs first - mandatory)
- `start-infrastructure.sh` - Phase 2: Starts database-server (postgres + redis)
- `start-microservices.sh` - Phase 3: Starts all microservices
- `start-applications.sh` - Phase 4: Starts all applications

**Nginx Management Scripts** (in `scripts/`):

- `restart-nginx.sh` - **RECOMMENDED**: Restarts nginx (automatically syncs containers and symlinks first)
- `sync-containers-and-nginx.sh` - Syncs containers and symlinks, optionally restarts nginx
- `reload-nginx.sh` - Reloads nginx configuration (lightweight, no restart)
- `status-all-services.sh` - Shows status of all services and containers
- `diagnose-nginx-restart.sh` - **RECOMMENDED**: Comprehensive diagnostic tool for nginx container restart loops

**Note**: The blue/green system uses a modern symlink-based approach where each service has separate blue and green config files (`{domain}.blue.conf` and `{domain}.green.conf`), with a symlink (`{domain}.conf`) pointing to the active environment. This replaces the legacy file-modification approach.

### Container and Nginx Synchronization Scripts

The system automatically ensures that nginx configuration symlinks point to the correct active containers before restarting nginx. This is critical for blue/green deployments:

**Key Features**:

- ✅ **Automatic symlink management**: Symlinks automatically point to running containers
- ✅ **Container detection**: Detects which color (blue/green) has running containers
- ✅ **Auto-start missing containers**: Starts missing containers using deploy-smart.sh
- ✅ **Safe nginx restart**: Validates configuration before restarting
- ✅ **Integrated with restart-nginx.sh**: Automatically syncs before restart

**Usage**:

```bash
# Recommended: restart-nginx.sh automatically syncs
./scripts/restart-nginx.sh

# Manual sync (no restart)
./scripts/sync-containers-and-nginx.sh

# Manual sync and restart
./scripts/sync-containers-and-nginx.sh --restart-nginx
```

**How it works**:

1. Checks all services in the registry
2. Detects which containers are running (blue/green)
3. Updates symlinks to match running containers
4. Starts missing containers if needed
5. Validates nginx configuration
6. Restarts nginx (if requested)

For complete documentation, see:

- **[Blue/Green Deployment Guide](docs/BLUE_GREEN_DEPLOYMENT.md)** - Complete usage guide
- **[Container and Nginx Synchronization Guide](docs/CONTAINER_NGINX_SYNC.md)** - Symlink and container sync details

## Support

For issues and questions, please open an issue on GitHub.
