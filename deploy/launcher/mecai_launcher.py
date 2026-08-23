#!/usr/bin/env python3
"""
MEC-AI Launcher — single-file Windows GUI for field deployment.

Put this folder on the Desktop (preferred — Downloads is ignored):
- Auto-detects the MECAI repo/bundle by walking up from the exe location
  and by scanning Desktop first (Downloads is skipped even if a stale copy exists).
- Update button runs `git pull --ff-only origin main` hidden, streams log.
- Start buttons spawn API + Web with CREATE_NO_WINDOW so no terminal is needed.
- Local IP is shown for the Flutter app to connect (http://<LAN_IP>:8000 and :3000).

Both dev (repo with services/api + apps/web) and bundled (MEC-AI-Windows.zip
layout with api/MEC-AI-API.exe + web/server.js + web/node.exe) are supported.

Build:
  pyinstaller --noconsole --onefile --name MECAI-Launcher --icon ../../MEC-AI_SIMPLIFIED-LOGO*.png mecai_launcher.py
"""
from __future__ import annotations

import http.client
import os
import queue
import socket
import subprocess
import sys
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

# ── detection ──────────────────────────────────────────────────────────────

ROOT_MARKERS = [
    Path("pnpm-workspace.yaml"),
    Path("apps/web/package.json"),
    Path("services/api/pyproject.toml"),
]
# Bundle markers (MEC-AI-Windows layout)
BUNDLE_MARKERS = [Path("api/MEC-AI-API.exe"), Path("web/server.js")]

def is_mecai_root(p: Path) -> bool:
    # repo OR bundle — either is a valid root
    if all((p / m).exists() for m in ROOT_MARKERS):
        return True
    if all((p / m).exists() for m in BUNDLE_MARKERS):
        return True
    return False

def walk_up(start: Path, depth: int = 5) -> Path | None:
    cur = start.resolve()
    for _ in range(depth + 1):
        if is_mecai_root(cur):
            return cur
        if cur.parent == cur:
            break
        cur = cur.parent
    return None

def _is_downloads(p: Path) -> bool:
    # Never prefer Downloads — client has a stale copy there from the zip
    try:
        parts = [s.lower() for s in p.resolve().parts]
    except Exception:
        parts = [s.lower() for s in p.parts]
    return "downloads" in parts

def _score_root(p: Path) -> int:
    # Lower is better. Desktop is always first; Downloads is always last.
    if _is_downloads(p):
        return 100
    s = str(p).lower().replace("\\", "/")
    if "/desktop/" in s or s.endswith("/desktop"):
        return 0
    # exact Desktop/MECAI variants score even better
    if "desktop" in s:
        return 1
    if "/documents/" in s:
        return 50
    return 10

def _desktop_paths() -> list[Path]:
    out: list[Path] = []
    for env in ["USERPROFILE", "HOME"]:
        base = os.environ.get(env)
        if base:
            b = Path(base)
            # lowercase 'mecai' first — client's folder is lowercase (git clone default)
            for sub in ["Desktop/mecai", "Desktop/MECAI", "Desktop/MEC-AI", "Desktop/mecai-main", "Desktop/Mecai", "Desktop"]:
                out.append(b / sub)
    # OneDrive Desktop (common on Win11)
    for env in ["OneDrive", "OneDriveCommercial", "OneDriveConsumer"]:
        base = os.environ.get(env)
        if base:
            b = Path(base)
            for sub in ["Desktop/mecai", "Desktop/MECAI", "Desktop/Mecai", "Desktop"]:
                out.append(b / sub)
    # Try the real shell folder via PowerShell (handles redirected Desktop)
    if sys.platform == "win32":
        try:
            ps = subprocess.check_output(
                ["powershell", "-NoProfile", "-Command", '[Environment]::GetFolderPath("Desktop")'],
                text=True, timeout=3, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)
            ).strip()
            if ps:
                p = Path(ps)
                # lowercase first — matches client's actual folder name
                out.insert(0, p / "mecai")
                out.insert(1, p / "MECAI")
                out.insert(2, p / "Mecai")
                out.insert(3, p / "MEC-AI")
                out.insert(4, p)
        except Exception:
            pass
    return out

def candidate_search_roots(exe_dir: Path) -> list[Path]:
    cands: list[Path] = []
    # 1) exe dir and parents — lowercase first for client's 'mecai'
    cur = exe_dir
    for _ in range(4):
        cands.append(cur)
        cands.append(cur / "mecai")
        cands.append(cur / "MECAI")
        cands.append(cur / "Mecai")
        cur = cur.parent
    # 2) Desktop first — explicit preference
    cands.extend(_desktop_paths())
    # 3) common Windows places (non-Desktop) — lowercase first
    for env in ["USERPROFILE", "HOME"]:
        base = os.environ.get(env)
        if not base:
            continue
        b = Path(base)
        for sub in [
            "mecai", "MECAI", "Mecai", "Documents/mecai", "Documents/MECAI",
            "mecai-app", "MEC-AI",
        ]:
            cands.append(b / sub)
        cands.append(b)
    # 4) drive roots like C:\mecai
    for drive in ["C:", "D:"]:
        cands.append(Path(f"{drive}/mecai"))
        cands.append(Path(f"{drive}/MECAI"))
        cands.append(Path(f"{drive}/Mecai"))
    # dedup preserve order
    seen: set[str] = set()
    uniq: list[Path] = []
    for p in cands:
        s = str(p).lower()
        if s not in seen:
            seen.add(s)
            uniq.append(p)
    return uniq

