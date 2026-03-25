# Keycloak JWT auth proxy — validates Bearer tokens via JWKS
#
# Sits in front of services (Apollo, devmcp) as a Cloud Run sidecar.
# Same stack as credential-proxy (Python + FastAPI + uvicorn).
#
# Required env vars:
#   UPSTREAM_URL     — e.g. http://localhost:8001
#   KEYCLOAK_ISSUER  — e.g. https://keycloak-apanptkfaq-as.a.run.app/realms/fluid
#
# Remove when ContextForge handles all traffic with working auth.

FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY proxy.py .

CMD ["sh", "-c", "uvicorn proxy:app --host 0.0.0.0 --port ${PORT:-8000}"]
