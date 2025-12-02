# Nginx Config Validation & Always-Running Guarantee – Enforcement Plan

## 1. Goals and Scope

- **Primary goal**: Ensure that **every** code path which creates, modifies, or activates nginx configuration files follows the validated staging flow from `IMPLEMENTATION_PLAN_VALIDATION.md`:

  ```text
  Generate Config → Write to conf.d/staging/ → Validate in Isolation → If Valid: Move to conf.d/blue-green/ → Create Symlink → Reload Nginx
                                                                     → If Invalid: Reject and Log Error → Keep Nginx Running
  ```

- **Secondary goals**:
  - Nginx must **always be able to start and stay running**, independent of container state.
  - A **broken new config must never break nginx**; it must be rejected and moved to `conf.d/rejected/`.
  - Existing working services must continue unaffected when a new config is invalid.
  - The behavior and guarantees must be **consistent across all scripts and docs**.

## 2. Current State Summary (from Research)

1. **Blue/Green utilities (`scripts/blue-green/utils.sh`)**
   - Implements `ensure_config_directories()` for `nginx/conf.d/{staging,blue-green,rejected}`.
   - Implements `validate_config_in_isolation()`:
     - Pre-validates configs for empty upstreams and other critical issues.
     - Tests the new config together with all validated configs in a temporary directory inside the nginx container.
     - Treats critical errors (`no servers in upstream`, `duplicate upstream`, etc.) as hard failures.
   - Implements `validate_and_apply_config()`:
     - On success: moves config from `staging` → `blue-green`, logs success.
     - On failure: moves config from `staging` → `rejected` (with timestamp), logs error, keeps nginx running with existing configs.
   - `generate_blue_green_configs()`:
     - Generates blue/green configs to `staging`.
     - Calls `validate_and_apply_config()` for each color.
   - `ensure_blue_green_configs()`:
     - Ensures blue/green configs exist for services/domains, generating via the staging + validation flow when needed.

2. **Sync & symlink management (`scripts/sync-containers-and-nginx.sh`)**
   - For each service:
     - Calls `ensure_blue_green_configs()` (so generation always uses staging + validation).
     - Uses `switch_config_symlink()` to point `nginx/conf.d/<domain>.conf` at validated configs in `blue-green`.
   - If a service’s configs fail validation, it logs the error but continues syncing other services and does not remove existing valid configs.
   - At the end, calls `test_nginx_config()` which is tolerant and does not tear nginx down on failures.

3. **Nginx startup & restart scripts**
   - `scripts/start-nginx.sh`:
     - Ensures `nginx-network` exists.
     - Starts `nginx-microservice` via `docker compose up -d`.
     - Inspects `staging`, `rejected`, and `blue-green` directories and surfaces their state for diagnostics.
     - Enforces zero-tolerance only for nginx itself being down, restarting, or unhealthy (runs `diagnose-nginx-restart.sh` in such cases).
   - `scripts/restart-nginx.sh`:
     - Calls `sync-containers-and-nginx.sh` first (which uses validated configs).
     - Runs `nginx -t` and on failure still attempts reload/restart while preserving validated configs.
   - `scripts/reload-nginx.sh`:
     - Runs `nginx -t`; on failure, still attempts `nginx -s reload` and only fails if reload itself fails.

4. **Diagnostics and orchestration**
   - Diagnostic scripts (`diagnose-nginx-restart.sh`, `diagnose-nginx-502.sh`) only **read** configs and container state; they do not write or activate configs.
   - Startup orchestration scripts (`start-all-services.sh`, `start-infrastructure.sh`, `start-microservices.sh`, `start-applications.sh`, `startup-utils.sh`) delegate nginx handling to the validated paths and do not write config files directly.

5. **Legacy / non-conforming path**
   - `scripts/add-domain.sh`:
     - Writes configs **directly** to `nginx/conf.d/<domain>.conf` using `domain.conf.template`.
     - Immediately runs `nginx -t` and, on success, reloads nginx.
     - This bypasses `staging`, `blue-green`, `rejected`, and the isolation validation functions in `scripts/blue-green/utils.sh`.
     - As a result, a bad config created here could prevent nginx from starting, violating the fail-safe requirement.

## 3. Design Decisions

1. **Single mechanism for all nginx configs**
   - All scripts that create or modify nginx configs must:
     - Generate to `nginx/conf.d/staging/`.
     - Use `validate_and_apply_config()` (and therefore `validate_config_in_isolation()`).
     - Result in active configs living only in `nginx/conf.d/blue-green/` plus a symlink `nginx/conf.d/<domain>.conf`.
   - Direct writes to `nginx/conf.d/*.conf` (outside of symlink creation) are considered **legacy and prohibited**.

