# Blue/Green Deployment Troubleshooting Guide

## Common Issues and Solutions

### Issue 1: "Infrastructure compose file not found"

**Error Message:**

```text
ERROR Infrastructure compose file not found: docker-compose.infrastructure.yml
And shared database-server is not running
Either start database-server or ensure docker-compose.infrastructure.yml exists
```

**Causes:**

1. `docker-compose.infrastructure.yml` doesn't exist in service directory
2. Shared `database-server` is not running
3. Container names don't match expected values

**Solutions:**

#### **Option A: Start Shared Database-Server (Recommended)**

```bash
cd /path/to/database-server
./scripts/start.sh

# Verify it's running
docker ps | grep db-server-postgres
docker ps | grep db-server-redis
```

#### **Option B: Create Infrastructure File**

```bash
# Copy from local to production
scp crypto-ai-agent/docker-compose.infrastructure.yml \
    statex:/home/statex/crypto-ai-agent/
```

#### **Option C: Verify Container Names**

```bash
# Check if containers exist with different names
docker ps --format "{{.Names}}" | grep -E "postgres|redis"

# Update ensure-infrastructure.sh if names differ
```

---

### Issue 2: "Nginx configuration test failed"

**Error Message:**

```text
nginx: [emerg] host not found in upstream "crypto-ai-frontend-green:3100"
nginx: configuration file /etc/nginx/nginx.conf test failed
```

**Causes:**

1. Nginx config references containers that don't exist
2. Containers not on `nginx-network`
3. Container names don't match config

**Solutions:**

#### **A. Fix Using Switch-Traffic Script (Recommended)**

```bash
cd /path/to/nginx-microservice

# This automatically ensures configs exist and switches symlink
./scripts/blue-green/switch-traffic.sh crypto-ai-agent
```

#### **B. Regenerate Configs**

```bash
# Regenerate blue and green configs from template (validated via staging → blue-green pipeline)
cd /path/to/nginx-microservice
./scripts/blue-green/migrate-to-symlinks.sh crypto-ai-agent

# This will regenerate configs based on current service registry
# using the staging + isolated validation + blue/green + symlink pipeline
# and ensure the symlink points to the correct active color without breaking nginx
```

#### **C. Verify Containers Exist**

```bash
# Check running containers
docker ps | grep crypto-ai

# Check network connectivity
docker network inspect nginx-network | grep crypto-ai
```

---

### Issue 3: "Nginx container restart loop"

**Error Message:**

```text
Error response from daemon: Container is restarting, wait until the container is running
nginx-microservice started but config test ✗ failed after 15 attempts
```

**Causes:**

1. Invalid nginx configuration (syntax errors, missing upstreams)
2. Port conflicts (ports 80/443 already in use)
3. Health check failures in docker-compose.yml
4. Resource constraints (memory/CPU limits)
5. Dependency issues (certbot not ready, network not available)

**Solutions:**

#### **A. Run Diagnostic Script (Recommended)**

The diagnostic script automatically identifies the root cause:

```bash
cd /path/to/nginx-microservice

# Run diagnostic (generic tool for all containers)
./scripts/diagnose.sh nginx-microservice

# Or with specific check type
./scripts/diagnose.sh nginx-microservice --check restart
./scripts/diagnose.sh nginx-microservice --check health
```

The diagnostic script will:

- Check container status (running/restarting/stopped)
- Show container logs (last 50 lines)
- Test nginx configuration (even if container is restarting)
- Check for port conflicts
- Verify volume mounts and network connectivity
- Provide actionable fix recommendations

#### **B. Fix Nginx Configuration Errors**

If the diagnostic shows invalid nginx configuration:

```bash
# Test config manually
docker compose run --rm nginx nginx -t

# Check specific config files
ls -la nginx/conf.d/

# Fix errors in config files, then restart
./scripts/restart-nginx.sh
```

#### **C. Fix Port Conflicts**

```bash
# Check what's using ports 80/443
docker ps --format "{{.Names}}\t{{.Ports}}" | grep -E ":80|:443"

# Stop conflicting containers
docker stop <container-name>
docker rm <container-name>

# Restart nginx
./scripts/restart-nginx.sh
```

#### **D. Stop Restart Loop and Investigate**

```bash
# Stop the restarting container
docker stop nginx-microservice

# Check logs
docker logs nginx-microservice

# Test config in temporary container
docker compose run --rm nginx nginx -t

# Fix issues, then restart
./scripts/restart-nginx.sh
```

**Prevention:**

The health check in `start-all-services.sh` now automatically:

- Detects restarting containers before attempting `docker exec`
- Waits and retries if container is restarting
- Stops container and tests config if restart loop persists
- Provides clear error messages with diagnostic script suggestions

---

### Issue 4: "Health check failed, rollback triggered"

**Error Message:**

```text
ERROR Health check failed, rollback already triggered
```

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
```

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
./scripts/blue-green/deploy-smart.sh crypto-ai-agent
```

---

### Issue 5: State File Out of Sync

**Symptoms:**

- State file shows one color active, but different color is actually running
- Nginx config doesn't match running containers

**Detection:**

```bash
# Check state file
cat /path/to/nginx-microservice/state/crypto-ai-agent.json | jq .

# Check actual running containers
docker ps | grep crypto-ai

# Check symlink (points to active color)
readlink nginx/conf.d/crypto-ai-agent.statex.cz.conf

# Compare with nginx config (active config)
cat nginx/conf.d/crypto-ai-agent.statex.cz.conf | grep upstream
```

**Fix:**

