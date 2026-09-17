from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import docker

# Initialize the local Docker engine client
docker_client = docker.from_env()

class MainApiHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        # 1. Routing Matrix Evaluation
        if self.path == '/usecase1':
            target_image = "gopi/uc1:latest"
            worker_name = "uc1"
        elif self.path == '/usecase2':
            target_image = "gopi/uc2:latest"
            worker_name = "uc2"
        else:
            # 404 Route Not Found for any unmapped paths
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"404 Route Not Found. Use /usecase1 or /usecase2\n")
            return

        # 2. Dynamic Container Orchestration (Simulating ECS RunTask execution)
        try:
            print(f"Routing to {worker_name}... Launching ephemeral container [{target_image}].")
            
            # Spin up the target worker container container
            container = docker_client.containers.run(
                image=target_image,
                detach=False,       # Hold the connection open until the python script exits
                remove=True         # Automatically destroy the container container immediately on completion
            )
            
            # 3. Capture runtime logs from the execution (the printed Hello timestamp string)
            worker_output = container.decode('utf-8')
            
            # 4. Return successful structured response back to client
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            
            response_data = {
                "status": "success",
                "worker": worker_name,
                "output": worker_output.strip()
            }
            self.wfile.write(json.dumps(response_data).encode("utf-8"))
            
        except Exception as e:
            # Catch container failures or missing local images cleanly
            self.send_response(500)
            self.end_headers()
            self.wfile.write(f"Local Orchestration Error handling {worker_name}: {str(e)}\n".encode("utf-8"))

if __name__ == "__main__":
    server_address = ("", 8000)
    httpd = HTTPServer(server_address, MainApiHandler)
    print("Local main_api running on http://localhost:8000...")
    httpd.serve_forever()
