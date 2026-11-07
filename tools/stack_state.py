"""Read-only, instance-scoped launcher state and identity-checked process stop.

No account, token, command line or raw exception is printed. TCP listeners alone
never grant ownership. QQ and A.I.VOICE Editor are never stop candidates.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import sys
import time
import urllib.request


KINDS = {"backend", "snowluma", "ollama", "watch", "voice_bridge", "relogin"}


def _load_backend(root):
    path = Path(root) / "tools" / "backend_state.py"
    spec = importlib.util.spec_from_file_location("_launcher_backend_state", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _safe_json(path):
    try:
        value = Path(path).read_text(encoding="utf-8-sig")
        result = json.loads(value)
        return result if isinstance(result, dict) else {}
    except (OSError, UnicodeError, ValueError):
        return {}


def _default_get_json(url):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(url, timeout=2) as response:
            value = json.loads(response.read(262144).decode("utf-8-sig"))
        return value if isinstance(value, dict) else None
    except Exception:
        return None


def _created(process):
    try:
        value = float(process.get("create", 0))
        return value if math.isfinite(value) and value > 0 else 0.0
    except (ValueError, TypeError, OverflowError):
        return 0.0


def _refs(processes):
    return [{"pid": int(p["pid"]), "created": _created(p)}
            for p in processes if int(p.get("pid", 0)) > 4 and _created(p)]


def _script_entry(process, expected, backend):
    """Match a real PowerShell -File argument, not text inside -Command."""
    args = backend._command_args(process.get("cmd", ""))
    for index, arg in enumerate(args[:-1]):
        if arg in {"-command", "-c", "-encodedcommand", "-enc"}:
            return False
        if arg in {"-file", "-f"}:
            return backend.norm(args[index + 1]) == backend.norm(expected)
    return False


def _watch_entry(process, root, backend):
    kind, entry = backend._python_entry(process)
    if kind != "file" or backend.norm(entry) != backend.norm(root / "tools" / "qq_watch.py"):
        return False
    args = backend._command_args(process.get("cmd", ""))
    for index, arg in enumerate(args[:-1]):
        if arg == "--dir":
            return backend.norm(args[index + 1]) == backend.norm(root)
    # The installed tools/qq_watch.py defaults to its own parent directory.
    return True


def _node_entry(process, root, backend):
    args = backend._command_args(process.get("cmd", ""))
    if len(args) < 2:
        return False
    for arg in args[1:]:
        if arg.startswith("-"):
            continue
        return arg in {"index.mjs", "./index.mjs"} or backend.norm(arg) == backend.norm(root / "SnowLuma" / "index.mjs")
    return False


def inspect_stack(directory, *, backend=None, snap=None, get_json=None, probe_api=True):
    root = Path(directory).resolve()
    backend = backend or _load_backend(root)
    snapshot = backend.snapshot() if snap is None else snap
    raw = snapshot.get("procs", [])
    listening = snapshot.get("listen", {})
    session = backend._windows_session_id(os.getpid())

    # A known user name alone is insufficient when that same user has two logons.
    processes = [p for p in raw if session is not None
                 and backend._windows_session_id(p.get("pid", 0)) == session]
    brain = [p for p in processes if backend._cli_process(p, root)]
    if not (root / "start-astrbot.cmd").exists():
        # Resolve the pinned launcher first; an arbitrary main.py is not ours.
        resolved = backend.resolve(root, repair=False, snap=snapshot)
        main = Path(resolved.get("instance", "")) / "core" / "main.py"
        brain = [p for p in processes if resolved.get("instance") and backend._main_process(p, main)]
    else:
        resolved = backend.resolve(root, repair=False, snap=snapshot)

    snow, ollama, watch, bridges, relogins, qq = [], [], [], [], [], []
    unknown = {kind: session is None for kind in KINDS}
    qq_unknown = session is None
    official_qq = {
        backend.norm(Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Tencent" / "QQNT" / "QQ.exe"),
        backend.norm(Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Tencent" / "QQNT" / "QQ.exe"),
    }
    for process in processes:
        exe = process.get("exe", "")
        name = str(process.get("name", "")).lower()
        leaf = str(exe).replace("\\", "/").rsplit("/", 1)[-1].lower()
        has_command = bool(process.get("cmd"))
        if backend.within(exe, root / "SnowLuma") and leaf == "node.exe":
            if has_command and _node_entry(process, root, backend):
                snow.append(process)
            else:
                unknown["snowluma"] = True
        if backend.within(exe, root / "Ollama") and leaf in {"ollama.exe", "ollama app.exe", "ollama_llama_server.exe"}:
            args = backend._command_args(process.get("cmd", ""))
            if any(arg in {"serve", "runner"} for arg in args[1:]) or leaf in {"ollama app.exe", "ollama_llama_server.exe"}:
                ollama.append(process)
            else:
                unknown["ollama"] = True
        if leaf in {"python.exe", "pythonw.exe"} and (
                backend.within(exe, root / "tools" / "python") or backend.within(exe, root / "uv")):
            if has_command and _watch_entry(process, root, backend):
                watch.append(process)
            elif not has_command and leaf == "pythonw.exe":
                unknown["watch"] = True
        if leaf in {"powershell.exe", "pwsh.exe"}:
            if _script_entry(process, root / "tools" / "aivoice-daemon.ps1", backend):
                bridges.append(process)
            if _script_entry(process, root / "tools" / "relogin-qq.ps1", backend):
                # An explicit --Dir for a sibling installation must not be owned.
                args = backend._command_args(process.get("cmd", ""))
                directories = [args[i + 1] for i, arg in enumerate(args[:-1]) if arg in {"-dir", "--dir"}]
                if not directories or all(backend.norm(d) == backend.norm(root) for d in directories):
                    relogins.append(process)
        if leaf == "qq.exe" and backend.norm(exe) in official_qq:
            qq.append(process)
        elif name == "qq.exe" and not exe:
            qq_unknown = True

    # State files can help avoid duplicate starts, but never authorize stopping a
    # process whose entry point is hidden or whose PID has been reused.
    heartbeat = _safe_json(root / "logs" / "qq-watch.json")
    heartbeat_live = False
    try:
        age = time.time() - float(heartbeat.get("at", 0))
        candidate = next((p for p in processes if p.get("pid") == heartbeat.get("pid")), None)
        heartbeat_live = bool(candidate and 0 <= age <= 180 and _created(candidate)
                              and _created(candidate) <= float(heartbeat["at"])
                              and (backend.within(candidate.get("exe", ""), root / "tools" / "python")
                                   or backend.within(candidate.get("exe", ""), root / "uv")))
    except (ValueError, TypeError, KeyError, OverflowError):
        pass
    if heartbeat_live and not watch:
        unknown["watch"] = True
    elif not watch:
        try:
            heartbeat_pid = int(heartbeat.get("pid", 0))
            age = time.time() - float(heartbeat.get("at", 0))
            if heartbeat_pid > 4 and 0 <= age <= 180 and session is not None and backend._windows_session_id(heartbeat_pid) == session:
                unknown["watch"] = True
        except (ValueError, TypeError, OverflowError):
            pass

    def conflict(port, candidates, accepted=None):
        if port not in listening:
            return False
        pids = {p["pid"] for p in candidates}
        if accepted:
            pids.add(accepted)
        return listening.get(port) not in pids

    backend_pid = resolved.get("pid", 0)
    backend_up = resolved.get("state") == "up"
    unknown["backend"] |= bool(backend_up and backend_pid not in {p["pid"] for p in brain})
    brain_ports = [int(resolved.get("port") or 6185), int(resolved.get("ws_port") or 6199)]
    brain_conflict = any(conflict(port, brain, backend_pid if backend_up else None) for port in brain_ports)
    ws_port = int(resolved.get("ws_port") or 0)
    ws_ready = bool(ws_port and listening.get(ws_port) in ({p["pid"] for p in brain} | ({backend_pid} if backend_up else set())))
    tag_data = (get_json or _default_get_json)("http://127.0.0.1:11434/api/tags") if probe_api else None
    tags = tag_data.get("models") if isinstance(tag_data, dict) else None
    api_ready = isinstance(tags, list)
    model_available = bool(api_ready and any(isinstance(item, dict) and str(item.get("name") or item.get("model") or "").split(":", 1)[0] == "bge-m3" for item in tags))
    ollama_pids = {p["pid"] for p in ollama}
    external = bool((11434 in listening and listening.get(11434) not in ollama_pids)
                    or (api_ready and not ollama))
    # Do not stop an instance-local Ollama when unrelated applications currently
    # hold client connections. Unknown client PIDs are also treated as shared.
    known_clients = {p["pid"] for p in brain + snow + watch + bridges + relogins}
    known_clients.add(os.getpid())
    shared = any(remote == 11434 and local != 11434 and pid not in known_clients
                 for local, remote, pid in snapshot.get("est", []))
    proto_file = root / "private" / "protocol.txt"
    try:
        protocol = proto_file.read_text(encoding="utf-8-sig").strip().lower()
    except (OSError, UnicodeError):
        protocol = "snowluma" if (root / "start-snowluma.cmd").exists() else "napcat"
    if protocol not in {"snowluma", "napcat"}:
        protocol = "unknown"
    return {
        "protocol": protocol,
        "backend": {**{k: resolved.get(k) for k in ("state", "pid", "port", "ws_port", "online", "ambiguous")},
                    "owned": _refs(brain), "unknown": unknown["backend"], "port_conflict": brain_conflict, "ws_ready": ws_ready},
        "snowluma": {"running": bool(snow), "ready": bool(snow) and listening.get(5099) in {p["pid"] for p in snow},
                     "owned": _refs(snow), "unknown": unknown["snowluma"], "port_conflict": conflict(5099, snow)},
        "ollama": {"running": bool(ollama), "api_ready": api_ready, "model_available": model_available,
                   "owned": _refs(ollama), "unknown": unknown["ollama"], "external": external,
                   "shared": shared, "port_conflict": conflict(11434, ollama) and not api_ready},
        # A historical login-detected line cannot prove the current QQ account is
        # still logged in. The master owner-qq file is not the bot account.
        "qq": {"running": bool(qq), "unknown": qq_unknown, "owner_login": None},
        "watch": {"running": bool(watch) or heartbeat_live, "owned": _refs(watch), "unknown": unknown["watch"]},
        "voice_bridge": {"running": bool(bridges), "owned": _refs(bridges), "unknown": unknown["voice_bridge"]},
        "relogin": {"running": bool(relogins), "owned": _refs(relogins), "unknown": unknown["relogin"]},
    }


def stop_owned(directory, kind, pid, created, *, backend=None, snap=None, process_factory=None):
    if kind not in KINDS:
        return {"ok": False, "reason": "unsupported_kind"}
    try:
        pid, created = int(pid), float(created)
        if pid <= 4 or not math.isfinite(created) or created <= 0:
            return {"ok": False, "reason": "invalid_identity"}
        state = inspect_stack(directory, backend=backend, snap=snap, probe_api=False)
        component = state[kind]
        if kind == "ollama" and any(component.get(key) for key in ("external", "shared", "unknown")):
            return {"ok": False, "reason": "ollama_not_exclusive"}
        if process_factory is None:
            import psutil
            process_factory = psutil.Process
        owned = next((item for item in component["owned"] if item["pid"] == pid), None)
        if owned is None:
            try:
                process_factory(pid)
            except Exception as error:
                if type(error).__name__ in {"NoSuchProcess", "ProcessLookupError"}:
                    return {"ok": True, "reason": "already_stopped"}
            return {"ok": False, "reason": "identity_not_owned"}
        if abs(owned["created"] - created) > 0.01:
            return {"ok": False, "reason": "pid_reused"}
        process = process_factory(pid)
        if abs(float(process.create_time()) - created) > 0.01:
            return {"ok": False, "reason": "pid_reused"}
        process.kill()
        process.wait(timeout=5)
        if process.is_running():
            return {"ok": False, "reason": "not_exited"}
        return {"ok": True, "reason": "stopped", "pid": pid}
    except Exception as error:
        # Never leak command line, account identifiers, provider data or paths
        # from a native API exception into the launcher output.
        name = type(error).__name__
        if name in {"NoSuchProcess", "ProcessLookupError"}:
            return {"ok": True, "reason": "already_stopped"}
        reason = "access_denied" if name in {"AccessDenied", "PermissionError"} else "not_exited" if name in {"TimeoutExpired", "TimeoutError"} else "stop_failed"
        return {"ok": False, "reason": reason}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", default=r"E:\dafeiyu")
    parser.add_argument("--stop", choices=sorted(KINDS))
    parser.add_argument("--pid", type=int)
    parser.add_argument("--created", type=float)
    args = parser.parse_args()
    if args.stop:
        result = stop_owned(args.dir, args.stop, args.pid, args.created)
    else:
        try:
            result = inspect_stack(args.dir)
        except Exception:
            result = {"ok": False, "reason": "probe_failed"}
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get("ok", True) else 1


if __name__ == "__main__":
    sys.exit(main())
