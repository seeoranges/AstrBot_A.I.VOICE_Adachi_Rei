"""本机大脑的共同口径：按实例进程认端口，不把 cmd_config 的默认端口当运行端口。

PowerShell、工作台、桌宠桥共用。只查当前 Windows 用户；不读写启动器数据库，
不启动实例。backend.txt 只改 url，原字节先备份；多实例认不准时不猜。
"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import threading
import time
import urllib.parse
import urllib.request
import uuid

try:
    import psutil
except ImportError:
    psutil = None

_LOCK = threading.RLock()


def read(path):
    try:
        return Path(path).read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError):
        return ""


def js(path):
    try:
        value = json.loads(read(path))
        return value if isinstance(value, dict) else {}
    except ValueError:
        return {}


def kv(path):
    return {m[1].lower(): m[2].strip() for m in
            re.finditer(r"(?m)^[ \t]*([^\s:：]+)[ \t]*[:：][ \t]*(.*)$", read(path))}


def norm(path):
    return os.path.normcase(os.path.abspath(str(path))).replace("\\", "/").rstrip("/").lower()


def within(path, root):
    return bool(path) and norm(path).startswith(norm(root) + "/")


def _windows_session_id(pid):
    """无需打开目标进程，也能识别同一桌面会话中的提权进程。"""
    if os.name != "nt":
        return None
    try:
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        get_session = kernel.ProcessIdToSessionId
        get_session.argtypes = (wintypes.DWORD, ctypes.POINTER(wintypes.DWORD))
        get_session.restype = wintypes.BOOL
        session = wintypes.DWORD()
        return session.value if get_session(int(pid), ctypes.byref(session)) else None
    except (OSError, AttributeError, ValueError):
        return None


def _process_value(process, field, default):
    try:
        return getattr(process, field)()
    except (psutil.Error, OSError):
        return default


def _listen(out, port, pid):
    # IPv4/IPv6 同端口若属于不同进程，不能任选其中一个来证明归属。
    if port not in out["listen"]:
        out["listen"][port] = pid
    elif out["listen"][port] != pid:
        out["listen"][port] = None


def _loopback(address):
    try:
        ip = ipaddress.ip_address(str(address).split("%", 1)[0])
        return ip.is_loopback or bool(getattr(ip, "ipv4_mapped", None) and ip.ipv4_mapped.is_loopback)
    except ValueError:
        return False


def snapshot():
    """按用户及 Windows 桌面会话筛进程，端口还须按 pid 匹配。"""
    out = {"procs": [], "listen": {}, "est": []}
    excluded = set()
    if psutil:
        me = _process_value(psutil.Process(), "username", "").lower()
        session = _windows_session_id(os.getpid())
        for p in psutil.process_iter():
            try:
                process_session = _windows_session_id(p.pid) if session is not None else None
                if process_session is not None and process_session != session:
                    excluded.add(p.pid)
                    continue
                user = _process_value(p, "username", "").lower()
                if user and me and user != me:
                    excluded.add(p.pid)
                    continue
                exe = _process_value(p, "exe", "")
                # 用户名不可读时，只允许能确认同一桌面会话、且路径可读的进程。
                if (not user or not me) and not (
                    session is not None and process_session == session and exe
                ):
                    continue
                item = dict(pid=p.pid, name=_process_value(p, "name", ""), exe=exe,
                            cmd=" ".join(_process_value(p, "cmdline", [])),
                            create=_process_value(p, "create_time", 0))
                out["procs"].append(item)
            except (psutil.Error, OSError):
                continue
        try:
            for c in psutil.net_connections("tcp"):
                if c.status == "LISTEN" and c.laddr:
                    _listen(out, c.laddr.port, c.pid)
                elif c.status == "ESTABLISHED" and c.laddr and c.raddr and _loopback(c.raddr.ip):
                    out["est"].append((c.laddr.port, c.raddr.port, c.pid))
            return out
        except (psutil.Error, OSError):
            pass
    if os.name == "nt":
        # 无 psutil 时仍按会话筛进程，不把 15000 等其他用户的实例认进来。
        code = r"""
