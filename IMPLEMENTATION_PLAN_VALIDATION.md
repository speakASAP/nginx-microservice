# Nginx Config Validation System - Implementation Plan

## Goal

Implement a system where nginx always runs independently of container state, and new service configs are validated BEFORE being applied. If a new config would break nginx, it should be rejected and existing working services should continue unaffected.

## Key Principles

1. **Nginx Always Runs**: Nginx should start and run even if some configs are invalid
2. **Isolated Validation**: New configs are tested in isolation before being applied
3. **Fail-Safe**: Invalid configs are rejected and never affect running nginx
4. **Backward Compatible**: Existing working configs continue to work

## Architecture Changes

### Current Flow

```text
Generate Config → Write to conf.d/blue-green/ → Create Symlink → Test All Configs → Reload Nginx
```

### New Flow

```text
Generate Config → Write to conf.d/staging/ → Validate in Isolation → If Valid: Move to conf.d/blue-green/ → Create Symlink → Reload Nginx
                                                                   → If Invalid: Reject and Log Error → Keep Nginx Running
```

## Implementation Steps

### 1. Create Staging Directory Structure

**File**: `scripts/blue-green/utils.sh`

- Add staging directory: `nginx/conf.d/staging/`
- Add rejected directory: `nginx/conf.d/rejected/` (for logging/debugging)
- Ensure directories exist in initialization

### 2. Implement Isolated Config Validation Function

**File**: `scripts/blue-green/utils.sh`

**New Function**: `validate_config_in_isolation()`

- Parameters: `service_name`, `domain`, `config_file_path`
- Steps:
  1. Check if nginx container is running (if not, start it)
  2. Create temporary test directory
  3. Copy all existing valid configs to test directory
  4. Copy new config to test directory
  5. Test nginx config with test directory
  6. Clean up test directory
  7. Return success/failure

**Key**: This function tests the new config WITH existing configs to ensure compatibility, but if it fails, the new config is rejected and nginx continues with existing configs.

### 3. Implement Safe Config Application Function

**File**: `scripts/blue-green/utils.sh`

**New Function**: `validate_and_apply_config()`

- Parameters: `service_name`, `domain`, `staging_config_path`, `target_config_path`
- Steps:
  1. Validate config in isolation using `validate_config_in_isolation()`
  2. If validation passes:
     - Move config from staging to blue-green directory
     - Create/update symlink
     - Log success
     - Return 0
  3. If validation fails:
     - Move config to rejected directory with timestamp
     - Log error with details
     - Keep existing configs unchanged
     - Return 1

### 4. Modify Config Generation Function

**File**: `scripts/blue-green/utils.sh`

**Modify**: `generate_blue_green_configs()`

- Change output directory from `conf.d/blue-green/` to `conf.d/staging/`
- After generation, call `validate_and_apply_config()` for each config (blue and green)
- Only move to `blue-green/` if validation passes

### 5. Update Config Ensure Function

**File**: `scripts/blue-green/utils.sh`

**Modify**: `ensure_blue_green_configs()`

- Check if configs exist in `blue-green/` directory
- If missing, generate to staging and validate
- Only proceed if validation passes

### 6. Update Sync Script

**File**: `scripts/sync-containers-and-nginx.sh`

**Modify**: `sync_service_symlink()`

- When generating configs, use new validation flow
- If validation fails for a service, log error but continue with other services
- Don't fail entire sync if one service config is invalid

### 7. Update Nginx Test Function

**File**: `scripts/blue-green/utils.sh`

**Modify**: `test_nginx_config()`

- Make it more resilient: if nginx container is not running, try to start it
- If config test fails, log error but don't prevent nginx from running
- Add option to test with specific config directory

### 8. Update Restart Script

**File**: `scripts/restart-nginx.sh`

**Modify**:

- Ensure nginx always starts, even if some configs are invalid
- If config test fails, log warning but still attempt to start nginx
- Nginx will fail to start if ALL configs are invalid, but should start if only some are invalid

### 9. Add Config Cleanup Function

**File**: `scripts/blue-green/utils.sh`

**New Function**: `cleanup_rejected_configs()`

- Remove old rejected configs (older than 7 days)
- Can be called periodically or manually

### 10. Update Documentation

**Files**:

- `README.md`
- `docs/CONTAINER_NGINX_SYNC.md`
- `docs/BLUE_GREEN_DEPLOYMENT.md`

**Updates**:

- Document new validation system
- Explain staging/rejected directories
- Update troubleshooting section
- Add examples of validation failures

## Technical Details

### Staging Directory Structure

```text
nginx/conf.d/
├── staging/              # New configs before validation
│   └── {domain}.{color}.conf
├── blue-green/          # Validated configs (active)
│   └── {domain}.{color}.conf
├── rejected/            # Invalid configs (for debugging)
│   └── {domain}.{color}.conf.{timestamp}
└── {domain}.conf        # Symlinks to blue-green configs
```

### Validation Logic

1. **Isolated Test**: Test new config with all existing valid configs
2. **Compatibility Check**: Ensure new config doesn't conflict with existing configs
3. **Syntax Check**: Ensure nginx can parse the config
4. **Safe Application**: Only apply if all checks pass

### Error Handling

- Invalid configs are moved to `rejected/` directory
- Error is logged with full details
- Nginx continues running with existing valid configs
- User is notified of validation failure

## Testing Strategy

1. **Test Valid Config**: Generate valid config, should pass validation and be applied
2. **Test Invalid Config**: Generate invalid config (syntax error), should be rejected
3. **Test Conflicting Config**: Generate config that conflicts with existing (duplicate server_name), should be rejected
4. **Test Nginx Independence**: Stop all containers, nginx should still start
5. **Test Partial Failure**: One invalid config shouldn't prevent other valid configs from being applied

## Rollback Plan

If issues arise:

1. Remove staging/rejected directories
2. Revert to direct generation to blue-green directory
3. Existing configs remain unchanged

## Implementation Checklist

- [ ] Create staging directory structure
- [ ] Implement `validate_config_in_isolation()` function
- [ ] Implement `validate_and_apply_config()` function
- [ ] Modify `generate_blue_green_configs()` to use staging
- [ ] Update `ensure_blue_green_configs()` to use validation
- [ ] Update `sync_service_symlink()` to handle validation failures gracefully
- [ ] Make `test_nginx_config()` more resilient
- [ ] Update `restart-nginx.sh` to ensure nginx always starts
- [ ] Add `cleanup_rejected_configs()` function
- [ ] Update documentation
- [ ] Test with valid configs
- [ ] Test with invalid configs
- [ ] Test with conflicting configs
- [ ] Test nginx independence from containers
