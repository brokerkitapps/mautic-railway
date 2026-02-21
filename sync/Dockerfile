FROM python:3.13-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY sync_mautic_ids_to_hubspot.py .

CMD ["python", "sync_mautic_ids_to_hubspot.py"]