2. **Unify `add-domain.sh` with blue/green validation**
   - `add-domain.sh` will be refactored to:
     - Stop writing directly to `nginx/conf.d/<domain>.conf`.
     - Use the **same validation pipeline** as blue/green:
       - Generate a config into `staging` (initially blue-only; green may be either a copy or minimal).
       - Call `validate_and_apply_config()` and, on success, ensure `blue-green` and symlink are in place.
     - Continue to handle certificate provisioning exactly as today.
   - To avoid overcomplicating service registry handling, the first step will **not** auto-create a full blue/green JSON registry entry; instead, the nginx config generation for `add-domain.sh` will use the existing `domain.conf.template` but run through the validation functions and directories.

3. **Guardrails for future scripts**
   - We will introduce a **lightweight validation rule**:
     - Any script writing to `nginx/conf.d/` must either:
       - Source `scripts/blue-green/utils.sh` and use `validate_and_apply_config()` + `switch_config_symlink()`, or
       - Be explicitly documented as **read-only**.
   - This will be documented in `IMPLEMENTATION_PLAN_VALIDATION.md` and referenced from relevant developer docs.

4. **Documentation alignment**
   - `README.md`, `docs/CONTAINER_NGINX_SYNC.md`, and `docs/BLUE_GREEN_DEPLOYMENT.md` already describe the staging/validation system conceptually.
   - After implementation changes, we will:
     - Explicitly call out that **`add-domain.sh` uses the same validation pipeline**.
     - Clarify that any new domain or service config is always validated in isolation before being applied.

## 4. Planned Code Changes (High-Level, No Code Yet)

### 4.1. Refactor `scripts/add-domain.sh` to use staging + validation

1. **Import blue/green utilities**
   - Source `scripts/blue-green/utils.sh` at the top of `add-domain.sh`.
   - This gives access to:
     - `ensure_config_directories()`
     - `validate_and_apply_config()`
     - `reload_nginx()` (if we choose to use it) or at least the validation helpers.

2. **Change config output location and naming**
   - Instead of writing directly to `nginx/conf.d/<DOMAIN>.conf`, `add-domain.sh` will:
     - Write a temporary config to `nginx/conf.d/staging/<DOMAIN>.blue.conf` (or equivalent).
     - For the initial implementation, we can keep using `nginx/templates/domain.conf.template` (non-blue-green template) but adapt naming to fit the staging/validation logic.
   - Active configs after validation must live in `nginx/conf.d/blue-green/<DOMAIN>.blue.conf` and be referenced via a symlink `nginx/conf.d/<DOMAIN>.conf`.

3. **Call validation and apply logic**
   - After generating the staging config, `add-domain.sh` will:
     - Call `validate_and_apply_config()` with:
       - `service_name` – initially set to the domain name or a neutral identifier (e.g. `"custom-domain"`).
       - `domain` – the actual domain string.
       - `color` – `"blue"` for the initial single‑slot deployment.
       - `staging_config_path` – the path to the generated staging file.
     - If validation fails:
       - The config will automatically be moved to `rejected/` with a timestamp.
       - The script will:
         - Print a clear error with location of the rejected file.
         - Exit non‑zero **without attempting to reload nginx**, ensuring existing configs remain untouched.
     - If validation succeeds:
       - `validate_and_apply_config()` will move the config to `blue-green/`.

4. **Ensure symlink is created/updated**
   - After successful validation and application:
     - `add-domain.sh` will call `switch_config_symlink()` to create/update `nginx/conf.d/<DOMAIN>.conf` pointing to `blue-green/<DOMAIN>.blue.conf`.
   - This guarantees that:
     - The new domain uses the validated config.
     - The symlink pattern is consistent with blue/green deployment scripts.

5. **Reload nginx in a safe way**
   - Replace direct `nginx -t` + `nginx -s reload` calls with:
     - Option A: Call `reload_nginx()` from `scripts/blue-green/utils.sh`, which:
       - Automatically tests config, tolerates certain failures, and starts/reloads nginx in a safe way.
     - Option B: Keep a simple `nginx -s reload` but only after validation has succeeded, and avoid failing if `nginx -t` fails for non-critical reasons.
   - The preferred approach is **Option A** to reuse the hardened reload logic.

