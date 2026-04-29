# Adding Microservices

> **New services**: Deploy to Kubernetes (`statex-apps` namespace) — see [../shared/docs/KUBERNETES_SETUP_GUIDE.md](../../shared/docs/KUBERNETES_SETUP_GUIDE.md). The Docker blue/green path below applies to legacy Docker services.

## Overview

1. Ensure service has `docker-compose.blue.yml` / `docker-compose.green.yml`
2. Run `../<service>/scripts/deploy.sh` — registry file is auto-created, DO NOT create it manually
3. Verify deployment

## Service Registry (auto-managed)

Stored in `nginx-microservice/service-registry/<service>.json`. Created/updated by `deploy.sh`. Never commit these files to service repos.

**Minimal registry structure (auto-detected):**

```json
{
  "service_name": "my-microservice",
  "production_path": "~/Documents/Github/my-microservice",
  "domain": "my-service.alfares.cz",
  "docker_compose_file": "docker-compose.blue.yml",
  "docker_project_base": "my_microservice",
  "services": {
    "backend": {
      "container_name_base": "my-microservice",
      "container_port": 3000,
      "health_endpoint": "/health"
    }
  },
  "shared_services": ["postgres"],
  "network": "nginx-network"
}
```

Port auto-detected from `docker-compose.yml` if `container_port` is omitted.

## Docker Requirements

```yaml
services:
  backend:
    container_name: my-microservice-blue
    networks:
      - nginx-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
networks:
  nginx-network:
    external: true
    name: nginx-network
```

## Deploy

```bash
../<service>/scripts/deploy.sh
```

## Verify

```bash
curl https://my-service.alfares.cz/health
ls -la nginx/conf.d/blue-green/<service>.alfares.cz.*.conf
docker ps | grep my-microservice
```

## Troubleshooting


| Problem                 | Check |
| ----------------------- | ----- |
| Service not found       | `ls service-registry/my-microservice.json` |
| Containers not starting | `docker-compose.blue.yml` exists, containers on `nginx-network` |
| Nginx config missing    | `ls nginx/conf.d/rejected/` for validation errors |
| Port not detected       | Add `container_port` to registry or check `docker-compose.yml` has port mappings |

