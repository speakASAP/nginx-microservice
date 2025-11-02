# Blue/Green Deployment Troubleshooting Guide

## Common Issues and Solutions

### Issue 1: "Infrastructure compose file not found"

**Error Message:**

```text
ERROR Infrastructure compose file not found: docker-compose.infrastructure.yml
And shared database-server is not running
Either start database-server or ensure docker-compose.infrastructure.yml exists
```text

**Causes:**

1. `docker-compose.infrastructure.yml` doesn't exist in service directory
2. Shared `database-server` is not running
3. Container names don't match expected values

**Solutions:**

**Option A: Start Shared Database-Server (Recommended)**

```bash
cd /path/to/database-server
./scripts/start.sh

# Verify it's running
docker ps | grep db-server-postgres
docker ps | grep db-server-redis
```text

**Option B: Create Infrastructure File**

```bash
# Copy from local to production
scp crypto-ai-agent/docker-compose.infrastructure.yml \
    statex:/home/statex/crypto-ai-agent/
```text

**Option C: Verify Container Names**

```bash
# Check if containers exist with different names
docker ps --format "{{.Names}}" | grep -E "postgres|redis"

# Update ensure-infrastructure.sh if names differ
```text

---

### Issue 2: "Nginx configuration test failed"

**Error Message:**

```text
nginx: [emerg] host not found in upstream "crypto-ai-frontend-green:3100"
nginx: configuration file /etc/nginx/nginx.conf test failed
```text

**Causes:**

1. Nginx config references containers that don't exist
2. Containers not on `nginx-network`
3. Container names don't match config

**Solutions:**

**A. Fix Using Switch-Traffic Script (Recommended)**

```bash
cd /path/to/nginx-microservice

# This automatically comments out missing containers
./scripts/blue-green/switch-traffic.sh crypto-ai-agent
```text

**B. Manual Fix**

```bash
# Edit nginx config to comment out missing upstreams
cd /path/to/nginx-microservice
vim nginx/conf.d/crypto-ai-agent.statex.cz.conf

# Comment out missing servers:
# server crypto-ai-frontend-green:3100 backup ...;

# Test config
docker compose exec nginx nginx -t

# Reload if test passes
docker compose exec nginx nginx -s reload
```text

**C. Verify Containers Exist**

```bash
# Check running containers
docker ps | grep crypto-ai

# Check network connectivity
docker network inspect nginx-network | grep crypto-ai
```text

---

### Issue 3: "Health check failed, rollback triggered"

**Error Message:**

```text
ERROR Health check failed, rollback already triggered
```text

**What Happened:**

- New deployment (green) failed health checks
- Automatic rollback switched traffic back to blue
- Green containers stopped

**Investigation Steps:**

```bash
# 1. Check green container logs
docker logs crypto-ai-backend-green
docker logs crypto-ai-frontend-green

# 2. Check health endpoints manually
curl http://crypto-ai-backend-green:8100/health
curl http://crypto-ai-frontend-green:3100/

# 3. Check deployment logs
tail -f /path/to/nginx-microservice/logs/blue-green/deploy.log

# 4. Check database connectivity
docker exec crypto-ai-backend-green ping -c 2 db-server-postgres
docker exec crypto-ai-backend-green env | grep DATABASE
```text

**Common Causes:**

1. **Database Connection Failed**
   - Solution: Ensure database-server is running
   - Verify credentials in `.env` file

2. **Application Startup Error**
   - Solution: Check application logs for errors
   - Verify all environment variables are set

3. **Port Conflicts**
   - Solution: Check if ports are already in use
   - Verify docker-compose files use correct ports

4. **Network Issues**
   - Solution: Verify containers are on `nginx-network`
   - Check Docker network: `docker network inspect nginx-network`

**Recovery:**

```bash
# Fix the issue, then retry deployment
./scripts/blue-green/deploy.sh crypto-ai-agent
```text

---

### Issue 4: State File Out of Sync

