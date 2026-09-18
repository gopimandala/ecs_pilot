# --- Image 1: uc1 ---
FROM python:3.11-slim AS uc1
WORKDIR /app
COPY uc1.py .
EXPOSE 8080
CMD ["python", "-u", "uc1.py"]

# --- Image 2: uc2 ---
FROM python:3.11-slim AS uc2
WORKDIR /app
COPY uc2.py .
EXPOSE 8080
CMD ["python", "-u", "uc2.py"]

# --- Image 3: main_api ---
FROM python:3.11-slim AS main_api
WORKDIR /app
RUN pip install --no-cache-dir boto3
COPY main_api.py .
EXPOSE 8080
EXPOSE 8000
CMD ["python", "-u", "main_api.py"]

# --- Image 4: monitor ---
FROM python:3.11-slim AS monitor
WORKDIR /app
RUN pip install --no-cache-dir boto3
COPY monitor.py .
CMD ["python", "-u", "monitor.py"]

