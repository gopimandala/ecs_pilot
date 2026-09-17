from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import boto3
import os

# Initialize AWS clients
# AWS automatically injects credentials into the container via IAM Task Roles.
# The API writes requests to the queue dedicated to each use case.
sqs_client = boto3.client('sqs', region_name='ap-south-1')

UC1_SQS_QUEUE_URL = os.getenv("UC1_SQS_QUEUE_URL")
UC2_SQS_QUEUE_URL = os.getenv("UC2_SQS_QUEUE_URL")

class MainApiHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/usecase1':
            worker_name = "uc1"
            queue_url = UC1_SQS_QUEUE_URL
        elif self.path == '/usecase2':
            worker_name = "uc2"
            queue_url = UC2_SQS_QUEUE_URL
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"404 Route Not Found. Use /usecase1 or /usecase2\n")
            return

        if not queue_url:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(f"{worker_name.upper()} queue URL is not configured.\n".encode("utf-8"))
            return

        try:
            message = {
                "usecase": worker_name
            }

            response = sqs_client.send_message(
                QueueUrl=queue_url,
                MessageBody=json.dumps(message),
                MessageAttributes={
                    "usecase": {
                        "StringValue": worker_name,
                        "DataType": "String"
                    }
                }
            )

            self.send_response(202)
            self.send_header("Content-type", "application/json")
            self.end_headers()

            response_data = {
                "status": "queued_to_sqs",
                "worker": worker_name,
                "message_id": response.get("MessageId"),
                "queue_url": queue_url
            }
            self.wfile.write(json.dumps(response_data).encode("utf-8"))

        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(f"SQS Submission Error: {str(e)}\n".encode("utf-8"))

if __name__ == "__main__":
    server_address = ("", 8000)
    httpd = HTTPServer(server_address, MainApiHandler)
    print("ECS Main API Gateway running on port 8000...")
    httpd.serve_forever()