```bash
# Option 1: Use switch-traffic to sync (if colors are correct)
./scripts/blue-green/switch-traffic.sh crypto-ai-agent

# Option 2: Manually update state file, then switch symlink
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

# Then switch symlink to match state
./scripts/blue-green/switch-traffic.sh crypto-ai-agent
```

---

### Issue 6: HTTPS Connection Timeout

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
```

**Common Causes:**

1. **SSL Certificate Missing or Invalid**

   ```bash
   # Check certificates
   ls -la certificates/crypto-ai-agent.statex.cz/
   
   # Regenerate nginx config for the domain using validated pipeline
   ./scripts/add-domain.sh crypto-ai-agent.statex.cz
   # This writes a config into nginx/conf.d/staging/, validates it in isolation with existing configs,
   # promotes it to nginx/conf.d/blue-green/ on success, and sends invalid configs to nginx/conf.d/rejected/
   # without breaking a running nginx instance.
   ```

2. **Firewall Blocking Port 443**

   ```bash
   # Check firewall rules
   sudo iptables -L -n | grep 443
   sudo ufw status | grep 443
   
   # Open port if needed
   sudo ufw allow 443/tcp
   ```

3. **Nginx Config Error**

   ```bash
   # Fix using switch-traffic script
   ./scripts/blue-green/switch-traffic.sh crypto-ai-agent
   
   # Or manually test and reload
   docker compose exec nginx nginx -t
   docker compose exec nginx nginx -s reload
   ```

---

### Issue 7: Both Colors Running But Traffic Not Switching

**Symptoms:**

- Both blue and green containers are running
- Traffic always goes to one color
- State file doesn't update

**Investigation:**

```bash
# Check state file
cat state/crypto-ai-agent.json | jq .active_color

# Check nginx config symlink
readlink nginx/conf.d/crypto-ai-agent.statex.cz.conf

# Check active config upstream blocks
cat nginx/conf.d/crypto-ai-agent.statex.cz.conf | grep -A 2 upstream

# Verify switch-traffic script ran
tail -20 logs/blue-green/deploy.log | grep switch
```

**Fix:**

```bash
# Manually switch traffic (updates symlink)
./scripts/blue-green/switch-traffic.sh crypto-ai-agent

# Verify symlink points to correct color
readlink nginx/conf.d/crypto-ai-agent.statex.cz.conf

# Verify active color in config
cat nginx/conf.d/crypto-ai-agent.statex.cz.conf | grep weight

# Nginx reload is automatic, but you can verify
docker compose exec nginx nginx -s reload
```

---

### Issue 8: Cleanup Failed

**Error Message:**

```text
WARNING Phase 4 warning: cleanup.sh had issues, but deployment is successful
```

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
```

**Note:** This is a warning, not an error. Deployment succeeded, just need manual cleanup.

---

### Issue 9: Deployment Stuck or Hanging

**Symptoms:**

- Deployment script doesn't complete
- No error messages
- Containers in intermediate state

**Investigation:**

```bash
# Check script is still running
ps aux | grep deploy-smart.sh

# Check container states
docker ps | grep crypto-ai

# Check logs
tail -f logs/blue-green/deploy.log

# Check for health check loops
docker logs crypto-ai-backend-green | tail -50
```

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
pkill -f deploy-smart.sh

# Clean up intermediate state
docker compose -f docker-compose.green.yml -p crypto_ai_agent_green down

# Retry deployment
./scripts/blue-green/deploy-smart.sh crypto-ai-agent
```

---

## Diagnostic Commands

### Check Service Status

```bash
# State file
cat state/crypto-ai-agent.json | jq .

# Running containers
docker ps | grep crypto-ai

# Nginx config symlink
readlink nginx/conf.d/crypto-ai-agent.statex.cz.conf

# Active config upstream blocks
cat nginx/conf.d/crypto-ai-agent.statex.cz.conf | grep -A 5 upstream

# Network connectivity
docker network inspect nginx-network | grep crypto-ai
```

### Check Infrastructure

```bash
# Database-server
docker ps | grep db-server
docker exec db-server-postgres pg_isready
docker exec db-server-redis redis-cli ping

# Or service-specific
docker ps | grep crypto-ai-postgres
docker ps | grep crypto-ai-redis
```

### Check Logs

```bash
# Deployment logs
tail -f logs/blue-green/deploy.log

# Application logs
docker logs -f crypto-ai-backend-blue
docker logs -f crypto-ai-frontend-green

# Nginx logs
docker compose logs nginx --tail 100 -f
```

### Test Health Endpoints

```bash
# Backend health
curl http://crypto-ai-backend-blue:8100/health
curl http://crypto-ai-backend-green:8100/health

# Frontend health
curl http://crypto-ai-frontend-blue:3100/
curl http://crypto-ai-frontend-green:3100/
```

## Getting Help

1. **Check Logs First**: Always review logs before asking for help
2. **Collect Diagnostic Info**: Run diagnostic commands above
3. **Check Documentation**: Review main blue/green deployment guide
4. **Review Recent Changes**: Check git history for recent config changes

## Prevention

### Best Practices

1. **Always Test Before Production**

   ```bash
   ./scripts/blue-green/prepare-green-smart.sh crypto-ai-agent
   ```

2. **Monitor During Deployment**

   ```bash
   tail -f logs/blue-green/deploy.log
   ```

3. **Verify Infrastructure Before Deploying**

   ```bash
   cd /path/to/database-server
   ./scripts/status.sh
   ```

4. **Keep State File Accurate**
   - Don't edit manually
   - Use scripts for all changes
   - Verify after manual container operations

5. **Regular Testing**
   - Test blue/green switch regularly
   - Verify rollback works
   - Test cleanup process
