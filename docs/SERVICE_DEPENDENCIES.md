# Service Dependencies and Startup Order

## Infrastructure (start first)

### nginx-microservice

- **Runtime**: Docker on host (ports 80/443)
- **Startup**: Phase 1 — always first
- **Network**: Creates `nginx-network`
- **Health**: `nginx -t`

### database-server

- **Runtime**: Kubernetes (`statex-apps` namespace) — `db-server-postgres`, `db-server-redis` (headless ClusterIP)
- **Startup**: Phase 2
- **Health**: `kubectl get pods -n statex-apps | grep db-server`

## Microservices and Applications

All microservices and applications run as **Kubernetes pods** in the `statex-apps` namespace.

```bash
kubectl get svc -n statex-apps    # List all services and ClusterIPs
kubectl get pods -n statex-apps   # Check pod status
```


| Service                                                | K8s ClusterIP | Port |
| ------------------------------------------------------ | ------------- | ---- |
| auth-microservice                                      | 10.43.118.204 | 3370 |
| logging-microservice                                   | 10.43.10.84   | 3367 |
| payments-microservice                                  | 10.43.252.82  | 3468 |
| notifications-microservice                             | 10.43.50.173  | 3368 |
| ai-microservice                                        | 10.43.229.22  | 3380 |
| crypto-ai-agent                                        | 10.43.213.125 | 3000 |
| statex                                                 | 10.43.160.94  | 3000 |
| business-orchestrator                                  | 10.43.129.234 | 3390 |
| *(see `kubectl get svc -n statex-apps` for full list)* |               |      |


## Nginx proxying to K8s services

nginx-microservice (Docker on host) proxies to K8s ClusterIP endpoints. The host machine is a k3s node, so ClusterIPs in the `10.43.x.x` range are reachable from Docker containers via the host network.

## Startup sequence (nginx + Docker services)

```
Phase 1: nginx-microservice (Docker, ports 80/443)
Phase 2: K8s services — managed by Kubernetes scheduler
```

For K8s service dependencies (ordering, health checks), Kubernetes handles pod scheduling and readiness probes automatically.

## Scripts

```bash
./scripts/start-nginx.sh          # Start nginx (Docker)
./scripts/status-all-services.sh  # Check Docker service status
kubectl get pods -n statex-apps   # Check K8s pod status
```

