#!/bin/bash

# Test script for metrics endpoint
# Usage: ./test-metrics.sh

echo "Testing /metrics endpoint..."
echo ""

curl -s http://localhost:3010/metrics | head -50

echo ""
echo "..."
echo ""
echo "Full metrics available at: http://localhost:3010/metrics"
echo ""
echo "Test unique users tracking with device token:"
echo "curl -X POST http://localhost:3010/live-activity/start \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -H 'X-Device-Token: test-device-123' \\"
echo "  -d '{\"dockId\":\"BikePoints_1\",\"pushToken\":\"test-token\",\"buildType\":\"development\",\"expirySeconds\":120}'"
echo ""
echo "Test app action metrics:"
echo "curl -X POST http://localhost:3010/app/metrics \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -H 'X-Device-Token: test-device-123' \\"
echo "  -d '{\"action\":\"dock_tap\",\"screen\":\"Map\",\"buildType\":\"development\",\"dock\":{\"id\":\"BikePoints_123\",\"name\":\"Windsor Terrace\",\"standardBikes\":5,\"eBikes\":2,\"emptySpaces\":7,\"totalDocks\":14,\"isAvailable\":true},\"metadata\":{\"source\":\"manual_test\"}}'"
echo ""
echo "Test dock stats metric actions:"
echo "curl -X POST http://localhost:3010/app/metrics \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -H 'X-Device-Token: test-device-123' \\"
echo "  -d '{\"action\":\"favorite_add\",\"screen\":\"Map\",\"buildType\":\"development\",\"dock\":{\"id\":\"BikePoints_123\",\"name\":\"Windsor Terrace\"},\"metadata\":{\"source\":\"manual_test\"}}'"
echo "curl -X POST http://localhost:3010/app/metrics \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -H 'X-Device-Token: test-device-123' \\"
echo "  -d '{\"action\":\"live_activity_start\",\"screen\":\"Favourites\",\"buildType\":\"development\",\"dock\":{\"id\":\"BikePoints_123\",\"name\":\"Windsor Terrace\"},\"metadata\":{\"source\":\"manual_test\"}}'"
echo ""
echo "Then verify metric output:"
echo "curl -s http://localhost:3010/metrics | rg \"dock_stats_total|app_actions_total\" -n -S"
