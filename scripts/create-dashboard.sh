#!/bin/bash
# Create Cloud Monitoring dashboard + alerting policies for Fluid Intelligence
# Usage: ./scripts/create-dashboard.sh
# Requires: gcloud authenticated with monitoring.admin role

set -euo pipefail

PROJECT="${GCP_PROJECT:-junlinleather-mcp}"
SERVICE="fluid-intelligence"
NOTIFICATION_EMAIL="${ALERT_EMAIL:-ourteam@junlinleather.com}"

echo "=== Creating Fluid Intelligence Monitoring Dashboard ==="

# Create notification channel (email)
CHANNEL_ID=$(gcloud monitoring channels list --project="$PROJECT" \
  --filter="type=email AND labels.email_address=$NOTIFICATION_EMAIL" \
  --format='value(name)' 2>/dev/null | head -1)

if [ -z "$CHANNEL_ID" ]; then
  echo "Creating email notification channel for $NOTIFICATION_EMAIL..."
  CHANNEL_ID=$(gcloud monitoring channels create --project="$PROJECT" \
    --type=email \
    --display-name="Fluid Intelligence Alerts" \
    --channel-labels="email_address=$NOTIFICATION_EMAIL" \
    --format='value(name)' 2>/dev/null)
  echo "Created channel: $CHANNEL_ID"
else
  echo "Using existing channel: $CHANNEL_ID"
fi

# Create dashboard
echo "Creating dashboard..."
gcloud monitoring dashboards create --project="$PROJECT" --config-from-file=/dev/stdin <<'DASHBOARD_JSON'
{
  "displayName": "Fluid Intelligence — MCP Gateway",
  "gridLayout": {
    "columns": "2",
    "widgets": [
      {
        "title": "Request Latency (p50/p95/p99)",
        "xyChart": {
          "dataSets": [{
            "timeSeriesQuery": {
              "timeSeriesFilter": {
                "filter": "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"fluid-intelligence\" AND metric.type=\"run.googleapis.com/request_latencies\"",
                "aggregation": {"alignmentPeriod": "60s", "perSeriesAligner": "ALIGN_PERCENTILE_99"}
              }
            }
          }]
        }
      },
      {
        "title": "Request Count by Status",
        "xyChart": {
          "dataSets": [{
            "timeSeriesQuery": {
              "timeSeriesFilter": {
                "filter": "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"fluid-intelligence\" AND metric.type=\"run.googleapis.com/request_count\"",
                "aggregation": {"alignmentPeriod": "60s", "perSeriesAligner": "ALIGN_RATE", "groupByFields": ["metric.labels.response_code_class"]}
              }
            }
          }]
        }
      },
      {
        "title": "Instance Count",
        "xyChart": {
          "dataSets": [{
            "timeSeriesQuery": {
              "timeSeriesFilter": {
                "filter": "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"fluid-intelligence\" AND metric.type=\"run.googleapis.com/container/instance_count\"",
                "aggregation": {"alignmentPeriod": "60s", "perSeriesAligner": "ALIGN_MAX"}
              }
            }
          }]
        }
      },
      {
        "title": "Memory Usage",
        "xyChart": {
          "dataSets": [{
            "timeSeriesQuery": {
              "timeSeriesFilter": {
                "filter": "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"fluid-intelligence\" AND metric.type=\"run.googleapis.com/container/memory/utilizations\"",
                "aggregation": {"alignmentPeriod": "60s", "perSeriesAligner": "ALIGN_MAX"}
              }
            }
          }]
        }
      },
      {
        "title": "Cold Starts (Startup Latency)",
        "xyChart": {
          "dataSets": [{
            "timeSeriesQuery": {
              "timeSeriesFilter": {
                "filter": "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"fluid-intelligence\" AND metric.type=\"run.googleapis.com/container/startup_latencies\"",
                "aggregation": {"alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_PERCENTILE_99"}
              }
            }
          }]
        }
      },
      {
        "title": "CPU Utilization",
        "xyChart": {
          "dataSets": [{
            "timeSeriesQuery": {
              "timeSeriesFilter": {
                "filter": "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"fluid-intelligence\" AND metric.type=\"run.googleapis.com/container/cpu/utilizations\"",
                "aggregation": {"alignmentPeriod": "60s", "perSeriesAligner": "ALIGN_MAX"}
              }
            }
          }]
        }
      }
    ]
  }
}
DASHBOARD_JSON

echo "Dashboard created."

# Create alerting policies
echo ""
echo "=== Creating Alerting Policies ==="

# Alert 1: 5xx error rate > 5%
echo "Creating 5xx error rate alert..."
gcloud monitoring policies create --project="$PROJECT" --policy-from-file=/dev/stdin <<ALERT1_JSON
{
  "displayName": "Fluid Intelligence — 5xx Error Rate",
  "conditions": [{
    "displayName": "5xx rate > 5%",
    "conditionThreshold": {
      "filter": "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"fluid-intelligence\" AND metric.type=\"run.googleapis.com/request_count\" AND metric.labels.response_code_class=\"5xx\"",
      "aggregations": [{"alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_RATE"}],
      "comparison": "COMPARISON_GT",
      "thresholdValue": 0.05,
      "duration": "300s"
    }
  }],
  "notificationChannels": ["$CHANNEL_ID"],
  "combiner": "OR"
}
ALERT1_JSON

# Alert 2: Memory > 3.5Gi (OOM early warning)
echo "Creating memory pressure alert..."
gcloud monitoring policies create --project="$PROJECT" --policy-from-file=/dev/stdin <<ALERT2_JSON
{
  "displayName": "Fluid Intelligence — Memory Pressure",
  "conditions": [{
    "displayName": "Memory > 87.5% (3.5Gi of 4Gi)",
    "conditionThreshold": {
      "filter": "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"fluid-intelligence\" AND metric.type=\"run.googleapis.com/container/memory/utilizations\"",
      "aggregations": [{"alignmentPeriod": "60s", "perSeriesAligner": "ALIGN_MAX"}],
      "comparison": "COMPARISON_GT",
      "thresholdValue": 0.875,
      "duration": "120s"
    }
  }],
  "notificationChannels": ["$CHANNEL_ID"],
  "combiner": "OR"
}
ALERT2_JSON

echo ""
echo "=== Done ==="
echo "Dashboard: https://console.cloud.google.com/monitoring/dashboards?project=$PROJECT"
echo "Alerts: https://console.cloud.google.com/monitoring/alerting?project=$PROJECT"
