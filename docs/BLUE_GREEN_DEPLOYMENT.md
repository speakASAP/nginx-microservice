# Blue/Green Deployment

Zero-downtime deployments by running two environments (blue/green). Only one receives live traffic at a time, switched via nginx config symlinks.

> **Scope**: nginx-microservice itself uses blue/green Docker containers. K8s services in `statex-apps` use Kubernetes rolling updates instead.

## Config Structure

Each domain has two nginx configs + a symlink:

```
nginx/conf.d/blue-green/
├── crypto-ai-agent.alfares.cz.blue.conf   ← blue config
├── crypto-ai-agent.alfares.cz.green.conf  ← green config
└── crypto-ai-agent.alfares.cz.conf        ← symlink → active color
```

## Upstream Blocks

```nginx
# blue.conf — blue gets all traffic
upstream crypto-ai-frontend {
    server crypto-ai-frontend-blue:3100 weight=100;
    server crypto-ai-frontend-green:3100 backup;
}

# green.conf — green gets all traffic
upstream crypto-ai-frontend {
    server crypto-ai-frontend-blue:3100 backup;
    server crypto-ai-frontend-green:3100 weight=100;
}
```

Switching updates the symlink and reloads nginx (graceful, no dropped connections).

## Scripts

```bash
../<service>/scripts/deploy.sh                    # Full cycle (recommended)
./scripts/blue-green/switch-traffic.sh <service>  # Switch only
./scripts/blue-green/rollback.sh <service>        # Rollback
./scripts/blue-green/health-check.sh <color>      # Check health
```

## Config Validation Pipeline

New configs go through: `staging/` → isolated test → `blue-green/` (valid) or `rejected/` (invalid). Nginx never breaks due to a bad config — invalid configs are rejected and nginx continues with existing valid configs.

## Container Naming

- Blue: `{service-name}-blue`
- Green: `{service-name}-green`

All containers must be on `nginx-network` (external Docker network).

## Verify Deployment

```bash
ls -la nginx/conf.d/<domain>.conf       # Check symlink
cat nginx/conf.d/<domain>.conf | grep upstream  # Check active color
curl https://<domain>/health            # Test endpoint
```

## Rollback

```bash
./scripts/blue-green/rollback.sh <service>
# Or manually:
cd nginx/conf.d && ln -sf blue-green/<domain>.blue.conf <domain>.conf
docker exec nginx-microservice nginx -s reload
```

## Troubleshooting


| Problem            | Fix                                                                      |
| ------------------ | ------------------------------------------------------------------------ |
| 502 after switch   | `docker ps | grep <service>` — containers running? Check `nginx-network` |
| Config not applied | `ls nginx/conf.d/rejected/` — validation failed?                         |
| Rollback fails     | Manually update symlink (see above)                                      |


