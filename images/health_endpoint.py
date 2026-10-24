from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading


def start_health_server(is_healthy, port=8080):
    class HealthHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/health":
                self.send_error(404)
                return

            healthy = is_healthy()
            self.send_response(200 if healthy else 503)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(
                json.dumps({"status": "healthy" if healthy else "unhealthy"}).encode()
            )

        def log_message(self, _format, *_args):
            return

    server = ThreadingHTTPServer(("127.0.0.1", port), HealthHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server
