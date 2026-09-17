FROM python:3.11-slim

WORKDIR /app

# Copy the Python script into the container
COPY uc2.py .

# Expose the application port
EXPOSE 8080

# Run the script unbuffered so logs appear immediately
CMD ["python", "-u", "uc2.py"]
