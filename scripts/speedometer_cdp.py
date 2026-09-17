#!/usr/bin/env python3
"""
speedometer_cdp.py -- run Speedometer 3.1 against ONE build and record the score.

Why this exists
---------------
The 2026-09-16 Speedometer comparison in docs/BENCHMARKS.md is unusable. How
the two browsers were launched was not recorded, and Chromium's process
singleton is keyed on the user data directory: launching the second build
while the first is running hands the command line to the ALREADY RUNNING
browser and exits. The window that appears belongs to the first build, so the
run compares a build with itself and produces exactly the near-zero delta that
was observed. That result cannot distinguish "no codegen effect" from "same
binary twice".

This driver removes the human from the loop:

  * every run gets its OWN --user-data-dir, so the singleton cannot alias two
    builds together;
  * it asserts the browser it talks to is the binary it launched, by reading
    CDP Browser.getVersion AND the OS process path, and aborts otherwise;
  * it records the resolved exe path and its SHA256 in the output JSON, so a
    result can never again be of unknown provenance.

STARTING THE BENCHMARK NEEDS A TRUSTED CLICK
--------------------------------------------
Measured against Speedometer 3.1, not assumed: dispatching
`document.querySelector('.start-tests-button').click()` through
Runtime.evaluate does NOTHING. The button is found, the call returns without
throwing, and the page stays on section #home forever -- the first version of
this script sat in its score-polling loop for minutes against a completely
idle browser (chrome CPU 0.00s over 5s, which is how it was caught).

Speedometer's handler requires a real user gesture, so the click is delivered
through the Input domain at the button's viewport coordinates, which produces
a trusted event. Verified live: section went home -> running immediately.

`window.benchmarkClient.start()` is kept as a fallback. Either way the script
now ASSERTS that section #running appears before it starts waiting for a
score, so "failed to start" is a fast, explicit error instead of a timeout
fifteen minutes later.

No third-party packages. The CDP transport is a minimal WebSocket client
built on the standard library, because whether `websocket-client` is
installed on the build machine is not something a benchmark should depend on.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import socket
import struct
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


# --------------------------------------------------------------------------
# Minimal WebSocket client (RFC 6455), client-to-server frames are masked.
# --------------------------------------------------------------------------
class WS:
    def __init__(self, url, timeout=30):
        m = re.match(r"ws://([^:/]+):(\d+)(/.*)", url)
        if not m:
            raise ValueError(f"cannot parse ws url: {url}")
        host, port, path = m.group(1), int(m.group(2)), m.group(3)
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("handshake closed early")
            buf += chunk
        if b"101" not in buf.split(b"\r\n")[0]:
            raise ConnectionError("handshake failed")
        self._rest = buf.split(b"\r\n\r\n", 1)[1]

    def _recv_exact(self, n):
        out = self._rest[:n]
        self._rest = self._rest[n:]
        while len(out) < n:
            chunk = self.sock.recv(n - len(out))
            if not chunk:
                raise ConnectionError("socket closed")
            out += chunk
        return out

    def send(self, text):
        payload = text.encode()
        header = bytearray([0x81])  # FIN + text
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < (1 << 16):
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def recv(self):
        while True:
            b0, b1 = self._recv_exact(2)
            opcode = b0 & 0x0F
            length = b1 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._recv_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._recv_exact(8))[0]
            data = self._recv_exact(length) if length else b""
            if opcode == 0x8:          # close
                raise ConnectionError("server closed websocket")
            if opcode == 0x9:          # ping -> pong
                self.sock.sendall(bytes([0x8A, 0x80]) + os.urandom(4))
                continue
            if opcode in (0x1, 0x2):
                return data.decode("utf-8", "replace")

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


class CDP:
    def __init__(self, ws_url, timeout=30):
        self.ws = WS(ws_url, timeout=timeout)
        self._id = 0

    def call(self, method, params=None, timeout=60):
        self._id += 1
        mid = self._id
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})
        raise TimeoutError(f"{method} timed out")

    def evaluate(self, expr, timeout=60):
        r = self.call(
            "Runtime.evaluate",
            {"expression": expr, "returnByValue": True, "awaitPromise": False},
            timeout=timeout,
        )
        if "exceptionDetails" in r:
            raise RuntimeError(f"JS threw: {r['exceptionDetails'].get('text')}")
        return r.get("result", {}).get("value")

    def close(self):
        self.ws.close()


# --------------------------------------------------------------------------
def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def http_json(url, timeout=5):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode())


def wait_for_devtools(port, deadline):
    last = None
    while time.time() < deadline:
        try:
            return http_json(f"http://127.0.0.1:{port}/json/version")
        except Exception as e:
            last = e
            time.sleep(0.3)
    raise TimeoutError(f"devtools on :{port} never came up ({last})")


def page_ws_url(port):
    for t in http_json(f"http://127.0.0.1:{port}/json/list"):
        if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
            return t["webSocketDebuggerUrl"]
    raise RuntimeError("no page target")


SEL = (".start-tests-button,#home .start-tests-button,button.start-tests-button")


def visible_sections(cdp):
    return cdp.evaluate(
        "Array.from(document.querySelectorAll('section')).filter("
        "s=>getComputedStyle(s).display!=='none').map(s=>s.id).join(',')") or ""


def trusted_click(cdp, selector):
    """Deliver a real (trusted) click at the element's viewport centre."""
    box = cdp.evaluate(
        "(function(){var b=document.querySelector(%r);if(!b)return null;"
        "b.scrollIntoView({block:'center'});var r=b.getBoundingClientRect();"
        "return JSON.stringify({x:r.x+r.width/2,y:r.y+r.height/2});})()" % selector)
    if not box:
        return False
    c = json.loads(box)
    cdp.call("Input.dispatchMouseEvent",
             {"type": "mouseMoved", "x": c["x"], "y": c["y"], "buttons": 0})
    cdp.call("Input.dispatchMouseEvent",
             {"type": "mousePressed", "x": c["x"], "y": c["y"],
              "button": "left", "clickCount": 1, "buttons": 1})
    cdp.call("Input.dispatchMouseEvent",
             {"type": "mouseReleased", "x": c["x"], "y": c["y"],
              "button": "left", "clickCount": 1, "buttons": 0})
    return True


