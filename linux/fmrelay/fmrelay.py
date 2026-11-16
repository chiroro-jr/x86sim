#!/usr/bin/env python3
"""x86Sim: the Linux leg of the FoundationModels relay to a Mac with Apple Intelligence.

Apple's simulators run the system language model on the Mac: the simulator's HostInferenceProviderService.appex talks to
the Mac's modelmanagerd through the host Mach service com.apple.modelmanager.simulator. On x86Sim the simulator job
com.x86sim.mmhost (host/mmhost/mmhost.c) offers that name inside the simulator and hands each connection, its XPC
messages serialized (host/mmhost/xpcwire.h), to this process over a Unix socket. For each one this process runs the
Mac end (host/mmhost/fmrelay-mac.c) over ssh on $X86SIM_FM_RELAY, which opens the Mac's com.apple.modelmanager.simulator
as the appex on Apple's simulator would, and pumps the bytes both ways unchanged.

At start it builds fmrelay-mac on the Mac (clang of the Command Line Tools) into ~/Library/Caches/x86sim-fmrelay/<hash>/
unless that build is already there, and holds one ssh master connection, which every relayed connection shares. When the
Mac cannot be reached a connection is closed at once (and the next ones for 30 s): mmhost then cancels the simulator's
connection, as when the host service goes away (the model reports not ready, a request fails). Nothing is left running on
the Mac: each fmrelay-mac ends when its stdin does, and this process ends its ssh master when it stops
(cli/libexec/arm64/boot-a64.sh stops it with the device).

The Mac: Apple Intelligence on, and its modelmanagerd offering com.apple.modelmanager.simulator (the ModelManager/simulator
feature flag, on where Xcode's simulators get the model: `launchctl print system/com.apple.modelmanagerd` lists it under
endpoints). fmrelay-mac puts its connection in libxpc's simulator-to-host mode, as the simulator's appex does; the
daemon's simulator listener reads its peers that way and dropped plain connections.

Usage: fmrelay.py <socket path> <user@mac>   (X86SIM_FMRELAY_TRACE=1|2: fmrelay-mac logs each frame to this log)
"""
import hashlib
import os
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "..", "host", "mmhost")
FILES = ("xpcwire.h", "fmrelay-mac.c")
RETRY = 30


def log(*a):
    print("fmrelay:", *a, file=sys.stderr, flush=True)


class Relay:
    def __init__(self, sock, mac):
        self.sock, self.mac = sock, mac
        self.ctl = os.path.join(tempfile.mkdtemp(prefix="x86sim-fmrelay."), "ssh")
        self.master = None
        self.remote = None
        self.failed = 0.0  # when the Mac last could not be reached: connections fail at once for RETRY s after
        self.lock = threading.Lock()
        h = hashlib.sha256()
        for f in FILES:
            with open(os.path.join(SRC, f), "rb") as fh:
                h.update(f.encode() + b"\0" + fh.read())
        self.tag = h.hexdigest()[:16]

    def ssh(self, *args):
        return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15",
                "-o", "ControlPath=" + self.ctl, *args, self.mac]

    def ready(self):
        """the ssh master is up and fmrelay-mac built: the remote command, or None"""
        with self.lock:
            if self.remote and self.master and self.master.poll() is None:
                return self.remote
            if time.monotonic() - self.failed < RETRY:
                return None
            self.remote = None
            r = self._connect()
            if not r:
                self.failed = time.monotonic()
            return r

    def _connect(self):
        """start the ssh master and build fmrelay-mac on the Mac (under self.lock)"""
        if self.master and self.master.poll() is None:
            self.master.terminate()
        self.master = subprocess.Popen(self.ssh("-M", "-N", "-o", "ControlPersist=no"), stdin=subprocess.DEVNULL,
                                       stdout=subprocess.DEVNULL, stderr=sys.stderr)
        for _ in range(100):  # up to 10 s for the master's socket
            if self.master.poll() is not None:
                log("cannot reach", self.mac)
                self.master = None
                return None
            if subprocess.run(self.ssh("-O", "check"), capture_output=True).returncode == 0:
                break
            threading.Event().wait(0.1)
        else:
            log("no ssh master to", self.mac)
            return None
        d = "Library/Caches/x86sim-fmrelay/" + self.tag
        build = ("set -e; d=$HOME/%s; [ -x $d/fmrelay-mac ] && exit 0; rm -rf $HOME/Library/Caches/x86sim-fmrelay; "
                 "mkdir -p $d; cd $d; tar xf -; clang -O1 -Wall -o fmrelay-mac.tmp fmrelay-mac.c >&2; "
                 "mv fmrelay-mac.tmp fmrelay-mac" % d)
        tar = subprocess.run(["tar", "cf", "-", "-C", SRC, *FILES], capture_output=True, check=True).stdout
        r = subprocess.run(self.ssh() + [build], input=tar, stdout=subprocess.DEVNULL, stderr=sys.stderr)
        if r.returncode != 0:
            log("building fmrelay-mac on", self.mac, "failed")
            return None
        tr = os.environ.get("X86SIM_FMRELAY_TRACE", "")
        self.remote = ("X86SIM_FMRELAY_TRACE=%s exec $HOME/%s/fmrelay-mac" % (shlex.quote(tr), d))
        log("relaying to", self.mac, "(fmrelay-mac %s)" % self.tag)
        return self.remote

    def serve(self, c):
        remote = self.ready()
        if not remote:
            c.close()  # mmhost cancels the simulator's connection
            return
        p = subprocess.Popen(self.ssh() + [remote], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr,
                             bufsize=0)
        log("connection -> ssh pid", p.pid)

        def up():  # simulator -> Mac
            try:
                while True:
                    b = c.recv(65536)
                    if not b:
                        break
                    p.stdin.write(b)
            except OSError:
                pass
            try:
                p.stdin.close()
            except OSError:
                pass

        t = threading.Thread(target=up, daemon=True)
        t.start()
        try:  # Mac -> simulator
            while True:
                b = p.stdout.read(65536)
                if not b:
                    break
                c.sendall(b)
        except OSError:
            pass
        try:
            c.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        c.close()
        try:
            p.stdin.close()
        except OSError:
            pass
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()
        log("connection ended (ssh pid %d, exit %s)" % (p.pid, p.returncode))

    def stop(self, *_):
        if self.master and self.master.poll() is None:
            subprocess.run(self.ssh("-O", "exit"), capture_output=True)
            self.master.terminate()
        try:
            os.unlink(self.sock)
        except OSError:
            pass
        os._exit(0)

    def run(self):
        signal.signal(signal.SIGTERM, self.stop)
        signal.signal(signal.SIGINT, self.stop)
        signal.signal(signal.SIGHUP, self.stop)
        try:
            os.unlink(self.sock)
        except OSError:
            pass
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(self.sock)
        os.chmod(self.sock, 0o777)
        s.listen(16)
        log("listening on", self.sock, "for", self.mac)
        # build and connect ahead of the first request (the model's first availability check)
        threading.Thread(target=self.ready, daemon=True).start()
        while True:
            c, _ = s.accept()
            threading.Thread(target=self.serve, args=(c,), daemon=True).start()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    Relay(sys.argv[1], sys.argv[2]).run()
