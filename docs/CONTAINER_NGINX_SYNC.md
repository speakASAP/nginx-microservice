# Container and Nginx Synchronization

Nginx is **independent of container state** — it can start and run even when containers are not running (returns 502 until they become available). Configs are generated from the service registry, not from container state.

## Scripts

```bash
./scripts/restart-nginx.sh                          # Recommended: auto-syncs before restart
./scripts/sync-containers-and-nginx.sh              # Sync only (no restart)
./scripts/sync-containers-and-nginx.sh --restart-nginx  # Sync + restart
```

## What sync does

1. Scans all services in the service registry
2. Generates nginx configs from registry → `staging/`
3. Validates each config in isolation with existing valid configs
4. Moves valid configs → `blue-green/`; invalid → `rejected/` (with timestamp)
5. Updates symlinks to match running containers (blue/green state)
6. Optionally reloads nginx

## Symlink logic


| Containers           | Action                                                        |
| -------------------- | ------------------------------------------------------------- |
| Match expected color | Keep symlink as-is                                            |
| Don't match expected | Update symlink to match running containers                    |
| None running         | Keep expected color; nginx returns 502 until containers start |


## Config validation directory structure

```
nginx/conf.d/
├── staging/      # New configs before validation
├── blue-green/   # Validated active configs
├── rejected/     # Invalid configs (debug — timestamped)
└── *.conf        # Symlinks → blue-green/
```

## Troubleshooting

```bash
# Wrong symlink color
./scripts/sync-containers-and-nginx.sh

# Config validation failed
ls -la nginx/conf.d/rejected/
tail -f logs/blue-green/deploy.log

# 502 errors — check if containers running
docker ps | grep <service>
kubectl get pods -n statex-apps | grep <service>   # K8s services
```