def auto_detect_root() -> Path | None:
    exe_dir = Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent
    # Gather every viable root, then pick Desktop-preferred.
    # The old early-return walked to a Downloads copy when the Desktop copy
    # also existed — Desktop must win.
    candidates: list[Path] = []

    # 1) walk up from exe / launcher dir
    cur = exe_dir.resolve()
    for _ in range(6):
        if is_mecai_root(cur):
            candidates.append(cur)
        if cur.parent == cur:
            break
        cur = cur.parent
    # dev launch: MECAI/deploy/launcher -> parents[2]
    if not getattr(sys, "frozen", False):
        maybe = walk_up(exe_dir, depth=3)
        if maybe and maybe not in candidates:
            candidates.append(maybe)

    # 2) scan filesystem candidates
    for cand in candidate_search_roots(exe_dir):
        try:
            if cand.is_dir() and is_mecai_root(cand) and cand.resolve() not in [c.resolve() for c in candidates]:
                candidates.append(cand.resolve())
        except Exception:
            if cand.is_dir() and is_mecai_root(cand):
                candidates.append(cand)
        # also scan children of any Desktop folder (handles renamed MECAI folder)
        if cand.name.lower() == "desktop" and cand.is_dir():
            try:
                for child in cand.iterdir():
                    if child.is_dir() and is_mecai_root(child):
                        try:
                            rc = child.resolve()
                        except Exception:
                            rc = child
                        if rc not in candidates:
                            candidates.append(rc)
                    elif (child / "pnpm-workspace.yaml").exists():
                        try:
                            rc = child.resolve()
                        except Exception:
                            rc = child
                        if rc not in candidates:
                            candidates.append(rc)
            except Exception:
                pass

    if not candidates:
        return None
    # Prefer Desktop — never auto-pick Downloads (user has stale copy there)
    non_dl = [c for c in candidates if not _is_downloads(c)]
    if not non_dl:
        # only Downloads copies exist — treat as not found so user must Browse to Desktop
        return None
    non_dl.sort(key=_score_root)
    return non_dl[0]

def is_bundle_root(root: Path) -> bool:
    return all((root / m).exists() for m in BUNDLE_MARKERS)

# ── IPs ───────────────────────────────────────────────────────────────────

