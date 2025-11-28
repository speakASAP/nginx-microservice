# Container and Nginx Synchronization

## Overview

The `sync-containers-and-nginx.sh` script ensures that all nginx configuration symlinks point to the correct active containers (blue/green) before restarting nginx. This prevents nginx from failing to start due to missing containers.

## How It Works

1. **Scans all services** in the service registry
2. **Checks which containers are running** (blue, green, or both)
3. **Updates symlinks** to point to the color that has running containers
4. **Starts missing containers** if needed (using deploy-smart.sh)
5. **Validates nginx configuration** before restarting
6. **Optionally restarts nginx** if requested

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
   - If partial containers → Keep expected color, try to start missing containers
3. **If no containers running**: Keep expected color, try to start containers

### Container Detection

The script checks for:

- `{container-base}-blue` containers
- `{container-base}-green` containers  
- `{container-base}` containers (single container, treated as blue)

### Automatic Container Starting

If containers are missing, the script attempts to start them using `deploy-smart.sh`. This ensures:

- Missing containers are started automatically
- Services are ready before nginx restart
- No manual intervention needed

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

### Nginx Still Fails After Sync

Check nginx logs:

```bash
docker logs nginx-microservice
```

Verify containers are actually running:

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
