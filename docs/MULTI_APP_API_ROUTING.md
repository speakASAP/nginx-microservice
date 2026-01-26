# Multi-Application API Routing

**Date:** 2026-01-26  
**Question:** How does nginx-microservice handle multiple applications with the same API routes?  
**Answer:** Domain-based routing with per-service configuration

---

## How It Works

### Domain-Based Routing

Each application has its **own domain** and gets its **own nginx server block**:

```nginx
# app1.statex.cz
server {
    server_name app1.statex.cz www.app1.statex.cz;
    # ... app1's routes ...
}

# app2.statex.cz
server {
    server_name app2.statex.cz www.app2.statex.cz;
    # ... app2's routes ...
}

# app3.statex.cz
server {
    server_name app3.statex.cz www.app3.statex.cz;
    # ... app3's routes ...
}
```

### Per-Service API Route Configuration

Each service has its **own** `nginx-api-routes.conf` file that defines which API routes it handles:

**app1/nginx/nginx-api-routes.conf:**
```
/api/users
/api/users/collect-contact
```

**app2/nginx/nginx-api-routes.conf:**
```
/api/users
/api/users/collect-contact
```

**app3/nginx/nginx-api-routes.conf:**
```
/api/users
/api/users/collect-contact
```

### Service Registry Isolation

Each service has its **own service registry entry** with its own API routes:

**service-registry/app1-service.json:**
```json
{
  "service_name": "app1-service",
  "domain": "app1.statex.cz",
  "frontend_api_routes": [
    "/api/users",
    "/api/users/collect-contact"
  ]
}
```

**service-registry/app2-service.json:**
```json
{
  "service_name": "app2-service",
  "domain": "app2.statex.cz",
  "frontend_api_routes": [
    "/api/users",
    "/api/users/collect-contact"
  ]
}
```

---

## Request Flow Example

### Request: `POST https://app1.statex.cz/api/users/test-user-123/submissions`

1. **Nginx receives request**
   - Host header: `app1.statex.cz`
   - Path: `/api/users/test-user-123/submissions`

2. **Domain matching**
   - Nginx matches `server_name app1.statex.cz`
   - Uses app1's server block configuration

3. **Location matching (within app1's server block)**
   - Nginx matches `location /api/users` (from app1's nginx-api-routes.conf)
   - Routes to app1's frontend container: `app1-frontend-green`

4. **Container receives request**
   - Request goes to: `http://app1-frontend-green/api/users/test-user-123/submissions`
   - App1's Next.js handles the route

### Request: `POST https://app2.statex.cz/api/users/test-user-123/submissions`

1. **Nginx receives request**
   - Host header: `app2.statex.cz`
   - Path: `/api/users/test-user-123/submissions`

2. **Domain matching**
   - Nginx matches `server_name app2.statex.cz`
   - Uses app2's server block configuration

3. **Location matching (within app2's server block)**
   - Nginx matches `location /api/users` (from app2's nginx-api-routes.conf)
   - Routes to app2's frontend container: `app2-frontend-green`

4. **Container receives request**
   - Request goes to: `http://app2-frontend-green/api/users/test-user-123/submissions`
   - App2's Next.js handles the route

---

## Key Points

### ✅ Isolation

- **Each domain = separate server block** = complete isolation
- **Each service = separate nginx config file** = no conflicts
- **Each service = separate container** = no interference

### ✅ Same Routes, Different Apps

Multiple applications can have the same API routes because:
- Routes are scoped to their domain's server block
- Each app's routes point to its own containers
- No global route conflicts

### ✅ Automatic Configuration

- `deploy-smart.sh` reads each service's `nginx-api-routes.conf`
- Generates service-specific location blocks
- Creates separate nginx config files per domain

---

## Generated Nginx Config Structure

```
nginx/conf.d/blue-green/
├── app1.statex.cz.blue.conf      ← app1's config
├── app1.statex.cz.green.conf
├── app2.statex.cz.blue.conf      ← app2's config
├── app2.statex.cz.green.conf
├── app3.statex.cz.blue.conf      ← app3's config
└── app3.statex.cz.green.conf
```

Each config file contains:
- Domain-specific `server_name`
- Service-specific upstream blocks
- Service-specific location blocks (from that service's nginx-api-routes.conf)

---

## Why the Fix Helps

The fix (adding trailing slash to `proxy_pass`) is needed for **all applications** that use dynamic routes:

### Without Fix (Current - Broken)

```nginx
# app1.statex.cz
location /api/users {
    proxy_pass http://app1-frontend-green/api/users;    ← Strips sub-path
}
```

**Request:** `/api/users/test-user-123/submissions`  
**Proxied to:** `http://app1-frontend-green/api/users` (sub-path lost)  
**Result:** ❌ Route doesn't match, returns 404

### With Fix (After - Working)

```nginx
# app1.statex.cz
location /api/users {
    proxy_pass http://app1-frontend-green/api/users/;    ← Preserves sub-path
}
```

**Request:** `/api/users/test-user-123/submissions`  
**Proxied to:** `http://app1-frontend-green/api/users/test-user-123/submissions` (sub-path preserved)  
**Result:** ✅ Route matches, returns JSON

---

## Impact of the Fix

### ✅ Benefits All Applications

The fix in `nginx-microservice/scripts/common/config.sh` will:
- Apply to **all services** that use `/api/users` with dynamic routes
- Fix the path preservation issue for **all applications**
- Work correctly for **app1, app2, app3, etc.**

### ✅ No Conflicts

- Each app still has its own domain
- Each app still routes to its own containers
- The fix only changes how sub-paths are preserved (doesn't affect routing logic)

---

## Summary

**How nginx-microservice handles multiple apps with same routes:**
1. ✅ **Domain-based routing** - Each app has its own domain and server block
2. ✅ **Per-service config** - Each app has its own `nginx-api-routes.conf`
3. ✅ **Service registry isolation** - Each app has its own registry entry
4. ✅ **Separate containers** - Each app routes to its own containers

**Will the fix help?**
- ✅ **Yes!** The fix preserves sub-paths for dynamic routes
- ✅ **Applies to all apps** - Any app using `/api/users` with dynamic routes will benefit
- ✅ **No conflicts** - Each app's routes are still isolated by domain

---

## Related Documentation

- [API Routes Registration](API_ROUTES_REGISTRATION.md)
- [API Route Path Preservation Fix](API_ROUTE_PATH_PRESERVATION_FIX.md)
- [Service Registry](SERVICE_REGISTRY.md)