**Symptoms:**

- State file shows one color active, but different color is actually running
- Nginx config doesn't match running containers

**Detection:**

```bash
# Check state file
cat /path/to/nginx-microservice/state/crypto-ai-agent.json | jq .

# Check actual running containers
docker ps | grep crypto-ai

# Compare with nginx config
cat nginx/conf.d/crypto-ai-agent.statex.cz.conf | grep upstream
```text

**Fix:**

```bash
# Option 1: Use switch-traffic to sync (if colors are correct)
./scripts/blue-green/switch-traffic.sh crypto-ai-agent

# Option 2: Manually update state file
cd /path/to/nginx-microservice
cat > state/crypto-ai-agent.json << 'EOF'
{
  "service_name": "crypto-ai-agent",
  "active_color": "blue",
  "blue": {
    "status": "running",
    "deployed_at": "2025-11-02T08:00:00Z",
    "version": null
  },
  "green": {
    "status": "stopped",
    "deployed_at": null,
    "version": null
  },
  "last_deployment": {
    "color": "blue",
    "timestamp": "2025-11-02T08:00:00Z",
    "success": true
  }
}
EOF

# Then update nginx config
./scripts/blue-green/switch-traffic.sh crypto-ai-agent
```text

---

### Issue 5: HTTPS Connection Timeout

**Symptoms:**

- HTTP (port 80) works and redirects to HTTPS
- HTTPS (port 443) times out or fails
- Internal connectivity works (nginx → frontend returns 200)

**Investigation:**

```bash
# 1. Check nginx status
docker ps | grep nginx-microservice

# 2. Test nginx config
docker compose exec nginx nginx -t

# 3. Test internal connectivity
docker exec nginx-microservice curl http://crypto-ai-frontend-blue:3100/

# 4. Check SSL certificates
docker exec nginx-microservice ls -la /etc/nginx/certs/crypto-ai-agent.statex.cz/

# 5. Check nginx logs
docker compose logs nginx | tail -50

# 6. Test SSL from server
docker exec nginx-microservice curl -k https://localhost/ -H 'Host: crypto-ai-agent.statex.cz'
```text

**Common Causes:**

1. **SSL Certificate Missing or Invalid**

   ```bash
   # Check certificates
   ls -la certificates/crypto-ai-agent.statex.cz/
   
   # Regenerate if needed
   ./scripts/add-domain.sh crypto-ai-agent.statex.cz
   ```text

2. **Firewall Blocking Port 443**

   ```bash
   # Check firewall rules
   sudo iptables -L -n | grep 443
   sudo ufw status | grep 443
   
   # Open port if needed
   sudo ufw allow 443/tcp
   ```text

3. **Nginx Config Error**

   ```bash
   # Fix using switch-traffic script
   ./scripts/blue-green/switch-traffic.sh crypto-ai-agent
   
   # Or manually test and reload
   docker compose exec nginx nginx -t
   docker compose exec nginx nginx -s reload
   ```text

---

### Issue 6: Both Colors Running But Traffic Not Switching

**Symptoms:**

- Both blue and green containers are running
- Traffic always goes to one color
- State file doesn't update

**Investigation:**

```bash
# Check state file
cat state/crypto-ai-agent.json | jq .active_color

# Check nginx config
cat nginx/conf.d/crypto-ai-agent.statex.cz.conf | grep -A 2 upstream

# Verify switch-traffic script ran
tail -20 logs/blue-green/deploy.log | grep switch
```text

**Fix:**

```bash
# Manually switch traffic
./scripts/blue-green/switch-traffic.sh crypto-ai-agent

# Verify nginx config updated
cat nginx/conf.d/crypto-ai-agent.statex.cz.conf | grep weight

# Reload nginx
docker compose exec nginx nginx -s reload
```text

---

### Issue 7: Cleanup Failed

**Error Message:**

```text
WARNING Phase 4 warning: cleanup.sh had issues, but deployment is successful
```text

