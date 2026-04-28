# Service Registry

Registry files define how nginx routes traffic to services. Stored in `nginx-microservice/service-registry/<service>.json`.

**DO NOT** create or edit registry files manually. They are auto-created by `../<service>/scripts/deploy.sh`.

## How it works

`../<service>/scripts/deploy.sh` auto-detects service config from:

- `docker-compose.blue.yml` / `docker-compose.green.yml` (Docker services)
- `.env` file
- Running containers and port mappings

Then creates/updates `service-registry/<service-name>.json` and generates nginx configs.

> **K8s services**: Services deployed to Kubernetes (`statex-apps` namespace) do not use docker-compose. Their nginx routing is configured directly via their deploy scripts. Check `kubectl get svc -n statex-apps` for current endpoints.

## Registry file structure

```json
{
  "service_name": "allegro-service",
  "production_path": "/home/statex/allegro-service",
  "domain": "allegro.alfares.cz",
  "docker_compose_file": "docker-compose.green.yml",
  "docker_project_base": "allegro_service",
  "services": {
    "frontend": {
      "container_name_base": "allegro-service-frontend",
      "container_port": 3410,
      "health_endpoint": "/health"
    }
  },
  "domains": {
    "allegro.alfares.cz": { "active_color": "green", "services": ["frontend"] }
  },
  "shared_services": [],
  "network": "nginx-network"
}
```

## View registry

```bash
ls -la service-registry/
cat service-registry/<service>.json
```

## Deploy a service

```bash
./scripts/blue-green/deploy-smart.sh <service-name>
curl https://<domain>/health
```

## Troubleshooting


| Problem              | Check                                                     |
| -------------------- | --------------------------------------------------------- |
| Registry not found   | Run `../<service>/scripts/deploy.sh` — it auto-creates it |
| Nginx config missing | `ls nginx/conf.d/rejected/` for validation errors         |
| Container mismatch   | `docker network inspect nginx-network | grep <service>`   |


