FROM python:3.12-slim

WORKDIR /app

COPY deploy/shopify-oauth/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY services/shopify_oauth/ services/shopify_oauth/
RUN touch services/__init__.py

ENV PORT=8080
EXPOSE 8080

CMD ["uvicorn", "services.shopify_oauth.main:app", "--host", "0.0.0.0", "--port", "8080"]
