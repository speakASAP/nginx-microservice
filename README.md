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

### Manual Certificate Operations

```bash
# Request certificate
docker compose run --rm certbot /scripts/request-cert.sh <domain> [email]

# Check certificate expiry
docker compose run --rm certbot /scripts/check-cert-expiry.sh [domain]

# Renew certificates
docker compose run --rm certbot /scripts/renew-cert.sh
```

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

### Certificate Storage

Certificates are stored in two locations:

1. **Host filesystem**: `certificates/<domain>/` (primary storage)
2. **Docker volume**: `/etc/letsencrypt/live/<domain>/` (for certbot access)

### Certificate Request Flow

1. Check if certificate exists locally
2. Check expiration (request if < 30 days)
3. Request via certbot with webroot validation
4. Store in both locations
5. Nginx automatically picks up new certificates

### Certificate Renewal

Certificates are automatically renewed:

- **Systemd**: Daily check via timer
- **Cron**: Daily at 3:00 AM
- **Manual**: Run `docker compose run --rm certbot /scripts/renew-cert.sh`

Renewal triggers nginx reload automatically.

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

### Quick Start

```bash
# Deploy a service (full cycle)
./scripts/blue-green/deploy.sh crypto-ai-agent

# Manual rollback if needed
./scripts/blue-green/rollback.sh crypto-ai-agent

# Check deployment status
cat state/crypto-ai-agent.json | jq .
```

### Features

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

All scripts are in `scripts/blue-green/`:

- `deploy.sh` - Full deployment cycle
- `prepare-green.sh` - Build and start new deployment
- `switch-traffic.sh` - Switch traffic to new color
- `health-check.sh` - Check service health
- `rollback.sh` - Rollback to previous deployment
- `cleanup.sh` - Remove old deployment

See [Blue/Green Deployment Guide](docs/BLUE_GREEN_DEPLOYMENT.md) for detailed usage.

## Support

For issues and questions, please open an issue on GitHub.
