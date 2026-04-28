# Multi-Application API Routing

Multiple applications can have identical API routes without conflict because nginx routes by **domain first**, then by path within that domain's server block.

## How it works

Each application gets its own domain and nginx server block:

```nginx
server { server_name app1.alfares.cz; /* app1's routes */ }
server { server_name app2.alfares.cz; /* app2's routes */ }
```

Each service has its own `nginx-api-routes.conf` defining which API paths it handles. The same `/api/users` route in two services causes no conflict — they're scoped to different server blocks.

## Request flow

```
POST https://app1.alfares.cz/api/users/123
  → nginx matches server_name app1.alfares.cz
  → matches location /api/users (from app1's nginx-api-routes.conf)
  → proxies to app1-frontend-green container
```

```
POST https://app2.alfares.cz/api/users/123
  → nginx matches server_name app2.alfares.cz
  → matches location /api/users (from app2's nginx-api-routes.conf)
  → proxies to app2-frontend-green container
```

## Config isolation

```
nginx/conf.d/blue-green/
├── app1.alfares.cz.blue.conf   ← app1's upstreams + locations
├── app1.alfares.cz.green.conf
├── app2.alfares.cz.blue.conf   ← app2's upstreams + locations (independent)
└── app2.alfares.cz.green.conf
```

Each config has its own upstream blocks pointing to its own containers — no shared state.

## See also

- [API Routes Registration](API_ROUTES_REGISTRATION.md)
- [Service Registry](SERVICE_REGISTRY.md)
