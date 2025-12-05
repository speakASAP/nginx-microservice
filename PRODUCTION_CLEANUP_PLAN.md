# Production Docker Cleanup Plan

## Objective
Connect to production server, stop and delete all containers, then run Docker prune commands to free disk space.

## Implementation Plan

### Step 1: Connect to Production
- SSH to production server using `ssh statex`
- Verify connection and current directory
- Check Docker status

### Step 2: Stop All Containers
- Stop all running containers using `docker stop $(docker ps -q)` or use existing `stop-all-services.sh` script if available
- Force kill any containers that don't stop gracefully

### Step 3: Remove All Containers
- Remove all containers (running and stopped) using `docker rm -f $(docker ps -aq)`
- Verify all containers are removed

### Step 4: Docker System Prune
Execute comprehensive Docker cleanup commands in order:
1. `docker container prune -f` - Remove all stopped containers
2. `docker image prune -a -f` - Remove all unused images (not just dangling)
3. `docker volume prune -f` - Remove all unused volumes
4. `docker network prune -f` - Remove all unused networks
5. `docker builder prune -a -f` - Remove all build cache
6. `docker system prune -a --volumes -f` - Final comprehensive cleanup (removes everything unused including volumes)

### Step 5: Verify Cleanup
- Check disk space before and after: `df -h`
- Check Docker system usage: `docker system df`
- Verify no containers remain: `docker ps -a`
- Show summary of freed space

## Execution Checklist

1. [x] SSH to production: `ssh statex`
2. [x] Verify connection and check current directory
3. [x] Check Docker status: `docker ps`
4. [x] Stop all running containers: Used `./scripts/stop-all-services.sh`
5. [x] Force kill any remaining containers: Handled by stop-all-services.sh
6. [x] Remove all containers: All containers removed by stop script
7. [x] Verify containers removed: `docker ps -a` (confirmed no containers)
8. [x] Check disk space before: 82% used (31G used out of 39G)
9. [x] Check Docker system usage before: 25 images (15.09GB), 0 containers, 3 volumes
10. [x] Run container prune: `docker container prune -f` (0B reclaimed)
11. [x] Run image prune (all unused): `docker image prune -a -f` (14.64GB reclaimed)
12. [x] Run volume prune: `docker volume prune -f` (1 volume removed)
13. [x] Run network prune: `docker network prune -f` (3 networks removed)
14. [x] Run builder prune: `docker builder prune -a -f` (0B reclaimed)
15. [x] Run comprehensive system prune: `docker system prune -a --volumes -f` (0B reclaimed)
16. [x] Check disk space after: 39% used (15G used out of 39G) - **Freed 16GB!**
17. [x] Check Docker system usage after: 0 images, 0 containers, 2 volumes (0B)
18. [x] Verify no containers remain: `docker ps -a` (confirmed empty)
19. [x] Show summary of cleanup results

## Results Summary

✅ **Cleanup Completed Successfully**

- **Disk Space**: Reduced from 82% (31G) to 39% (15G) - **Freed 16GB**
- **Docker Images**: Removed all 25 images (15.09GB reclaimed)
- **Docker Containers**: All containers stopped and removed
- **Docker Volumes**: 1 volume removed (3 volumes → 2 volumes remaining, 0B size)
- **Docker Networks**: 3 networks removed (crypto-ai-agent_default, nginx-network, e-commerce_default)
- **Build Cache**: Already empty (0B)

**Final State**:
- 0 containers
- 0 images
- 2 volumes (0B size)
- 0 build cache
- Disk usage: 39% (down from 82%)

