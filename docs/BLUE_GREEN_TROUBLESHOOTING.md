# Blue/Green Troubleshooting

## Issue 1: "Infrastructure compose file not found"

**Cause**: `docker-compose.infrastructure.yml` missing or shared `database-server` not running.

```bash
# Option A: Start shared database-server (K8s)
kubectl get pods -n statex-apps | grep db-server

# Option B: Check Docker db containers
docker ps | grep -E "postgres|redis"
```

---

## Issue 2: "Nginx configuration test failed"

**Cause**: Nginx config references containers that don't exist or aren't on `nginx-network`.

```bash
# Recommended fix: regenerate configs
./scripts/blue-green/switch-traffic.sh <service>

# Or regenerate from registry
./scripts/blue-green/migrate-to-symlinks.sh <service>

# Verify containers exist
docker ps | grep <service>
docker network inspect nginx-network | grep <service>
```

---

## Issue 3: Nginx container restart loop

**Cause**: Invalid nginx config, port conflict on 80/443, or resource constraints.

```bash
# Run diagnostic
./scripts/diagnose.sh nginx-microservice

# Test config manually
docker compose run --rm nginx nginx -t

# Check port conflicts
docker ps --format "{{.Names}}\t{{.Ports}}" | grep -E ":80|:443"

# Stop loop and investigate
docker stop nginx-microservice
docker logs nginx-microservice
./scripts/restart-nginx.sh
```

---

## Issue 4: Health check failed, rollback triggered

**Cause**: Green deployment failed health checks; traffic auto-rolled back to blue.

```bash
# Check green container logs
docker logs <service>-green

# Check health endpoint
curl http://<service>-green:<port>/health

# Check deployment logs
tail -f logs/blue-green/deploy.log

# Fix issue then retry
../<service>/scripts/deploy.sh
```

Common causes: DB connection failed, missing env vars, port conflict, containers not on `nginx-network`.

---

## Issue 5: State file out of sync

**Cause**: State file shows one color but different color is running.

```bash
# Diagnose
cat state/<service>.json | jq .active_color
docker ps | grep <service>
readlink nginx/conf.d/<domain>.conf

# Fix: use switch-traffic to sync
./scripts/blue-green/switch-traffic.sh <service>
```

---

## Issue 6: HTTPS timeout

**Cause**: SSL cert missing, firewall blocking 443, or nginx config error.

```bash
docker exec nginx-microservice ls -la /etc/nginx/certs/<domain>/

# Ask user to execute sudo commands
sudo ufw status | grep 443
docker compose exec nginx nginx -t
docker compose logs nginx | tail -50
```

---

## Issue 7: Traffic not switching

**Cause**: Symlink not updated or state file stale.

```bash
readlink nginx/conf.d/<domain>.conf
cat state/<service>.json | jq .active_color
./scripts/blue-green/switch-traffic.sh <service>
```

---

## Issue 8: Cleanup failed

Non-critical — deployment succeeded but old containers weren't removed.

```bash
docker compose -f ../<service>/docker-compose.blue.yml -p <project>_blue down
```

---

## Issue 9: Deployment stuck/hanging

**Cause**: Health check timeout, network issues, or resource constraints.

```bash
ps aux | grep deploy-smart.sh
tail -f logs/blue-green/deploy.log
docker logs <service>-green | tail -50

# Kill and retry
pkill -f deploy-smart.sh
docker compose -f docker-compose.green.yml -p <project>_green down
../<service>/scripts/deploy.sh
```

---

## Quick Diagnostic Commands

```bash
# State
cat state/<service>.json | jq .

# Running containers
docker ps | grep <service>

# Nginx symlink
readlink nginx/conf.d/<domain>.conf

# Upstream config
cat nginx/conf.d/<domain>.conf | grep -A 5 upstream

# Deployment log
tail -f logs/blue-green/deploy.log

# Health endpoints
curl http://<service>-blue:<port>/health
curl http://<service>-green:<port>/health
```