[Console]::OutputEncoding=[Text.Encoding]::UTF8
$s=(Get-Process -Id $PID).SessionId
$p=@(Get-CimInstance Win32_Process | Where-Object {$_.SessionId -eq $s} | ForEach-Object {
 @{pid=$_.ProcessId;name=$_.Name;exe=$_.ExecutablePath;cmd=$_.CommandLine;create=$(if($_.CreationDate){[int64](($_.CreationDate.ToUniversalTime())-[datetime]'1970-01-01').TotalSeconds}else{0})}
})
$t=@(Get-NetTCPConnection -ErrorAction SilentlyContinue | Select-Object LocalPort,RemotePort,RemoteAddress,OwningProcess,State)
@{procs=$p;tcp=$t}|ConvertTo-Json -Depth 4 -Compress
"""
        try:
            p = subprocess.run(["powershell.exe", "-NoProfile", "-Command", code],
                               capture_output=True, timeout=30, creationflags=0x08000000)
            j = json.loads(p.stdout.decode("utf-8-sig"))
            # CIM 可能读不到提权进程路径；保留 psutil 已经读到的字段。
            known = {p["pid"]: p for p in out["procs"]}
            for p in j.get("procs") or []:
                if not isinstance(p, dict) or not p.get("pid") or p["pid"] in excluded:
                    continue
                old = known.get(p["pid"], {})
                known[p["pid"]] = {key: old.get(key) or p.get(key, default) for key, default in
                                   (("pid", 0), ("name", ""), ("exe", ""), ("cmd", ""), ("create", 0))}
            out["procs"] = list(known.values())
            out["listen"], out["est"] = {}, []
            for c in j.get("tcp") or []:
                if c["State"] in (2, "Listen"):
                    _listen(out, c["LocalPort"], c["OwningProcess"])
                elif c["State"] in (5, "Established") and _loopback(c.get("RemoteAddress", "")):
                    out["est"].append((c["LocalPort"], c["RemotePort"], c["OwningProcess"]))
        except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError):
            pass
    return out


def roots():
    override = js(Path(os.environ.get("APPDATA", "")) /
                  "com.github.raven95676.astrbot-launcher" / ".data-dir.json").get("data_dir")
    return [Path(override)] if override else [Path(os.environ.get("USERPROFILE", str(Path.home()))) / ".astrbot_launcher"]


def ws_port(config, token=""):
    platforms = [p for p in config.get("platform", []) or [] if isinstance(p, dict)
                 and p.get("type") == "aiocqhttp" and p.get("enable", True)]
    matches = [p for p in platforms if token and p.get("ws_reverse_token") == token]
    if not matches:
        matches = [p for p in platforms if p.get("id") == "大肥鱼"] or platforms
    ports = set()
    for p in matches:
        try:
            port = int(p.get("ws_reverse_port", 6199))
            if 0 < port < 65536:
                ports.add(port)
        except (ValueError, TypeError):
            pass
    # 多个平台端口不同且无法唯一匹配时，不猜默认端口去触发自动重登。
    return ports.pop() if len(ports) == 1 else (0 if len(ports) > 1 else 6199)


def dashboard_page(port):
    """只探实例 pid 已在听的端口，不带密码。排除插件开的其他 HTTP 服务。"""
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(f"http://127.0.0.1:{port}/", timeout=0.7) as r:
            return "astrbot" in r.read(65536).decode("utf-8", "ignore").lower()
    except (OSError, ValueError):
        return False


def repair_url(path, url):
    """跨进程互斥；逐字节保留凭证、BOM 和换行。返回是否实际改过。"""
    lock = path.with_name("backend-url.lock")
    with _LOCK:
        try:
            guard = lock.open("a+b")
            if os.name == "nt":
                import msvcrt
                guard.seek(0, 2)
                if not guard.tell():
                    guard.write(b"0"); guard.flush()
                guard.seek(0)
                msvcrt.locking(guard.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(guard.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            if "guard" in locals():
                guard.close()
            return False
        try:
            raw = path.read_bytes()
            text = raw.decode("utf-8-sig")
            old = kv(path).get("url", "")
            if old == url or not old:
                return False
            changed = re.sub(r"(?im)^([ \t]*url[ \t]*[:：][ \t]*)[^\r\n]*", lambda m: m[1] + url, text, count=1)
            if changed == text:
                return False
            backup = path.with_name(f"backend.txt.before-port-{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:6]}.bak")
            with backup.open("xb") as f:
                f.write(raw)
            tmp = path.with_name("backend.txt." + uuid.uuid4().hex + ".tmp")
            try:
                tmp.write_bytes((b"\xef\xbb\xbf" if raw.startswith(b"\xef\xbb\xbf") else b"") + changed.encode("utf-8"))
                if path.read_bytes() != raw:  # 用户正好在记事本里改过时，不覆盖他的改动。
                    return False
                os.replace(tmp, path)
            finally:
                tmp.unlink(missing_ok=True)
            return True
        except (OSError, UnicodeError):
            return False
        finally:
            guard.close()  # OS 锁在退出/进程崩溃时自动释放，磁盘上的空锁文件不影响重跑。


def _command_args(cmd):
    try:
        return [arg.strip('"').replace("\\", "/").lower()
                for arg in shlex.split(cmd or "", posix=False)]
    except ValueError:
        return []


def _python_entry(process):
    # cmdline 的第一项是解释器。只看 Python 真正执行的入口，不能把脚本
    # 后面的 --dir/--original 等普通参数误认成正在运行的 main.py。
    args = _command_args(process.get("cmd", ""))[1:]
    while args:
        arg = args[0]
        if arg in {"-x", "-w", "--check-hash-based-pycs"}:
            args = args[2:]
        elif arg in {"-m", "-c"}:
            return arg, args[1] if len(args) > 1 else ""
        elif arg.startswith("-"):
            args = args[1:]
        else:
            return "file", arg
    return "", ""


def _main_process(process, main):
    kind, entry = _python_entry(process)
    return kind == "file" and norm(entry) == norm(main)


def _cli_process(process, directory):
    """识别真正的大脑入口，不把 --dir 参数里带 astrbot 的运维脚本算进去。"""
    exe = process.get("exe", "")
    if not within(exe, directory / "uv"):
        return False
    if Path(exe).name.lower() == "astrbot.exe":
        return True
    kind, entry = _python_entry(process)
    if kind == "-m":
        return entry in {"astrbot", "astrbot.cli", "astrbot.__main__"}
    return kind == "file" and (
        (Path(entry).name in {"astrbot", "astrbot.exe"} and within(entry, directory / "uv"))
        or norm(entry) == norm(directory / "astrbot" / "main.py")
    )


def resolve(directory, *, repair=True, snap=None, launcher_roots=None, check_page=dashboard_page):
    d = Path(directory)
    backend = d / "private" / "backend.txt"
    configured_url = kv(backend).get("url", "").strip() or "http://127.0.0.1:6185"
    url = configured_url.split()[0].rstrip("/")
    try:
        parsed = urllib.parse.urlsplit(url if "://" in url else "http://" + url)
        port = parsed.port or 6185
    except ValueError:
        port = 6185
        url = "http://127.0.0.1:6185"
        parsed = urllib.parse.urlsplit(url)
    s = snapshot() if snap is None else snap
    procs, listening = s["procs"], s["listen"]
    r = dict(url=url, port=port, ws_port=6199, kind="cli" if (d / "start-astrbot.cmd").exists() else "launcher",
             instance="", data_dir="", state="off", launcher_running=any(
                 re.search(r"astrbot.?launcher", p.get("name", ""), re.I) for p in procs),
             pid=0, started=0, online=False, repaired=False, ambiguous=False)
    token = read(d / "private" / "napcat-ws-token.txt").strip()
    owned = []
    if r["kind"] == "cli":
        r["data_dir"] = str(d / "astrbot" / "data")
        config = js(Path(r["data_dir"]) / "cmd_config.json")
        owned = [p for p in procs if _cli_process(p, d)]
        listener = listening.get(port)
        # 提权 Python 的命令行可能不可读。只对本实例解释器监听的后台端口
        # 做页面探测后接纳，不能仅凭“6185 有人监听”判定大脑已经启动。
        if listener not in {p["pid"] for p in owned}:
            hidden = next((p for p in procs if p["pid"] == listener
                           and not p.get("cmd") and within(p.get("exe", ""), d / "uv")
                           and Path(p.get("exe", "")).name.lower() in {"python.exe", "pythonw.exe"}), None)
            if hidden and check_page(port):
                owned.append(hidden)
        # 命令行版照旧认 backend.txt；不会自动换成别的安装的端口。
        if listener is not None and listener in {p["pid"] for p in owned}:
            r["state"] = "up"
            r["pid"] = listening[port]
    else:
        cands = []
        for root in roots() if launcher_roots is None else launcher_roots:
            for inst in (Path(root) / "instances").glob("*"):
                cfg = js(inst / "core" / "data" / "cmd_config.json")
                if cfg:
                    cands.append((inst, cfg))
        pinned = read(d / "private" / "backend-instance.txt").strip()
        matching = [(i, c) for i, c in cands if pinned and norm(i) == norm(pinned)]
        if not matching and not pinned and token:
            matching = [(i, c) for i, c in cands if any(
                isinstance(p, dict) and p.get("type") == "aiocqhttp" and p.get("ws_reverse_token") == token
                for p in c.get("platform", []))]
        if not matching and not pinned:
            for inst, cfg in cands:
                ip = [p for p in procs if _main_process(p, inst / "core" / "main.py")]
                if listening.get(port) in {p["pid"] for p in ip}:
                    matching.append((inst, cfg))
        if not matching and not pinned and len(cands) == 1:
            matching = cands
        if len(matching) != 1:
            r["ambiguous"] = bool(cands)
            return r
        inst, config = matching[0]
        r["instance"], r["data_dir"] = str(inst), str(inst / "core" / "data")
        if repair and not pinned:
            try:
                with (d / "private" / "backend-instance.txt").open("x", encoding="utf-8") as f:
                    f.write(str(inst))
            except OSError:
                pass
        main = inst / "core" / "main.py"
        owned = [p for p in procs if _main_process(p, main)]
        pids = {p["pid"] for p in owned}
        ws = ws_port(config, token)
        ports = [p for p, pid in listening.items() if pid in pids and p != ws]
        actual = port if port in ports else next((p for p in ports if check_page(p)), None)
        if actual:
            r.update(port=actual, pid=listening[actual], state="up")
            # 仅本机后台允许自动校正，远端地址不探也不替换。
            if actual != port and parsed.hostname in ("127.0.0.1", "localhost", "::1"):
                host = "[::1]" if parsed.hostname == "::1" else parsed.hostname
                r["url"] = urllib.parse.urlunsplit((parsed.scheme or "http", f"{host}:{actual}", parsed.path, parsed.query, parsed.fragment))
                if repair:
                    r["repaired"] = repair_url(backend, r["url"])
    r["ws_port"] = ws_port(config, token)
    if not r["ws_port"]:
        r["ambiguous"] = True
    r["started"] = next((p.get("create", 0) for p in procs if p["pid"] == r["pid"]), 0)
    if r["state"] != "up" and owned:
        newest = max(p.get("create", 0) for p in owned)
        r["state"] = "starting" if time.time() - newest < 300 else "stuck"
    proto = read(d / "private" / "protocol.txt").strip().lower()
    root = d / ("SnowLuma" if proto == "snowluma" else "NapCat")
    clients = {p["pid"] for p in procs if within(p.get("exe", ""), root)}
    # online 只证明本实例 WS 传输连通，不证明 QQ 登录态仍有效；
    # qq_watch.py 还会检查明确掉线日志/登录态。其他实例的连接不能点亮这个小号。
    r["online"] = (r["state"] == "up" and listening.get(r["ws_port"]) in ({r["pid"]} | {p["pid"] for p in owned})
                   and any(remote == r["ws_port"] and pid in clients for _, remote, pid in s["est"]))
    return r


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--no-repair", action="store_true")
    a = ap.parse_args()
    print(json.dumps(resolve(a.dir, repair=not a.no_repair), ensure_ascii=False))
