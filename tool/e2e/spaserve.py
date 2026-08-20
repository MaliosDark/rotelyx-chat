"""Static server with SPA fallback, matching what nginx must do in production."""
import http.server, os, sys
ROOT = sys.argv[1]; PORT = int(sys.argv[2])

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=ROOT, **k)
    def do_GET(self):
        p = self.translate_path(self.path)
        if not os.path.exists(p) and '.' not in os.path.basename(self.path):
            self.path = '/index.html'   # deep link -> the app's own router
        return super().do_GET()
    def log_message(self, *a): pass

http.server.ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
