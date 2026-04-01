#!/bin/bash
echo "Waiting for Ray to start and generate dashboard configs..."
sleep 15

DASHBOARD_SRC="/tmp/ray/session_latest/metrics/grafana/dashboards"
DASHBOARD_DEST="/grafana-dashboards"

for i in $(seq 1 30); do
    if [ -d "$DASHBOARD_SRC" ]; then
        echo "Found Ray dashboards at ${DASHBOARD_SRC}"
        cp -r ${DASHBOARD_SRC}/*.json ${DASHBOARD_DEST}/ 2>/dev/null
        echo "Copied $(ls ${DASHBOARD_DEST}/*.json 2>/dev/null | wc -l) dashboard(s)"
        exit 0
    fi
    echo "Waiting for dashboards... (${i}/30)"
    sleep 2
done

echo "WARNING: Could not find Ray dashboard configs after 60 seconds."
