FROM python:3.11-slim
RUN pip install boto3
WORKDIR /app
COPY main_api.py .
CMD ["python", "-u", "main_api.py"]