**What Happened:**

- Deployment succeeded
- Traffic switched correctly
- Old color cleanup failed (non-critical)

**Investigation:**

```bash
# Check what cleanup tried to do
tail -30 logs/blue-green/deploy.log | grep cleanup

# Check if old containers still exist
docker ps | grep crypto-ai

# Manual cleanup
docker compose -f /path/to/crypto-ai-agent/docker-compose.blue.yml \
    -p crypto_ai_agent_blue down

# Or for green
docker compose -f /path/to/crypto-ai-agent/docker-compose.green.yml \
    -p crypto_ai_agent_green down
```text

**Note:** This is a warning, not an error. Deployment succeeded, just need manual cleanup.

---

### Issue 8: Deployment Stuck or Hanging

**Symptoms:**

- Deployment script doesn't complete
- No error messages
- Containers in intermediate state

**Investigation:**

```bash
# Check script is still running
ps aux | grep deploy.sh

# Check container states
docker ps | grep crypto-ai

# Check logs
tail -f logs/blue-green/deploy.log

# Check for health check loops
docker logs crypto-ai-backend-green | tail -50
```text

**Common Causes:**

1. **Health Checks Timing Out**
   - Solution: Increase `startup_time` in service registry
   - Or fix application startup issues

2. **Network Connectivity Issues**
   - Solution: Verify containers can reach each other
   - Check `nginx-network` exists

3. **Resource Constraints**
   - Solution: Check system resources
   - Free up memory/CPU if needed

**Recovery:**

```bash
# Kill stuck deployment
pkill -f deploy.sh

# Clean up intermediate state
docker compose -f docker-compose.green.yml -p crypto_ai_agent_green down

# Retry deployment
./scripts/blue-green/deploy.sh crypto-ai-agent
```text

---

## Diagnostic Commands

### Check Service Status

```bash
# State file
cat state/crypto-ai-agent.json | jq .

# Running containers
docker ps | grep crypto-ai

# Nginx config
cat nginx/conf.d/crypto-ai-agent.statex.cz.conf | grep -A 5 upstream

# Network connectivity
docker network inspect nginx-network | grep crypto-ai
```text

### Check Infrastructure

```bash
# Database-server
docker ps | grep db-server
docker exec db-server-postgres pg_isready
docker exec db-server-redis redis-cli ping

# Or service-specific
docker ps | grep crypto-ai-postgres
docker ps | grep crypto-ai-redis
```text

### Check Logs

```bash
# Deployment logs
tail -f logs/blue-green/deploy.log

# Application logs
docker logs -f crypto-ai-backend-blue
docker logs -f crypto-ai-frontend-green

# Nginx logs
docker compose logs nginx --tail 100 -f
```text

### Test Health Endpoints

```bash
# Backend health
curl http://crypto-ai-backend-blue:8100/health
curl http://crypto-ai-backend-green:8100/health

# Frontend health
curl http://crypto-ai-frontend-blue:3100/
curl http://crypto-ai-frontend-green:3100/
```text

## Getting Help

1. **Check Logs First**: Always review logs before asking for help
2. **Collect Diagnostic Info**: Run diagnostic commands above
3. **Check Documentation**: Review main blue/green deployment guide
4. **Review Recent Changes**: Check git history for recent config changes

## Prevention

### Best Practices

1. **Always Test Before Production**

   ```bash
   ./scripts/blue-green/prepare-green.sh crypto-ai-agent
   ```text

2. **Monitor During Deployment**

   ```bash
   tail -f logs/blue-green/deploy.log
   ```text

3. **Verify Infrastructure Before Deploying**

   ```bash
   cd /path/to/database-server
   ./scripts/status.sh
   ```text

4. **Keep State File Accurate**
   - Don't edit manually
   - Use scripts for all changes
   - Verify after manual container operations

5. **Regular Testing**
   - Test blue/green switch regularly
   - Verify rollback works
   - Test cleanup process
