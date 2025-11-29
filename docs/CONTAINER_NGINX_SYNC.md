# Container and Nginx Synchronization

## Overview

The `sync-containers-and-nginx.sh` script ensures that all nginx configuration symlinks point to the correct active containers (blue/green) and generates configs from the service registry. 

**Important**: Nginx is independent of container state - it can start and run even when containers are not running. Nginx will return 502 errors until containers become available, which is acceptable behavior. When containers start, nginx automatically connects to them.

## How It Works

1. **Scans all services** in the service registry
2. **Generates nginx configs** from registry (independent of container state)
3. **Checks which containers are running** (blue, green, or both) - for informational purposes
4. **Updates symlinks** to point to the expected color (from state) or running containers
5. **Optionally starts missing containers** if needed (using deploy-smart.sh) - not required
6. **Validates nginx configuration** (may fail if nginx container is not running, which is acceptable)
7. **Optionally reloads/restarts nginx** if requested

**Key Principle**: Configs are generated from the service registry, not from container state. Nginx can start and run with configs pointing to non-existent containers - it will return 502 errors until containers are available.

## Usage

### Basic Sync (No Restart)

```bash
./scripts/sync-containers-and-nginx.sh
```

This will:

- Check all services
- Update symlinks to match running containers
- Test nginx configuration
- **NOT restart nginx** (safe to run anytime)

### Sync and Restart Nginx

```bash
./scripts/sync-containers-and-nginx.sh --restart-nginx
```

This will:

- Do everything above
- **Restart nginx** after validation

### Automatic Sync Before Nginx Restart

The `restart-nginx.sh` script automatically calls `sync-containers-and-nginx.sh` before restarting:

```bash
./scripts/restart-nginx.sh
```

This ensures containers are running and symlinks are correct before nginx restarts.

## Behavior

### Symlink Logic

1. **If containers match expected color**: Symlink stays as-is ✅
2. **If containers don't match expected color**:
   - If all containers of a color are running → Update symlink to match running containers
   - If partial containers → Keep expected color, optionally try to start missing containers
3. **If no containers running**: Keep expected color, optionally try to start containers

**Note**: Even if no containers are running, nginx will still start successfully. It will return 502 errors until containers become available, which is acceptable behavior.

### Container Detection

The script checks for:

- `{container-base}-blue` containers
- `{container-base}-green` containers  
- `{container-base}` containers (single container, treated as blue)

### Automatic Container Starting

If containers are missing, the script optionally attempts to start them using `deploy-smart.sh`. This is **not required** for nginx to function:

- Missing containers are optionally started automatically (non-blocking)
- Nginx can run without containers (will return 502s until containers are available)
- No manual intervention needed - nginx will connect when containers start

## Integration with Blue/Green Deployment

This script works seamlessly with the blue/green deployment system:

1. **During deployment**: `deploy-smart.sh` starts containers and updates state
2. **Before nginx restart**: `sync-containers-and-nginx.sh` ensures symlinks match running containers
3. **After deployment**: Symlinks automatically point to the correct active color

## Best Practices

1. **Always run sync before restarting nginx manually**:

   ```bash
   ./scripts/sync-containers-and-nginx.sh --restart-nginx
   ```

2. **Use restart-nginx.sh** which automatically syncs:

   ```bash
   ./scripts/restart-nginx.sh
   ```

3. **Run sync after container changes**:

   ```bash
   # After starting/stopping containers manually
   ./scripts/sync-containers-and-nginx.sh
   ```

4. **Check status before sync**:

   ```bash
   ./scripts/status-all-services.sh
   ./scripts/sync-containers-and-nginx.sh
   ```

## Troubleshooting

### Symlink Points to Wrong Color

Run sync to fix:

```bash
./scripts/sync-containers-and-nginx.sh
```

### Containers Not Starting

Check service registry and state:

```bash
cat service-registry/{service-name}.json
cat state/{service-name}.json
```

### Nginx Returns 502 Errors

This is **expected behavior** when containers are not running:

- Nginx can start successfully even if containers are not available
- Nginx will return 502 errors until containers become available
- When containers start, nginx automatically connects to them
- No action needed - just wait for containers to start

To verify nginx is running:

```bash
docker logs nginx-microservice
docker ps | grep nginx-microservice
```

To check if containers are running:

```bash
docker ps | grep {service-name}
```

## Script Output

The script provides detailed output:

- ✅ **Success**: Service synced, symlink correct
- ⚠️ **Warning**: Mismatch detected, attempting to fix
- ❌ **Error**: Failed to sync, manual intervention needed

## Example Output

```text
[INFO] ==========================================
[INFO] Syncing Containers and Nginx Configuration
[INFO] ==========================================
[INFO] Found 8 service(s) to sync

[INFO] ----------------------------------------
[INFO] Syncing service: auth-microservice
[INFO] ----------------------------------------
[SUCCESS] Symlink for auth-microservice is correct (pointing to blue, containers running)
[SUCCESS] Service auth-microservice synced successfully

[INFO] Testing nginx configuration...
[SUCCESS] Nginx configuration is valid
```

## Related Scripts

- `restart-nginx.sh` - Automatically syncs before restarting
- `deploy-smart.sh` - Starts containers and updates state
- `switch-traffic.sh` - Switches traffic between blue/green
- `status-all-services.sh` - Shows current service status