6. **Preserve and enhance user-facing messages**
   - Keep the existing helpful messages about:
     - Certificates.
     - How to test the domain.
     - Where logs are found.
   - Add explicit notes:
     - That the config was validated in isolation.
     - That invalid configs are automatically moved to `nginx/conf.d/rejected/` and do not impact running nginx.

### 4.2. Audit and harden other scripts (read vs write)

1. **Search for direct writes into `nginx/conf.d/`**
   - Confirm which scripts, if any, other than `add-domain.sh` and blue/green utilities write into:
     - `nginx/conf.d/*.conf`
     - `nginx/conf.d/blue-green/*.conf`
     - `nginx/conf.d/staging/*.conf`
   - For any script that writes configs:
     - Ensure it:
       - Sources `scripts/blue-green/utils.sh`.
       - Writes to `staging`.
       - Uses `validate_and_apply_config()` and `switch_config_symlink()`.
     - If not, refactor it to do so.

2. **Mark read-only scripts**
   - For diagnostic or status scripts that only read configs:
     - Optionally add a short comment at the top stating they are **read-only** with respect to nginx configs.
   - This helps keep future maintenance aligned with the validation contract.

### 4.3. Documentation updates

1. **`IMPLEMENTATION_PLAN_VALIDATION.md`**
   - Update the “Implementation Steps” and/or “Technical Details” to:
     - Explicitly mention that `add-domain.sh` and other config-generating scripts must use the staging + isolation validation flow.
     - Clarify that `nginx/conf.d/<domain>.conf` must always be a symlink pointing into `blue-green/` (for validated configs only).

2. **`README.md`**
   - In the sections “Nginx Independence” and “Nginx Config Validation System”:
     - Add a short note that running `./scripts/add-domain.sh` uses the same validation mechanism and cannot break a running nginx instance.

3. **`docs/CONTAINER_NGINX_SYNC.md` / `docs/BLUE_GREEN_DEPLOYMENT.md`**
   - Where config generation and sync are described, add:
     - A subsection summarizing how ad-hoc domains (via `add-domain.sh`) are also validated through the same pipeline.
     - Cross-links to `IMPLEMENTATION_PLAN_VALIDATION.md`.

## 5. Implementation Checklist

1. Refactor `scripts/add-domain.sh` to **stop writing directly** to `nginx/conf.d/<domain>.conf` and instead generate to `nginx/conf.d/staging/`.
2. Wire `scripts/add-domain.sh` to **source** `scripts/blue-green/utils.sh` and call `ensure_config_directories()`.
3. Update `scripts/add-domain.sh` to call `validate_and_apply_config()` for the generated staging config, with appropriate `service_name`, `domain`, and `color` parameters.
4. Ensure that on validation failure in `add-domain.sh`, the script exits non-zero **without** attempting to reload nginx, and clearly prints the rejected config path.
5. Ensure that on validation success in `add-domain.sh`, the config is present in `nginx/conf.d/blue-green/` and marked as validated in logs.
6. Update `scripts/add-domain.sh` to call `switch_config_symlink()` so that `nginx/conf.d/<domain>.conf` always points to a validated config in `blue-green/`.
7. Replace direct `nginx -t` / `nginx -s reload` calls in `scripts/add-domain.sh` with a call to `reload_nginx()` from `scripts/blue-green/utils.sh` (or an equivalent safe wrapper).
8. Re-scan all scripts for any remaining direct writes to `nginx/conf.d/*.conf` and refactor them to use the staging + validation + blue-green + symlink flow if found.
9. For diagnostic/status scripts that only read configs, add clarifying comments that they are read-only with respect to nginx configs (no writes).
10. Update `IMPLEMENTATION_PLAN_VALIDATION.md` to explicitly state that **all** nginx config writers must use the staging + isolation validation flow, including `add-domain.sh`.
11. Update `README.md` to document that `add-domain.sh` now uses the safe validation system and cannot break a running nginx instance.
12. Update `docs/CONTAINER_NGINX_SYNC.md` and `docs/BLUE_GREEN_DEPLOYMENT.md` to mention that ad-hoc domain additions follow the same validation guarantees.
13. After implementation, run `add-domain.sh` in a controlled environment with:
    - A valid config (should be accepted and applied).
    - An invalid config (should be rejected and moved to `rejected/`, nginx keeps running).
14. Verify that all blue/green deployment and sync flows still work as documented and continue to respect the “nginx always runs” and “validated-before-apply” guarantees.
