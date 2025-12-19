# Service Dependencies and Startup Order

This document describes the dependency relationships between all services and the correct startup order.

## Service Categories

### 1. Infrastructure Services (No Dependencies)

These services must be started first and have no dependencies on other services:

#### nginx-microservice

- **Purpose**: Reverse proxy for all services
- **Dependencies**: None
- **Startup Order**: 1
- **Network**: Creates `nginx-network`
- **Ports**:
  - **HTTP**: 80 (exposed on host)
  - **HTTPS**: 443 (exposed on host)
- **Health Check**: `nginx -t` (config test)

#### database-server

- **Purpose**: Shared PostgreSQL and Redis infrastructure
- **Dependencies**: None (but requires `nginx-network`)
- **Startup Order**: 2
- **Containers**:
  - `db-server-postgres` (PostgreSQL)
  - `db-server-redis` (Redis)
- **Health Checks**:
  - PostgreSQL: `pg_isready -U dbadmin`
  - Redis: `redis-cli ping`

### 2. Microservices (Depend on Infrastructure Only)

These services depend only on infrastructure (nginx-network, database-server) and can be started in parallel after infrastructure is ready:

#### logging-microservice

- **Purpose**: Centralized logging service
- **Dependencies**: `nginx-network` only
- **Startup Order**: 3 (can start first among microservices)
- **Shared Services**: None
- **Container**: `logging-microservice-blue` / `logging-microservice-green`
- **Host Port**: `${PORT:-3367}` (configured in `logging-microservice/.env`), **Container Port**: `${PORT:-3367}`
- **Health Endpoint**: `/health`

#### auth-microservice

- **Purpose**: Authentication service
- **Dependencies**: `nginx-network`, `db-server-postgres`
- **Startup Order**: 4
- **Shared Services**: `postgres`
- **Container**: `auth-microservice-blue` / `auth-microservice-green`
- **Host Port**: `${PORT:-3370}` (Blue, configured in `auth-microservice/.env`) / 3371 (Green), **Container Port**: `${PORT:-3370}`
- **Health Endpoint**: `/health`

#### payments-microservice

- **Purpose**: Payment processing service
- **Dependencies**: `nginx-network`, `db-server-postgres`
- **Startup Order**: 5
- **Shared Services**: `postgres`
- **Container**: `payments-microservice-blue` / `payments-microservice-green`
- **Host Port**: `${PORT_BLUE:-3369}` / `${PORT_GREEN:-3369}` (configured in `payments-microservice/.env`), **Container Port**: `${SERVICE_PORT:-3468}`
- **Health Endpoint**: `/health`

#### notifications-microservice

- **Purpose**: Notification service
- **Dependencies**: `nginx-network`, `db-server-postgres`, `db-server-redis`
- **Startup Order**: 6
- **Shared Services**: `postgres`, `redis`
- **Container**: `notifications-microservice-blue` / `notifications-microservice-green`
- **Host Port**: `${PORT:-3368}` (configured in `notifications-microservice/.env`), **Container Port**: `${PORT:-3368}`
- **Health Endpoint**: `/health`

#### ai-microservice

- **Purpose**: AI microservice (starts after all other microservices, before applications)
- **Dependencies**: `nginx-network`, `db-server-postgres`, `db-server-redis`
- **Startup Order**: 7 (starts after all other microservices, before applications)
- **Shared Services**: `postgres`, `redis`
- **Container**: `ai-microservice-blue` / `ai-microservice-green`
- **Host Port**: `${PORT:-3371}` (configured in `ai-microservice/.env`), **Container Port**: `${PORT:-3371}`
- **Health Endpoint**: `/health`

### 3. Applications (May Depend on Microservices)

These applications may depend on microservices and should be started after all microservices are running:

#### crypto-ai-agent

- **Purpose**: Crypto AI agent application
- **Dependencies**: `nginx-network`, `db-server-postgres`, `db-server-redis`
- **Startup Order**: 8
- **Shared Services**: `postgres`, `redis`
- **Containers**:
  - `crypto-ai-backend-blue` / `crypto-ai-backend-green` (Port: 3102)
  - `crypto-ai-frontend-blue` / `crypto-ai-frontend-green` (Port: 3100)
- **Health Endpoints**:
  - Backend: `/api/health`
  - Frontend: `/`

#### statex

- **Purpose**: Main statex platform application (consolidated service including all statex components)
- **Dependencies**: `nginx-network`, `db-server-postgres`, `db-server-redis`
- **Startup Order**: 9
- **Shared Services**: `postgres`, `redis`
- **Containers**:
  - `statex-frontend-blue` / `statex-frontend-green` (Port: 3000)
  - `statex-submission-service-blue` / `statex-submission-service-green` (Port: 8000)
  - `statex-user-portal-blue` / `statex-user-portal-green` (Port: 8000)
  - `statex-content-service-blue` / `statex-content-service-green` (Port: 8000)
  - `statex-ai-orchestrator-blue` / `statex-ai-orchestrator-green` (Port: 8000) - AI orchestrator service
  - `statex-api-gateway-blue` / `statex-api-gateway-green` (Port: 80) - API gateway
- **Health Endpoints**:
  - Frontend: `/`
  - Services: `/health`
- **May Depend On**: `auth-microservice`, `notifications-microservice`

#### flipflop

