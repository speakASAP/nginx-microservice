# Docker Cleanup Script Fix Plan

## Problem Analysis

1. **Current Issue**: Script only removes unused images, not other Docker resources consuming disk space
2. **Root Cause**: Conservative cleanup approach doesn't address filesystem space issues
3. **Impact**: Disk space continues to fill up despite cron job running

## Solution Overview

Enhance the cleanup script to remove:
- Stopped containers
- Unused volumes (with safety check)
- Build cache
- Unused networks
- Unused images (existing)

Add disk space threshold check to trigger aggressive cleanup when space is low.

## Implementation Checklist

1. Update script header comment to reflect comprehensive cleanup
2. Add disk space threshold check function (warn if < 10% free)
3. Add cleanup for stopped containers (`docker container prune -f`)
4. Add cleanup for unused volumes (`docker volume prune -f`) - with safety note
5. Add cleanup for build cache (`docker builder prune -a -f`)
6. Add cleanup for unused networks (`docker network prune -f`)
7. Keep existing unused images cleanup
8. Add total space reclaimed calculation
9. Improve error handling for each cleanup step
10. Simplify redundant code
11. Test script manually after update

## Files to Modify

- `/Users/sergiystashok/Documents/GitHub/statex.cz/nginx-microservice/scripts/docker-cleanup-images.sh`

## Deployment Steps

1. Update script in codebase
2. Test script locally (dry-run if possible)
3. Deploy to production server: `/usr/local/bin/docker-cleanup-images.sh`
4. Verify cron job is running: `sudo crontab -l`
5. Check logs after next cron run: `tail -f /home/statex/docker-cleanup.log`

