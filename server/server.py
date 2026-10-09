"""Tiny Whisper transcription server for push-to-dictate clients.

POST /transcribe with a 16 kHz mono 16-bit WAV body and header "Authorization: Bearer <token>".
Optional query: ?lang=en|zh (default: auto-detect). Responds with plain text.
"""
import io
import os
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import numpy as np
from faster_whisper import WhisperModel
from opencc import OpenCC

HOST = os.environ.get("WHISPER_HOST", "127.0.0.1")
PORT = int(os.environ.get("WHISPER_PORT", "8765"))
TOKEN = open(os.path.expanduser("~/whisper-server/token")).read().strip()
MODEL = os.environ.get("WHISPER_MODEL", "large-v3-turbo")
COMPUTE = os.environ.get("WHISPER_COMPUTE", "int8_float32")

t2s = OpenCC("t2s")
model = WhisperModel(MODEL, device="cuda", compute_type=COMPUTE)
print(f"loaded {MODEL} ({COMPUTE}); listening on {HOST}:{PORT}", flush=True)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        url = urlparse(self.path)
        if url.path != "/transcribe":
            return self.send_error(404)
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            return self.send_error(401)
        audio = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        lang = parse_qs(url.query).get("lang", [None])[0]
        start = time.time()
        try:
            text, language = self.transcribe(audio, lang)
        except Exception as e:
            print(f"transcribe failed: {e!r}", flush=True)
            return self.send_error(400, "expected 16 kHz mono 16-bit WAV")
        print(f"{language} {time.time() - start:.2f}s {text!r}", flush=True)
        body = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def transcribe(self, audio, lang):
        # Decode the WAV ourselves; faster-whisper's PyAV path breaks on newer av releases.
        with wave.open(io.BytesIO(audio)) as w:
            if (w.getframerate(), w.getnchannels(), w.getsampwidth()) != (16000, 1, 2):
                raise ValueError("expected 16 kHz mono 16-bit WAV")
            pcm = np.frombuffer(w.readframes(w.getnframes()), np.int16)
        segments, info = model.transcribe(
            pcm.astype(np.float32) / 32768.0,
            language=lang,
            beam_size=5,
            vad_filter=True,
            # Nudges Chinese output toward simplified characters with punctuation.
            initial_prompt="以下是普通话的句子，使用简体中文。" if lang == "zh" else None,
        )
        text = "".join(s.text for s in segments).strip()
        if info.language == "zh":
            text = t2s.convert(text)
        return text, info.language

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