- **Purpose**: flipflop platform (heavy application with 10+ internal services)
- **Dependencies**: `nginx-network`, `db-server-postgres`, `db-server-redis`
- **Startup Order**: 10 (start last due to complexity and startup time)
- **Shared Services**: `postgres`, `redis`
- **Containers**:
  - `flipflop-frontend-blue` / `flipflop-frontend-green` (Port: 3000)
  - `flipflop-api-gateway-blue` / `flipflop-api-gateway-green` (Port: 3011)
  - Plus 10+ internal services (managed by flipflop docker-compose)
- **Health Endpoints**:
  - Frontend: `/`
  - API Gateway: `/health`
- **May Depend On**: `payments-microservice`, `auth-microservice`

## Dependency Graph

```text
┌─────────────────────┐
│  nginx-network      │ (Docker network)
└──────────┬──────────┘
           │
           ├───────────────────────────────────────────┐
           │                                           │
┌──────────▼──────────┐                  ┌─────────────▼─────────────┐
│ nginx-microservice  │                  │   database-server         │
│  (Reverse Proxy)    │                  │   - db-server-postgres    │
└─────────────────────┘                  │   - db-server-redis       │
                                         └───────────────────────────┘
                                                      │
           ┌──────────────────────────────────────────┼──────────────────────────┐
           │                                          │                          │
           │                                          │                          │
┌──────────▼──────────┐                    ┌──────────▼──────────┐    ┌──────────▼──────────┐
│ logging-microservice│                    │  auth-microservice  │    │ payments-microservice│
│ (No DB)             │                    │  (needs postgres)   │    │ (needs postgres)    │
└─────────────────────┘                    └─────────────────────┘    └─────────────────────┘
           │                                          │                          │
           └──────────────────────────────────────────┼──────────────────────────┘
                                                      │
                                                      │
                                                      │
                                           ┌──────────▼──────────┐
                                           │notifications-       │
                                           │microservice         │
                                           │(needs postgres +    │
                                           │redis)               │
                                           └─────────────────────┘
                                                      │
                                           ┌──────────▼──────────┐
                                           │  ai-microservice    │
                                           │  (needs postgres +  │
                                           │  redis)             │
                                           │  (starts after all  │
                                           │  other microservices│
                                           │  before applications)│
                                           └─────────────────────┘
                                                      │
           ┌──────────────────────────────────────────┼────────────────────────┐
           │                                          │                        │
           │                                          │                        │
┌──────────▼──────────┐                    ┌──────────▼──────────┐    ┌───────▼───────────┐
│  crypto-ai-agent    │                    │      statex         │    │    flipflop     │
│  (needs postgres +  │                    │  (consolidated:     │    │  (needs postgres +│
│  redis)             │                    │  frontend,          │    │  redis)           │
└─────────────────────┘                    │  submission,        │    └───────────────────┘
                                           │  user-portal,       │
                                           │  content-service,   │
                                           │  ai-orchestrator,   │
                                           │  api-gateway)       │
                                           │  (needs postgres +  │
                                           │  redis, may need    │
                                           │  auth + notif)      │
                                           └─────────────────────┘
```

## Startup Sequence

### Phase 1: Infrastructure (Order: 1-2)

1. Create `nginx-network` (if not exists)
2. Start `nginx-microservice`
3. Start `database-server` (postgres + redis)
4. Wait for infrastructure health checks

### Phase 2: Microservices (Order: 3-7)

1. Start `logging-microservice` (no dependencies)
2. Start `auth-microservice` (needs postgres)
3. Start `payments-microservice` (needs postgres)
4. Start `notifications-microservice` (needs postgres + redis)
5. Start `ai-microservice` (needs postgres + redis)

### Phase 3: Applications (Order: 8-10)

1. Start `crypto-ai-agent` (needs postgres + redis)
2. Start `statex` (main application - includes frontend, submission-service, user-portal, content-service, ai-orchestrator, api-gateway)
3. Start `flipflop` (heavy application, start last)

## Using the Central Startup Script

The `scripts/start-all-services.sh` script automatically handles the dependency order:

```bash
# Start all services in correct order
./scripts/start-all-services.sh

# Start only infrastructure
./scripts/start-all-services.sh --skip-microservices --skip-applications

# Start only microservices (assumes infrastructure is running)
./scripts/start-all-services.sh --skip-infrastructure --skip-applications

# Start only applications (assumes infrastructure and microservices are running)
./scripts/start-all-services.sh --skip-infrastructure --skip-microservices

# Start a single service (will start dependencies if needed)
./scripts/start-all-services.sh --service logging-microservice
```

## Service Registry Files

Each service has a registry file in `service-registry/` that defines:

- Service name and paths
- Container names
- Ports and health endpoints
- Shared services (postgres, redis)
- Network configuration

## Notes

- **Shared Infrastructure**: `database-server` provides shared PostgreSQL and Redis for all services that need them. This prevents data corruption and ensures consistency.

- **Nginx Upstreams**: All nginx configs are generated from the service registry and use Docker DNS-based container discovery. Configs are generated independently of container state, allowing nginx to start even when containers are not running.

- **Health Checks**: Each service must pass health checks before the next phase starts. This ensures dependencies are ready.

- **Parallel Startup**: Within each phase, services can potentially start in parallel if they don't depend on each other. However, the script starts them sequentially for safety.

- **Rollback**: If any service fails to start, the script continues with other services but logs warnings. Manual intervention may be required.