def get_lan_ips() -> list[str]:
    ips: set[str] = set()
    # UDP trick — does not send, just reveals local address that would be used
    for target in [("8.8.8.8", 80), ("1.1.1.1", 80)]:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.settimeout(0.6)
            s.connect(target)
            ip = s.getsockname()[0]
            if ip and not ip.startswith("127."):
                ips.add(ip)
            s.close()
        except Exception:
            pass
    # hostname fallback
    try:
        for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
            if ip and not ip.startswith("127.") and "." in ip:
                ips.add(ip)
    except Exception:
        pass
    # ipconfig parsing fallback via powershell (windows only)
    if not ips and sys.platform == "win32":
        try:
            out = subprocess.check_output(
                ["powershell", "-NoProfile", "-Command",
                 r"(Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown'}).IPAddress"],
                text=True, timeout=4, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            for line in out.splitlines():
                line=line.strip()
                if line and "." in line and not line.startswith("127."):
                    ips.add(line)
        except Exception:
            pass
    return sorted(ips)

def check_tcp(host: str, port: int, timeout: float = 0.8) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except Exception:
        return False

def check_health(host: str, port: int, path: str = "/health", timeout: float = 1.2) -> bool:
    try:
        conn = http.client.HTTPConnection(host, port, timeout=timeout)
        conn.request("GET", path)
        r = conn.getresponse()
        ok = 200 <= r.status < 400
        conn.close()
        return ok
    except Exception:
        return False

# ── helpers ────────────────────────────────────────────────────────────────

def creation_flags():
    if sys.platform == "win32":
        return getattr(subprocess, "CREATE_NO_WINDOW", 0)
    return 0

def find_python() -> str | None:
    for cand in [r"py -3.12", r"py -3", "python", "python3", "python3.12"]:
        # py launcher needs shell
        if cand.startswith("py "):
            try:
                subprocess.check_output(cand + " --version", shell=True, stderr=subprocess.STDOUT, timeout=3, creationflags=creation_flags())
                return cand
            except Exception:
                continue
        else:
            try:
                subprocess.check_output([cand, "--version"], stderr=subprocess.STDOUT, timeout=3, creationflags=creation_flags())
                return cand
            except Exception:
                # try shell on Windows for shims
                try:
                    subprocess.check_output(cand + " --version", shell=True, stderr=subprocess.STDOUT, timeout=3, creationflags=creation_flags())
                    return cand
                except Exception:
                    continue
    return None

def get_venv_python(api_dir: Path) -> Path | None:
    # Cross-platform: Windows uses Scripts/python.exe, Linux uses bin/python
    for p in [
        api_dir / ".venv" / "Scripts" / "python.exe",
        api_dir / ".venv" / "Scripts" / "python",
        api_dir / ".venv" / "bin" / "python",
        api_dir / ".venv" / "bin" / "python3",
        api_dir / ".venv" / "bin" / "python3.12",
    ]:
        if p.exists() and p.is_file():
            return p
    return None

def run_stream(cmd, cwd: Path, q: queue.Queue, env=None, shell=False):
    """Run cmd, stream stdout+stderr line-by-line into q. Put None as sentinel when done. Return code via q."""
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            shell=shell,
            env=env,
            creationflags=creation_flags(),
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            q.put(("line", line.rstrip("\n")))
        proc.wait()
        q.put(("exit", proc.returncode))
    except Exception as e:
        q.put(("line", f"[error] {e}"))
        q.put(("exit", 1))

# ── GUI ───────────────────────────────────────────────────────────────────

BG = "#0b1220"
CARD = "#111d33"
INK = "#e6edf7"
MUTED = "#8aa0c2"
ACCENT = "#3b82f6"
ACCENT2 = "#22d3ee"
GOOD = "#22c55e"
WARN = "#f59e0b"
BAD = "#ef4444"

class Launcher(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("MEC-AI Launcher")
        self.geometry("720x760")
        self.minsize(700, 700)
        self.configure(bg=BG)
        # pids / procs
        self.api_proc: subprocess.Popen | None = None
        self.web_proc: subprocess.Popen | None = None
        self._api_starting = False
        self._web_starting = False
        self.root_path: Path | None = auto_detect_root()
        self._poll_after = None
        self._build_ui()
        if self.root_path:
            self.path_var.set(str(self.root_path))
            self.log(f"Auto-detected mecai folder: {self.root_path} (Desktop preferred; Downloads ignored)")
            self._refresh_ip()
        else:
            self.log("mecai folder not found on Desktop (Downloads is ignored). Use Browse or Auto-detect. Tip: put the whole mecai folder on the Desktop, then click Auto-detect.")
        self._poll_status()
        self.protocol("WM_DELETE_WINDOW", self.on_close)

    # ── UI ──
    def _build_ui(self):
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except Exception:
            pass
        style.configure("TFrame", background=BG)
        style.configure("Card.TFrame", background=CARD)
        style.configure("TLabel", background=BG, foreground=INK, font=("Segoe UI", 9))
        style.configure("Card.TLabel", background=CARD, foreground=INK)
        style.configure("Muted.TLabel", background=BG, foreground=MUTED, font=("Segoe UI", 8))
        style.configure("Title.TLabel", background=BG, foreground=INK, font=("Segoe UI", 16, "bold"))
        style.configure("H2.TLabel", background=CARD, foreground=INK, font=("Segoe UI", 10, "bold"))
        style.configure("TButton", font=("Segoe UI", 9))
        style.configure("Accent.TButton", font=("Segoe UI", 9, "bold"))
        style.configure("TEntry", fieldbackground="#0f1a30")

        # Header
        hdr = ttk.Frame(self, style="TFrame")
        hdr.pack(fill="x", padx=18, pady=(16, 8))
        ttk.Label(hdr, text="◆  MEC-AI", style="Title.TLabel").pack(side="left")
        ttk.Label(hdr, text="  Field launcher  •  Desktop preferred (Downloads ignored)  •  no terminal", style="Muted.TLabel").pack(side="left", padx=(8,0))
        self.version_lbl = ttk.Label(hdr, text="", style="Muted.TLabel")
        self.version_lbl.pack(side="right")

        # Path card
        card = tk.Frame(self, bg=CARD, highlightbackground="#1e335c", highlightthickness=1, bd=0)
        card.pack(fill="x", padx=16, pady=8)
        inner = tk.Frame(card, bg=CARD)
        inner.pack(fill="x", padx=14, pady=12)
        tk.Label(inner, text="mecai folder", bg=CARD, fg=MUTED, font=("Segoe UI", 8, "bold")).pack(anchor="w")
        row = tk.Frame(inner, bg=CARD)
        row.pack(fill="x", pady=(6,0))
        self.path_var = tk.StringVar()
        self.path_entry = tk.Entry(row, textvariable=self.path_var, bg="#0f1a30", fg=INK, insertbackground=INK,
                                   relief="flat", highlightthickness=1, highlightbackground="#233a66", highlightcolor=ACCENT,
                                   font=("Segoe UI", 9))
        self.path_entry.pack(side="left", fill="x", expand=True, ipady=6, padx=(0,8))
        tk.Button(row, text="Browse…", command=self.browse, bg="#162a4d", fg=INK, activebackground="#1b335c",
                  relief="flat", padx=14, pady=4, font=("Segoe UI", 9), cursor="hand2").pack(side="left", padx=2)
        tk.Button(row, text="Auto-detect", command=self.auto_detect, bg=ACCENT, fg="white", activebackground="#2563eb",
                  relief="flat", padx=12, pady=4, font=("Segoe UI", 9, "bold"), cursor="hand2").pack(side="left", padx=2)
        self.detect_lbl = tk.Label(inner, text="", bg=CARD, fg=MUTED, font=("Segoe UI", 8))
        self.detect_lbl.pack(anchor="w", pady=(6,0))
        self._update_detect_label()

        # IP card
        ip_card = tk.Frame(self, bg=CARD, highlightbackground="#1e335c", highlightthickness=1, bd=0)
        ip_card.pack(fill="x", padx=16, pady=6)
        ip_in = tk.Frame(ip_card, bg=CARD)
        ip_in.pack(fill="x", padx=14, pady=12)
        top = tk.Frame(ip_in, bg=CARD)
        top.pack(fill="x")
        tk.Label(top, text="Network — for Flutter app", bg=CARD, fg=MUTED, font=("Segoe UI", 8, "bold")).pack(side="left")
        tk.Button(top, text="↻ Refresh", command=self._refresh_ip, bg="#162a4d", fg=INK, relief="flat", padx=10, pady=2, font=("Segoe UI", 8), cursor="hand2").pack(side="right")
        tk.Button(top, text="Copy API URL", command=self.copy_api, bg="#162a4d", fg=INK, relief="flat", padx=10, pady=2, font=("Segoe UI", 8), cursor="hand2").pack(side="right", padx=4)
        self.ip_list = tk.Frame(ip_in, bg=CARD)
        self.ip_list.pack(fill="x", pady=(10,0))
        # placeholder filled by _refresh_ip

        # Status row
        stat_card = tk.Frame(self, bg=CARD, highlightbackground="#1e335c", highlightthickness=1, bd=0)
        stat_card.pack(fill="x", padx=16, pady=6)
        s_in = tk.Frame(stat_card, bg=CARD)
        s_in.pack(fill="x", padx=14, pady=12)
        self.api_dot = tk.Label(s_in, text="● API", bg=CARD, fg=MUTED, font=("Segoe UI", 10, "bold"))
        self.api_dot.pack(side="left", padx=(0,16))
        self.web_dot = tk.Label(s_in, text="● Web", bg=CARD, fg=MUTED, font=("Segoe UI", 10, "bold"))
        self.web_dot.pack(side="left", padx=16)
        self.stat_lbl = tk.Label(s_in, text="Idle", bg=CARD, fg=MUTED, font=("Segoe UI", 9))
        self.stat_lbl.pack(side="left", padx=16)
        tk.Button(s_in, text="Open Dashboard", command=self.open_dashboard, bg=ACCENT, fg="white", relief="flat", padx=12, pady=4, font=("Segoe UI", 9, "bold"), cursor="hand2").pack(side="right")
        tk.Button(s_in, text="API /docs", command=self.open_api_docs, bg="#162a4d", fg=INK, relief="flat", padx=10, pady=4, font=("Segoe UI", 9), cursor="hand2").pack(side="right", padx=4)

        # Controls
        ctrl = tk.Frame(self, bg=BG)
        ctrl.pack(fill="x", padx=16, pady=8)
        btns = [
            ("▶  Start Both", self.start_both, ACCENT),
            ("▶  Start API", self.start_api, "#162a4d"),
            ("▶  Start Web", self.start_web, "#162a4d"),
            ("■  Stop All", self.stop_all, "#3a1f2a"),
            ("⟳  Update (git pull)", self.do_update, "#0f2a1a"),
        ]
        for i, (txt, cmd, bg) in enumerate(btns):
            fg = "white" if bg == ACCENT else INK
            if bg == "#0f2a1a":
                fg = "#86efac"
            if bg == "#3a1f2a":
                fg = "#fca5a5"
            b = tk.Button(ctrl, text=txt, command=cmd, bg=bg, fg=fg, activebackground="#1e335c" if bg!="#3a1f2a" else "#4a2530",
                          relief="flat", padx=8, pady=10, font=("Segoe UI", 9, "bold"), cursor="hand2", bd=0)
            b.grid(row=0, column=i, padx=3, sticky="ew")
            ctrl.grid_columnconfigure(i, weight=1)
        # Second row: desktop shortcut
        ctrl2 = tk.Frame(self, bg=BG)
        ctrl2.pack(fill="x", padx=16, pady=(0,8))
        tk.Button(ctrl2, text="★ Create Desktop Shortcut", command=self.create_shortcut, bg="#1a2744", fg="#9ec5ff",
                  relief="flat", padx=10, pady=6, font=("Segoe UI", 8, "bold"), cursor="hand2").pack(side="left")
        tk.Label(ctrl2, text="  puts MEC-AI.lnk on Desktop → one click to this launcher", bg=BG, fg=MUTED, font=("Segoe UI", 8)).pack(side="left")

        # Log
        log_card = tk.Frame(self, bg=CARD, highlightbackground="#1e335c", highlightthickness=1, bd=0)
        log_card.pack(fill="both", expand=True, padx=16, pady=(6, 12))
        log_head = tk.Frame(log_card, bg=CARD)
        log_head.pack(fill="x", padx=14, pady=(10,0))
        tk.Label(log_head, text="Log", bg=CARD, fg=MUTED, font=("Segoe UI", 8, "bold")).pack(side="left")
        tk.Button(log_head, text="Clear", command=lambda: self.log_widget.configure(state="normal") or self.log_widget.delete("1.0","end") or self.log_widget.configure(state="disabled"),
                  bg="#162a4d", fg=INK, relief="flat", padx=8, pady=1, font=("Segoe UI", 8), cursor="hand2").pack(side="right")
        tk.Button(log_head, text="Copy", command=self.copy_log,
                  bg="#162a4d", fg=INK, relief="flat", padx=8, pady=1, font=("Segoe UI", 8), cursor="hand2").pack(side="right", padx=4)
        frame = tk.Frame(log_card, bg=CARD)
        frame.pack(fill="both", expand=True, padx=14, pady=(6,12))
        self.log_widget = tk.Text(frame, bg="#0a1222", fg="#c9d6ee", insertbackground=INK,
                                  relief="flat", highlightthickness=1, highlightbackground="#233a66",
                                  font=("Cascadia Code", 8) if sys.platform=="win32" else ("TkFixedFont", 8),
                                  wrap="word", state="disabled")
        sb = tk.Scrollbar(frame, command=self.log_widget.yview)
        self.log_widget.configure(yscrollcommand=sb.set)
        self.log_widget.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")

        # Bottom bar
        bar = tk.Frame(self, bg="#0a1222", highlightbackground="#1e335c", highlightthickness=1)
        bar.pack(fill="x", side="bottom")
        self.bottom = tk.Label(bar, text="Ready.", bg="#0a1222", fg=MUTED, font=("Segoe UI", 8), anchor="w", padx=12, pady=6)
        self.bottom.pack(fill="x")

    # ── path helpers ──
    def _update_detect_label(self):
        p = self.path_var.get().strip()
        if not p:
            self.detect_lbl.config(text="No folder selected", fg=WARN)
            return
        root = Path(p)
        if _is_downloads(root):
            self.detect_lbl.config(text="⚠ Downloads folder — move mecai to Desktop and use Auto-detect. Downloads copy is ignored by auto-detect.", fg=WARN)
            return
        if is_bundle_root(root):
            self.detect_lbl.config(text="✓ Bundle detected (MEC-AI-Windows) — will use api/MEC-AI-API.exe + web/server.js", fg=GOOD)
        elif is_mecai_root(root):
            # count git
            git_ok = (root / ".git").exists()
            tag = " • git ✓" if git_ok else " • no .git (update disabled)"
            self.detect_lbl.config(text=f"✓ mecai repo detected{tag}", fg=GOOD if git_ok else WARN)
        else:
            self.detect_lbl.config(text="✗ Not a mecai folder (missing pnpm-workspace.yaml / services/api/pyproject.toml)", fg=BAD)

    def browse(self):
        d = filedialog.askdirectory(title="Select mecai folder")
        if d:
            self.path_var.set(d)
            self.root_path = Path(d)
            self._update_detect_label()
            self.log(f"Selected: {d}")
            self._refresh_ip()

    def auto_detect(self):
        found = auto_detect_root()
        if found:
            self.path_var.set(str(found))
            self.root_path = found
            self._update_detect_label()
            self.log(f"Auto-detected: {found}")
            self._refresh_ip()
        else:
            # Check if we ignored a Downloads copy — tell user why
            dl_hint = ""
            try:
                exe_dir = Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent
                for cand in candidate_search_roots(exe_dir):
                    if _is_downloads(cand) and cand.is_dir() and is_mecai_root(cand):
                        dl_hint = f"\n\nFound a copy in Downloads ({cand}) but it is ignored — please use the Desktop copy. Move mecai to Desktop and click Auto-detect again."
                        break
                if not dl_hint:
                    # also check Desktop children for downloads-like name? not needed
                    pass
            except Exception:
                pass
            messagebox.showinfo("Not found", "Could not find mecai on Desktop automatically.\n\nTried: Desktop/mecai, exe folder parents, %USERPROFILE%/mecai (Downloads is ignored)." + dl_hint + "\n\nUse Browse to pick the folder that contains pnpm-workspace.yaml.")
            self.log("Auto-detect failed — ask user to Browse" + (f" (ignored Downloads copy at {dl_hint})" if dl_hint else ""))

    def current_root(self) -> Path | None:
        p = self.path_var.get().strip().strip('"')
        if not p:
            return None
        pp = Path(p)
        if not pp.exists():
            return None
        # if they selected a subfolder, walk up
        if is_mecai_root(pp):
            return pp
        found = walk_up(pp, depth=3)
        return found or (pp if is_mecai_root(pp) else None)

    # ── IPs ──
    def _refresh_ip(self):
        for w in self.ip_list.winfo_children():
            w.destroy()
        ips = get_lan_ips()
        root = self.current_root()
        # also show localhost always
        rows: list[tuple[str,str]] = []
        if ips:
            for ip in ips:
                rows.append((ip, ip))
        else:
            rows.append(("127.0.0.1", "127.0.0.1 (no LAN — check Wi-Fi)"))
        for ip, label in rows:
            r = tk.Frame(self.ip_list, bg=CARD)
            r.pack(fill="x", pady=2)
            dot = "●" if ip != "127.0.0.1" else "○"
            col = GOOD if ip != "127.0.0.1" else MUTED
            tk.Label(r, text=dot, bg=CARD, fg=col, font=("Segoe UI", 9, "bold")).pack(side="left")
            tk.Label(r, text=f"  {label}", bg=CARD, fg=INK, font=("Segoe UI", 9)).pack(side="left")
            urls = tk.Frame(r, bg=CARD)
            urls.pack(side="right")
            for label_txt, port, suffix in [("API", 8000, ""), ("Dashboard", 3000, "/dashboard")]:
                url = f"http://{ip}:{port}{suffix}"
                def _copy(u=url):
                    self.clipboard_clear(); self.clipboard_append(u); self.bottom.config(text=f"Copied {u}")
                tk.Button(urls, text=f"{label_txt}  {url}", command=_copy, bg="#0f1a30", fg="#9ec5ff", relief="flat",
                          font=("Segoe UI", 8), cursor="hand2", padx=6, pady=2).pack(side="left", padx=2)
        if not ips:
            tk.Label(self.ip_list, text="No LAN address found — connect to Wi-Fi/LAN. Flutter should use 127.0.0.1 only when running on the same PC.", bg=CARD, fg=WARN, font=("Segoe UI", 8), wraplength=640, justify="left").pack(anchor="w", pady=(6,0))

    def copy_api(self):
        ips = get_lan_ips()
        ip = ips[0] if ips else "127.0.0.1"
        url = f"http://{ip}:8000"
        self.clipboard_clear(); self.clipboard_append(url)
        self.bottom.config(text=f"Copied {url}")
        self.log(f"Copied {url}")

    def copy_log(self):
        txt = self.log_widget.get("1.0","end-1c")
        self.clipboard_clear(); self.clipboard_append(txt)

    def create_shortcut(self):
        # Locate the exe to point to
        if getattr(sys, "frozen", False):
            target = Path(sys.executable)
        else:
            # dev: point to the built exe if it exists, else this .py via pythonw
            built = Path(__file__).resolve().parent / "dist/MECAI-Launcher.exe"
            if built.exists():
                target = built
            else:
                messagebox.showinfo("Build first", "Run deploy/launcher/build.bat to build MECAI-Launcher.exe first.\n\nAlternatively a shortcut to this folder will be created.")
                target = Path(__file__).resolve().parent
        root = self.current_root()
        workdir = str(root) if root else str(target.parent)
        if sys.platform != "win32":
            self.log("[shortcut] only on Windows — copy the folder to Desktop instead")
            return
        ps = f'''
$WshShell = New-Object -comObject WScript.Shell
$lnk = $WshShell.CreateShortcut("$env:USERPROFILE\\Desktop\\MEC-AI.lnk")
$lnk.TargetPath = "{target}"
$lnk.WorkingDirectory = "{workdir}"
$lnk.Description = "MEC-AI — Start API + Dashboard"
$lnk.Save()
Write-Host "OK $lnk"
'''
        try:
            subprocess.run(["powershell", "-NoProfile", "-Command", ps], creationflags=creation_flags(), timeout=6, check=False)
            self.log("Created Desktop shortcut: %USERPROFILE%\\Desktop\\MEC-AI.lnk")
            self.bottom.config(text="Shortcut created on Desktop")
            messagebox.showinfo("Done", "Shortcut created on Desktop → MEC-AI.lnk\n\nDouble-click it to open the launcher from the Desktop.")
        except Exception as e:
            self.log(f"[shortcut] {e}")
            messagebox.showerror("Failed", str(e))

    # ── open ──
    def open_dashboard(self):
        root = self.current_root()
        ips = get_lan_ips()
        ip = ips[0] if ips else "127.0.0.1"
        url = "http://127.0.0.1:3000/dashboard"
        lan = f"http://{ip}:3000/dashboard"
        self.log(f"Opening {url} (LAN: {lan})")
        self._open_url(url)

    def open_api_docs(self):
        self._open_url("http://127.0.0.1:8000/docs")

    def _open_url(self, url: str):
        try:
            import webbrowser
            webbrowser.open(url)
        except Exception as e:
            self.log(f"[open] {e}")

    # ── log ──
    def log(self, msg: str):
        def _do():
            self.log_widget.configure(state="normal")
            self.log_widget.insert("end", msg + "\n")
            self.log_widget.see("end")
            self.log_widget.configure(state="disabled")
        # thread-safe
        try:
            self.after(0, _do)
        except Exception:
            pass
        # also if called from UI thread, run now
        if threading.current_thread() is threading.main_thread():
            try:
                self.log_widget.configure(state="normal")
                self.log_widget.insert("end", msg + "\n")
                self.log_widget.see("end")
                self.log_widget.configure(state="disabled")
            except Exception:
                pass

    # ── status poll ──
    def _poll_status(self):
        api_up = check_tcp("127.0.0.1", 8000) or check_health("127.0.0.1", 8000)
        web_up = check_tcp("127.0.0.1", 3000)
        # prefer proc liveness if we launched
        if self.api_proc is not None and self.api_proc.poll() is not None:
            api_up = False
            self.log(f"[api] exited with {self.api_proc.returncode}")
            self.api_proc = None
        if self.web_proc is not None and self.web_proc.poll() is not None:
            web_up = False
            self.log(f"[web] exited with {self.web_proc.returncode}")
            self.web_proc = None
        self.api_dot.config(fg=GOOD if api_up else BAD if self.api_proc else MUTED, text="● API  running" if api_up else "● API  stopped")
        self.web_dot.config(fg=GOOD if web_up else BAD if self.web_proc else MUTED, text="● Web  running" if web_up else "● Web  stopped")
        if api_up and web_up:
            self.stat_lbl.config(text="Both running", fg=GOOD)
        elif api_up or web_up:
            self.stat_lbl.config(text="Partial", fg=WARN)
        else:
            self.stat_lbl.config(text="Stopped", fg=MUTED)
        self._poll_after = self.after(1500, self._poll_status)

    # ── start/stop ──
    def start_both(self):
        self.start_api()
        # stagger
        self.after(1200, self.start_web)

    def start_api(self):
        root = self.current_root()
        if not root:
            messagebox.showwarning("Pick folder", "Select the mecai folder first.")
            return
        self._update_detect_label()
        if self.api_proc and self.api_proc.poll() is None:
            self.log("[api] already running")
            return
        if self._api_starting:
            self.log("[api] already starting…")
            return
        bundle = is_bundle_root(root)
        q: queue.Queue = queue.Queue()
        self._api_starting = True
        if bundle:
            exe = root / "api/MEC-AI-API.exe"
            if not exe.exists():
                messagebox.showerror("Missing", f"Not found: {exe}")
                return
            env = os.environ.copy()
            # load bundle .env if present
            env_file = root / ".env"
            if env_file.exists():
                try:
                    for line in env_file.read_text().splitlines():
                        line=line.strip()
                        if not line or line.startswith("#") or "=" not in line: continue
                        k,v=line.split("=",1)
                        env[k.strip()] = v.strip().strip('"').strip("'")
                except Exception:
                    pass
            env.setdefault("MECAI_HOST", "0.0.0.0")
            env.setdefault("MECAI_PORT", "8000")
            env.setdefault("MECAI_DATABASE_PATH", str(root / "data/mecai.db"))
            cmd = [str(exe)]
            cwd = root
            self.log(f"[api] bundle: {exe}")
            def _run():
                try:
                    self.api_proc = subprocess.Popen(cmd, cwd=str(cwd), env=env, creationflags=creation_flags())
                    q.put(("line", f"[api] pid {self.api_proc.pid}"))
                    q.put(("exit", 0))
                except Exception as e:
                    q.put(("line", f"[api] failed: {e}"))
                    q.put(("exit", 1))
            threading.Thread(target=_run, daemon=True).start()
        else:
            # dev mode: venv python — cross-platform
            api_dir = root / "services/api"
            venv_dir = api_dir / ".venv"
            venv_py = get_venv_python(api_dir)
            # ensure venv
            if venv_py is None:
                self.log("[api] creating venv + installing deps (one-time)…")
                # run synchronously streamed so log shows progress
                def _setup_and_start():
                    py_cmd = find_python()
                    if not py_cmd:
                        q.put(("line", "[api] Python 3.12 not found. Install Python 3.12 and retry."))
                        q.put(("exit", 1)); return
                    # venv
                    code = subprocess.call(f'{py_cmd} -m venv "{venv_dir}"', shell=True, creationflags=creation_flags())
                    if code != 0:
                        q.put(("line", f"[api] venv creation failed (code {code}) — tried: {py_cmd} -m venv"))
                        q.put(("exit", 1)); return
                    # re-locate venv python after creation (bin/ on Linux, Scripts/ on Windows)
                    new_py = get_venv_python(api_dir)
                    if new_py is None:
                        q.put(("line", f"[api] venv created but python not found at {venv_dir}/bin/python nor Scripts/python.exe"))
                        q.put(("exit", 1)); return
                    q.put(("line", f"[api] venv ready: {new_py}"))
                    q.put(("line", "[api] upgrading pip…"))
                    subprocess.call([str(new_py), "-m", "pip", "install", "--upgrade", "pip"], creationflags=creation_flags())
                    q.put(("line", "[api] installing mecai_api…"))
                    code2 = subprocess.call([str(new_py), "-m", "pip", "install", "-e", str(api_dir)], creationflags=creation_flags())
                    if code2 != 0:
                        q.put(("line", "[api] pip install failed"))
                        q.put(("exit", 1)); return
                    self._spawn_api_dev(new_py, root, q)
                threading.Thread(target=_setup_and_start, daemon=True).start()
            else:
                self.log(f"[api] using existing venv: {venv_py}")
                threading.Thread(target=lambda: self._spawn_api_dev(venv_py, root, q), daemon=True).start()
        # stream q to log
        def _drain():
            try:
                while True:
                    typ, val = q.get(timeout=0.1)
                    if typ == "line":
                        self.log(val)
                    elif typ == "exit":
                        self._api_starting = False
                        if val != 0:
                            self.log(f"[api] exit {val}")
                        break
            except queue.Empty:
                pass
            # if queue still has data, keep draining; otherwise ensure flag cleared if done
            if not q.empty():
                self.after(100, _drain)
            elif self._api_starting and q.empty():
                # _spawn_api_dev will push exit later; keep polling
                self.after(150, _drain)
        self.after(100, _drain)
        # safety: clear starting flag after 4s even if drain hasn't seen exit (dev mode spawns long-runner)
        self.after(4000, lambda: setattr(self, '_api_starting', False))

    def _spawn_api_dev(self, venv_py: Path, root: Path, q: queue.Queue):
        try:
            env = os.environ.copy()
            env["MECAI_HOST"] = "0.0.0.0"
            env["MECAI_PORT"] = "8000"
            env["MECAI_ENABLE_MOCK_ENDPOINTS"] = "false"
            env["MECAI_DATABASE_PATH"] = str(root / "services/api/.data/mecai.db")
            # also allow host/port env for bundle compat
            cmd = [str(venv_py), "-m", "uvicorn", "mecai_api.main:app", "--host", "0.0.0.0", "--port", "8000"]
            self.log(f"[api] {' '.join(cmd)}")
            self.api_proc = subprocess.Popen(cmd, cwd=str(root / "services/api"), env=env, creationflags=creation_flags(),
                                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
            # stream output to log
            assert self.api_proc.stdout
            for line in self.api_proc.stdout:
                self.log(f"[api] {line.rstrip()}")
            self.api_proc.wait()
            q.put(("exit", self.api_proc.returncode or 0))
        except Exception as e:
            self.log(f"[api] spawn failed: {e}")
            q.put(("exit", 1))

    def start_web(self):
        root = self.current_root()
        if not root:
            messagebox.showwarning("Pick folder", "Select the mecai folder first.")
            return
        if self.web_proc and self.web_proc.poll() is None:
            self.log("[web] already running")
            return
        if self._web_starting:
            self.log("[web] already starting…")
            return
        self._web_starting = True
        bundle = is_bundle_root(root)
        if bundle:
            node = root / "web/node.exe"
            server = root / "web/server.js"
            if not server.exists():
                # fallback web/server.js inside .next/standalone
                server = root / "web/.next/standalone/server.js"
            if not node.exists():
                # try system node
                node = Path("node")
            if not server.exists():
                self._web_starting = False
                messagebox.showerror("Missing", f"Web server not found: {server}\nRebuild with pnpm --dir apps/web build")
                return
            env = os.environ.copy()
            env["HOSTNAME"] = "0.0.0.0"
            env["PORT"] = "3000"
            # bundle uses 127.0.0.1 for API by default; LAN needs host 0.0.0.0 already
            cmd = [str(node), str(server)]
            self.log(f"[web] bundle: {' '.join(cmd)}")
            try:
                self.web_proc = subprocess.Popen(cmd, cwd=str(root), env=env, creationflags=creation_flags())
                self.log(f"[web] pid {self.web_proc.pid} — opening http://127.0.0.1:3000/dashboard in 2s")
                self.after(2000, lambda: self._open_url("http://127.0.0.1:3000/dashboard"))
            except Exception as e:
                self.log(f"[web] failed: {e}")
                messagebox.showerror("Start failed", str(e))
            finally:
                self.after(1500, lambda: setattr(self, '_web_starting', False))
            return
        # dev mode
        web_dir = root / "apps/web"
        if not (web_dir / "package.json").exists():
            self._web_starting = False
            messagebox.showerror("Missing", f"Not found: {web_dir / 'package.json'}")
            return
        # prefer pnpm
        # use dev.bat hidden but we can call directly
        env = os.environ.copy()
        env["HOSTNAME"] = "0.0.0.0"
        env["PORT"] = "3000"
        # kill stale port holders like start-web.bat does (optional)
        # spawn next dev hidden
        # try pnpm, then npm — on Windows these are .cmd shims so need shell
        cmd_str: str | None = None
        cmd_list: list[str] | None = None
        is_win = sys.platform == "win32"
        try:
            subprocess.check_output("pnpm --version", shell=True, creationflags=creation_flags(), timeout=3, stderr=subprocess.STDOUT, text=True)
            cmd_str = f'pnpm --dir "{web_dir}" dev'
            cmd_list = ["pnpm", "--dir", str(web_dir), "dev"]
        except Exception:
            try:
                subprocess.check_output("npm --version", shell=True, creationflags=creation_flags(), timeout=3, stderr=subprocess.STDOUT, text=True)
                cmd_str = f'npm --prefix "{web_dir}" run dev'
                cmd_list = ["npm", "--prefix", str(web_dir), "run", "dev"]
            except Exception:
                self._web_starting = False
                messagebox.showerror("Node missing", "Node.js not found. Install Node 20+ then retry.")
                return
        assert cmd_str is not None and cmd_list is not None
        self.log(f"[web] {cmd_str}  (HOST=0.0.0.0 PORT=3000)")
        try:
            # shell=True on Windows for .cmd resolution; list without shell on posix
            if is_win:
                self.web_proc = subprocess.Popen(cmd_str, cwd=str(root), env=env, shell=True, creationflags=creation_flags(),
                                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
            else:
                self.web_proc = subprocess.Popen(cmd_list, cwd=str(root), env=env, creationflags=creation_flags(),
                                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
            # stream first lines to log, then background
            def _stream():
                assert self.web_proc and self.web_proc.stdout
                for line in self.web_proc.stdout:
                    self.log(f"[web] {line.rstrip()}")
                if self.web_proc:
                    self.log(f"[web] exited {self.web_proc.poll()}")
            threading.Thread(target=_stream, daemon=True).start()
            self.after(2500, lambda: self._open_url("http://127.0.0.1:3000/dashboard"))
        except Exception as e:
            self.log(f"[web] failed: {e}")
            messagebox.showerror("Start failed", str(e))
        finally:
            self.after(1500, lambda: setattr(self, '_web_starting', False))

    def stop_all(self):
        killed = 0
        for name, proc in [("api", self.api_proc), ("web", self.web_proc)]:
            if proc and proc.poll() is None:
                try:
                    proc.terminate()
                    try:
                        proc.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                    self.log(f"[{name}] stopped")
                    killed += 1
                except Exception as e:
                    self.log(f"[{name}] stop error: {e}")
        self.api_proc = None
        self.web_proc = None
        # also taskkill by windowtitle/port as fallback (Windows)
        if sys.platform == "win32":
            try:
                subprocess.call('taskkill /FI "WINDOWTITLE eq MEC-AI API*" /T /F', shell=True, creationflags=creation_flags(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.call('taskkill /FI "WINDOWTITLE eq MEC-AI Dashboard*" /T /F', shell=True, creationflags=creation_flags(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                # kill by port
                for port in [8000, 3000]:
                    try:
                        out = subprocess.check_output(f'netstat -aon | findstr :{port} | findstr LISTENING', shell=True, text=True, creationflags=creation_flags(), timeout=3)
                        for line in out.splitlines():
                            parts = line.strip().split()
                            if parts:
                                pid = parts[-1]
                                subprocess.call(f"taskkill /PID {pid} /F", shell=True, creationflags=creation_flags(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    except Exception:
                        pass
            except Exception:
                pass
        if killed == 0:
            self.log("Nothing to stop.")
        self.bottom.config(text="Stopped.")

    # ── update ──
    def do_update(self):
        root = self.current_root()
        if not root:
            messagebox.showwarning("Pick folder", "Select the mecai folder first.")
            return
        if not (root / ".git").exists():
            messagebox.showinfo("Not a git checkout", f"No .git at {root}\n\nThis looks like a bundled release (MEC-AI-Windows). Re-download the zip for updates, or use the source git clone to get git updates.")
            return
        # check git present
        try:
            subprocess.check_output(["git", "--version"], creationflags=creation_flags(), timeout=3)
        except Exception:
            messagebox.showerror("Git missing", "Git for Windows not found. Install from https://git-scm.com/download/win")
            return
        # warn dirty
        try:
            dirty = subprocess.check_output(["git", "-C", str(root), "status", "--porcelain"], text=True, creationflags=creation_flags(), timeout=5).strip()
            if dirty:
                if not messagebox.askyesno("Local changes", "Local changes detected:\n\n" + dirty[:1200] + "\n\nPull anyway? (may fail or conflict)"):
                    return
        except Exception:
            pass
        self.log(f"[update] git -C {root} pull --ff-only origin main")
        self.bottom.config(text="Updating…")
        q: queue.Queue = queue.Queue()
        def _run():
            run_stream(["git", "-C", str(root), "pull", "--ff-only", "origin", "main"], root, q, shell=False)
        threading.Thread(target=_run, daemon=True).start()
        def _drain():
            got_exit = None
            try:
                while True:
                    typ, val = q.get_nowait()
                    if typ == "line":
                        self.log(val)
                    else:
                        got_exit = val
                        if val == 0:
                            self.log("[update] pull ok — installing deps if needed…")
                            self._post_pull_install(root)
                        else:
                            self.log(f"[update] pull failed exit {val}")
                            self.bottom.config(text="Update failed")
                        break
            except queue.Empty:
                pass
            if got_exit is None:
                self.after(120, _drain)
            else:
                # refresh detect
                self._update_detect_label()
        self.after(120, _drain)

    def _post_pull_install(self, root: Path):
        # npm deps: run hidden pnpm install or npm install if lock changed
        def _do():
            try:
                # Python deps first: a pull can add requirements to
                # services/api/pyproject.toml (zeroconf for server discovery
                # did), and the API imports them at startup. Re-running the
                # editable install is a fast no-op when everything is already
                # satisfied.
                api_dir = root / "services/api"
                venv_py = get_venv_python(api_dir)
                if venv_py is None:
                    self.log("[update] no API venv yet — it will be created on next Start API")
                else:
                    self.log("[update] refreshing API dependencies (pip install -e)…")
                    code = subprocess.call(
                        [str(venv_py), "-m", "pip", "install", "-q", "-e", str(api_dir)],
                        creationflags=creation_flags(),
                    )
                    self.log(f"[update] pip exit {code}")

                web_dir = root / "apps/web"
                is_win = sys.platform == "win32"
                if (root / "pnpm-lock.yaml").exists():
                    self.log("[update] pnpm install --frozen-lockfile (web)…")
                    if is_win:
                        code = subprocess.call('pnpm install --frozen-lockfile', shell=True, cwd=str(root), creationflags=creation_flags())
                    else:
                        code = subprocess.call(["pnpm", "install", "--frozen-lockfile"], cwd=str(root), creationflags=creation_flags())
                    self.log(f"[update] pnpm exit {code}")
                elif (web_dir / "package.json").exists():
                    self.log("[update] npm install --prefix apps/web…")
                    if is_win:
                        code = subprocess.call(f'npm install --prefix "{web_dir}"', shell=True, cwd=str(root), creationflags=creation_flags())
                    else:
                        code = subprocess.call(["npm", "install", "--prefix", str(web_dir)], cwd=str(root), creationflags=creation_flags())
                    self.log(f"[update] npm exit {code}")
                self.log("[update] done. Click Start Both to relaunch.")
                self.bottom.config(text="Update complete")
            except Exception as e:
                self.log(f"[update] install error: {e}")
                self.bottom.config(text="Update install failed")
        threading.Thread(target=_do, daemon=True).start()

    def on_close(self):
        if (self.api_proc and self.api_proc.poll() is None) or (self.web_proc and self.web_proc.poll() is None):
            if not messagebox.askyesno("Quit", "Servers are still running. Stop them and quit?"):
                return
            self.stop_all()
        if self._poll_after:
            try: self.after_cancel(self._poll_after)
            except Exception: pass
        self.destroy()

def main():
    # High DPI aware on Windows
    if sys.platform == "win32":
        try:
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except Exception:
            pass
    app = Launcher()
    app.mainloop()

if __name__ == "__main__":
    main()
