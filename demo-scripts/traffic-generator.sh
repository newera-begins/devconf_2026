#!/bin/bash
# Traffic Generator — runs continuous requests between all tiers
# Start this BEFORE the demo so NOO dashboard shows active flows
# Usage: bash traffic-generator.sh
# To stop: kill the background process or press Ctrl+C

set -e

NAMESPACE="demo-app"
INTERVAL=2  # seconds between requests

echo "=== Bookstore Traffic Generator ==="
echo "Sending requests every ${INTERVAL}s to all tiers in namespace ${NAMESPACE}"
echo "Press Ctrl+C to stop"
echo ""

while true; do
    TIMESTAMP=$(date '+%H:%M:%S')

    # Backend API health check (generates pod-to-service traffic)
    HTTP_CODE=$(oc exec -n "$NAMESPACE" deploy/backend-api -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 --max-time 5 \
        http://backend-api:5000/api/health 2>/dev/null || echo "000")
    echo "[$TIMESTAMP] backend-api /api/health : HTTP $HTTP_CODE"

    # Backend API → Database (queries PostgreSQL via books endpoint)
    HTTP_CODE=$(oc exec -n "$NAMESPACE" deploy/backend-api -- \
        curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 --max-time 5 \
        http://backend-api:5000/api/books 2>/dev/null || echo "000")
    echo "[$TIMESTAMP] backend-api /api/books  : HTTP $HTTP_CODE"

    # Frontend via route (external → frontend → backend-api)
    ROUTE_URL=$(oc get route frontend -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
    if [ -n "$ROUTE_URL" ]; then
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 3 --max-time 5 \
            "http://$ROUTE_URL/" 2>/dev/null || echo "000")
        echo "[$TIMESTAMP] external → frontend (route)    : HTTP $HTTP_CODE"
    fi

    echo "---"
    sleep "$INTERVAL"
done