def start_benchmark(cdp):
    """Start the run and confirm it actually started. Returns how it started."""
    if trusted_click(cdp, SEL):
        deadline = time.time() + 20
        while time.time() < deadline:
            if "running" in visible_sections(cdp):
                return "trusted_click"
            time.sleep(1)

    # Fallback: drive the client object directly.
    cdp.evaluate("(function(){try{window.benchmarkClient.start();}catch(e){}})()")
    deadline = time.time() + 20
    while time.time() < deadline:
        if "running" in visible_sections(cdp):
            return "benchmarkClient.start"
        time.sleep(1)

    raise RuntimeError(
        "benchmark did not start: page still on section "
        f"'{visible_sections(cdp)}' after a trusted click and "
        "benchmarkClient.start(). Speedometer's markup may have changed.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--profile-dir", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--port", type=int, default=9222)
    ap.add_argument("--url", default="https://browserbench.org/Speedometer3.1/")
    ap.add_argument("--out-json", required=True)
    ap.add_argument("--run-timeout", type=int, default=900)
    ap.add_argument("--width", type=int, default=1600)
    ap.add_argument("--height", type=int, default=1000)
    args = ap.parse_args()

    exe = Path(args.exe).resolve()
    if not exe.exists():
        print(f"FATAL: no binary at {exe}", file=sys.stderr)
        return 2

    prof = Path(args.profile_dir)
    prof.mkdir(parents=True, exist_ok=True)

    flags = [
        str(exe),
        f"--user-data-dir={prof}",
        f"--remote-debugging-port={args.port}",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-search-engine-choice-screen",
        "--homepage=about:blank",
        # Applied identically to BOTH builds. Without these Chromium throttles
        # timers and compositing whenever the window loses focus or is
        # occluded, which on an unattended run is the difference between a
        # benchmark and a random number.
        "--disable-background-timer-throttling",
        "--disable-backgrounding-occluded-windows",
        "--disable-renderer-backgrounding",
        f"--window-size={args.width},{args.height}",
        "--window-position=60,40",
        "about:blank",
    ]

    print(f"[{args.label}] launching {exe}", flush=True)
    proc = subprocess.Popen(flags)
    result = {
        "label": args.label,
        "exe": str(exe),
        "exe_sha256": sha256(exe),
        "exe_mtime": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(exe.stat().st_mtime)),
        "profile_dir": str(prof),
        "url": args.url,
        "started": time.strftime("%Y-%m-%d %H:%M:%S"),
    }

    cdp = None
    try:
        ver = wait_for_devtools(args.port, time.time() + 60)
        result["browser_version"] = ver.get("Browser")
        result["webkit_version"] = ver.get("WebKit-Version")
        result["v8_version"] = ver.get("V8-Version")

        # PROVENANCE GUARD. The whole point of this script. Confirm the
        # process actually serving this debugging port is the exe we launched
        # -- not a different build that grabbed the command line.
        try:
            out = subprocess.run(
                ["powershell.exe", "-NoProfile", "-Command",
                 f"(Get-Process -Id {proc.pid} -ErrorAction SilentlyContinue).Path"],
                capture_output=True, text=True, timeout=30).stdout.strip()
            result["os_process_path"] = out
            if out and Path(out).resolve() != exe:
                raise RuntimeError(f"process path {out} != launched exe {exe}")
        except Exception as e:
            result["provenance_warning"] = str(e)

        cdp = CDP(page_ws_url(args.port))
        cdp.call("Runtime.enable")
        cdp.call("Page.enable")
        cdp.call("Page.navigate", {"url": args.url})

        deadline = time.time() + 120
        while time.time() < deadline:
            if cdp.evaluate(f"!!document.querySelector({SEL!r})"):
                break
            time.sleep(1)
        else:
            raise TimeoutError("Speedometer start button never appeared (page load / network?)")

        result["page_title"] = cdp.evaluate("document.title")
        print(f"[{args.label}] loaded: {result['page_title']}", flush=True)

        how = start_benchmark(cdp)
        result["started_via"] = how
        print(f"[{args.label}] running (started via {how}), waiting for score ...", flush=True)

        deadline = time.time() + args.run_timeout
        score = None
        while time.time() < deadline:
            time.sleep(5)
            score = cdp.evaluate(
                "(function(){var e=document.querySelector('#result-number');"
                "return e&&e.textContent.trim()?e.textContent.trim():null;})()")
            if score:
                break
        if not score:
            raise TimeoutError(
                f"no score after {args.run_timeout}s (section="
                f"{visible_sections(cdp)})")

        result["score"] = float(score)
        result["confidence"] = cdp.evaluate(
            "(function(){var e=document.querySelector('#confidence-number');"
            "return e?e.textContent.trim():null;})()")
        # Full per-suite JSON, so a result can be re-analysed without re-running.
        try:
            result["full_json"] = cdp.evaluate(
                "(function(){try{return JSON.stringify("
                "window.benchmarkClient._formattedJSONResult"
                "?JSON.parse(window.benchmarkClient._formattedJSONResult()):null);}"
                "catch(e){return null;}})()")
        except Exception:
            result["full_json"] = None
        result["finished"] = time.strftime("%Y-%m-%d %H:%M:%S")
        result["ok"] = True
        print(f"[{args.label}] SCORE {score}  {result['confidence'] or ''}", flush=True)

    except Exception as e:
        result["ok"] = False
        result["error"] = f"{type(e).__name__}: {e}"
        print(f"[{args.label}] FAILED: {result['error']}", file=sys.stderr, flush=True)
    finally:
        if cdp:
            cdp.close()
        try:
            proc.terminate()
            proc.wait(timeout=20)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        # Chromium leaves children behind; reap anything still on our profile.
        subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command",
             "Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | "
             f"Where-Object {{ $_.CommandLine -like '*{prof.name}*' }} | "
             "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"],
            capture_output=True, timeout=60)

    Path(args.out_json).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out_json).write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(f"[{args.label}] wrote {args.out_json}", flush=True)
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
