# Container and Nginx Synchronization

## Overview

The `sync-containers-and-nginx.sh` script ensures that all nginx configuration symlinks point to the correct active containers (blue/green) and generates configs from the service registry. 

**Important**: Nginx is independent of container state - it can start and run even when containers are not running. Nginx will return 502 errors until containers become available, which is acceptable behavior. When containers start, nginx automatically connects to them.

## How It Works

1. **Scans all services** in the service registry
2. **Generates nginx configs** from registry to staging directory (independent of container state)
3. **Validates each config** in isolation with existing valid configs to ensure compatibility
4. **Applies validated configs** - only configs that pass validation are moved to blue-green directory
5. **Rejects invalid configs** - invalid configs are moved to rejected directory with timestamps
6. **Checks which containers are running** (blue, green, or both) - for informational purposes
7. **Updates symlinks** to point to the expected color (from state) or running containers
8. **Optionally starts missing containers** if needed (using deploy-smart.sh) - not required
9. **Validates nginx configuration** (may fail if nginx container is not running, which is acceptable)
10. **Optionally reloads/restarts nginx** if requested

**Key Principle**: Configs are generated from the service registry, not from container state. Nginx can start and run with configs pointing to non-existent containers - it will return 502 errors until containers are available.

**Config Validation**: New configs are validated before being applied. If a config would break nginx or conflict with existing configs, it is rejected and nginx continues running with existing valid configs. This ensures that one bad config doesn't affect all services.

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

## Config Validation System

The system includes a robust validation mechanism:

### Directory Structure

```
nginx/conf.d/
├── staging/              # New configs before validation
│   └── {domain}.{color}.conf
├── blue-green/          # Validated configs (active)
│   └── {domain}.{color}.conf
├── rejected/            # Invalid configs (for debugging)
│   └── {domain}.{color}.conf.{timestamp}
└── {domain}.conf        # Symlinks to blue-green configs
```

### Validation Flow

1. **Generate to Staging**: New configs are generated to `staging/` directory
2. **Isolated Test**: Each config is tested with all existing valid configs
3. **Apply if Valid**: Valid configs are moved to `blue-green/` directory
4. **Reject if Invalid**: Invalid configs are moved to `rejected/` directory with timestamps

### Benefits

- **Nginx Always Runs**: Invalid configs are rejected, nginx continues with valid configs
- **Isolated Failures**: One bad config doesn't break all services
- **Debugging**: Rejected configs are saved with timestamps for analysis
- **Automatic**: Validation happens automatically during config generation

### Checking Rejected Configs

If a config is rejected, check the rejected directory:

```bash
ls -la nginx/conf.d/rejected/
cat nginx/conf.d/rejected/{domain}.{color}.conf.{timestamp}
```

Fix the config issue and regenerate the config - it will be validated again.

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

### Config Validation Failed

If a config fails validation:

1. **Check rejected directory**:
   ```bash
   ls -la nginx/conf.d/rejected/
   ```

2. **Review error logs**:
   ```bash
   tail -f logs/blue-green/deploy.log
   ```

3. **Fix the config issue** (syntax error, duplicate server_name, etc.)

4. **Regenerate config** - it will be validated again:
   ```bash
   ./scripts/sync-containers-and-nginx.sh
   ```

**Note**: Nginx continues running with existing valid configs even if new configs fail validation.

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
