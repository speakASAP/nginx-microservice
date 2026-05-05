# CLAUDE.md (nginx-microservice)

→ Ecosystem: [../shared/CLAUDE.md](../shared/CLAUDE.md) | Reading order: `BUSINESS.md` → `SYSTEM.md` → `AGENTS.md` → `TASKS.md` → `STATE.json`

---

## nginx-microservice

⚠️ **RETIRED as active proxy** — replaced by Traefik v3 (hostNetwork) in Kubernetes on 2026-05-05.  
This repo is retained as an **archive** of service registry configs, certificate history, and blue/green templates.  
All live traffic now flows through Traefik → K8s ingresses in `statex-apps` namespace.

**Current ingress**: Traefik v3 · TLS via cert-manager + Cloudflare DNS-01 · wildcard `*.alfares.cz`  
**Docker containers**: Stopped and removed. No nginx process is running on ports 80/443.

### What this repo still contains (reference only)
- `service-registry/*.json` — historical per-service routing config
- `nginx/conf.d/` — historical nginx vhost configs
- `scripts/blue-green/` — archived blue/green deploy scripts (no longer used)
- `k8s-rehtani/` — K8s manifests for the rehtani placeholder site

### Do not use for new work
All routing changes must be made via K8s Ingress manifests in each service's `k8s/` directory.  
Traefik reads ingresses from the `statex-apps` namespace automatically on apply.

**Check live ingresses**: `kubectl get ingress -n statex-apps`  
**Check Traefik**: `kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik`
