# System: nginx-microservice

⚠️ **RETIRED** — replaced by Traefik v3 in Kubernetes (2026-05-05).

## Current ingress architecture

- **Ingress controller**: Traefik v3 Helm chart, `hostNetwork: true`, ports 80/443
- **TLS**: cert-manager + Cloudflare DNS-01 → wildcard `*.alfares.cz` (Let's Encrypt)
- **Ingresses**: 31 ingresses in `statex-apps` namespace
- **Namespace**: `kube-system` (Traefik pod)

## Quick ops

```bash
# Check Traefik
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik

# List all ingresses
kubectl get ingress -n statex-apps

# View a specific ingress
kubectl get ingress <service-name> -n statex-apps -o yaml

# Traefik logs
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik -f
```

## Archived content

This repo contains historical nginx configs and service registry entries from the Docker-era proxy.  
They are not used in production. New routing is defined in each service's `k8s/ingress.yaml`.

## Current State
Stage: archived — no longer active in production
