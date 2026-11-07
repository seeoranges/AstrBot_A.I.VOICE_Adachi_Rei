# -*- coding: utf-8 -*-
"""掉线提醒：小号被 QQ 踢下线，电脑右下角弹个通知，点一下就重新登录。

登录 Windows 时从启动文件夹起来（pythonw，没窗口），一直在后台看：
  本机那套：大脑开着、小号却没连上它，或者 NapCat 日志里最后一件事是被踢下线；
  云端那套：经 ssh 问服务器同样的事（private\\cloud.txt，跟云端工作台同一把钥匙）。
不吵人的规矩：
  - 连续掉线 3 分钟才提醒（重启大脑、网络闪一下都不算）；日志明确写了被踢的，下一轮确认后就提醒。
  - 一次掉线最多提醒 3 回：马上、半小时后、两小时后。她回来就清零。
  - 大脑没开不提醒（多半是他自己关的）；云端连不上服务器也不提醒（多半是这台电脑没网）。
  - 正在重新登录（开机登录、双击重登）时不提醒。
  - 电脑刚睡醒重新算 3 分钟。
  - private\\qq-watch-off.txt 存在就不提醒（工作台的开关）。

只用标准库；本机那套借 backend_state.py 判断在线（同一个目录）。

用法：
  pythonw qq_watch.py --dir <工作目录>      一直跑
  python  qq_watch.py --dir <工作目录> --once    只看一次，打印结果
  python  qq_watch.py --dir <工作目录> --test    弹一条试试
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.parse

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
IS_WIN = os.name == "nt"
NO_WINDOW = 0x08000000 if IS_WIN else 0

INTERVAL = {"local": 60, "cloud": 180}
GRACE = 180                     # 连续掉线多少秒才提醒
REMIND = (0, 30 * 60, 2 * 3600)  # 第几回提醒，距离第一回多久
KICK_RX = re.compile(r"KickedOffLine|登录已失效|登录态已失效|被迫下线|下线通知")
# 日志里这些说明她之后还活着：又登了一次。收到消息单独算（聊天内容也在日志里，不能拿它去匹配被踢）
ALIVE_RX = re.compile(r"本账号数据/缓存目录|WebSocket反向服务.*已启动")
ANSI_RX = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
LOG_ENTRY_RX = re.compile(r"^\[?(?:\d{4}-)?\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}")
FULL_EVERY = 15 * 60            # 在线时隔多久才完整查一次（完整查要起 PowerShell）


# ---------------------------------------------------------------- 工作目录

def read_text(p):
    try:
        return Path(p).read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError):
        return ""


def read_kv(p):
    return {m[1].lower(): m[2].strip() for m in re.finditer(r"(?m)^\s*([^\s:：]+)\s*[:：]\s*(.*)$", read_text(p))}


def is_cloud(d):
    kv = read_kv(Path(d) / "private" / "cloud.txt")
    return bool(kv.get("host") or kv.get("ip")) and not (Path(d) / "start-astrbot.cmd").exists() and not (Path(d) / "astrbot" / "data").is_dir()


def relogin_running(d):
    """检查命名锁是否正被持有；对象存在不等于重登还在运行。"""
    if not IS_WIN:
        return False
    import ctypes
    norm = os.path.abspath(str(d)).rstrip("\\").lower()
    tag = hashlib.sha256(norm.encode("utf-8")).hexdigest().upper()[:24]
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.OpenMutexW.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR)
    k32.OpenMutexW.restype = wintypes.HANDLE
    k32.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
    k32.WaitForSingleObject.restype = wintypes.DWORD
    k32.ReleaseMutex.argtypes = (wintypes.HANDLE,)
    k32.ReleaseMutex.restype = wintypes.BOOL
    k32.CloseHandle.argtypes = (wintypes.HANDLE,)
    k32.CloseHandle.restype = wintypes.BOOL
    h = k32.OpenMutexW(0x00100001, False, "Local\\DafeiyuQQ-" + tag)
    if not h:
        # 提权脚本创建的锁可能拒绝访问，保守等待，不能并发重登。
        return ctypes.get_last_error() not in (0, 2)
    try:
        result = k32.WaitForSingleObject(h, 0)
        if result in (0, 0x80):  # WAIT_OBJECT_0 / WAIT_ABANDONED：本线程已取得锁。
            k32.ReleaseMutex(h)
            return False
        return True  # WAIT_TIMEOUT 或检查失败，都不能再起一份重登。
    finally:
        k32.CloseHandle(h)


# ---------------------------------------------------------------- 本机：在不在线

def napcat_log(d):
    logs = []
    root = Path(d) / "NapCat"
    logs += list(root.glob("napcat-run*.log"))
    for sh in root.glob("NapCat.*.Shell"):
        logs += list(sh.glob("napcat-run*.log"))
        logs += list(sh.glob("versions/*/resources/app/napcat/logs/*.log"))
    try:
        return max(logs, key=lambda p: p.stat().st_mtime) if logs else None
    except OSError:
        return None


def kicked_in(lines):
    """最后一件事是被踢：有踢下线的字样，之后再没收到过消息、也没重新登录。
    发出去不算活着（被踢后她还会试着发，发不出去）；聊天内容里提到「下线通知」也不算被踢。"""
    lines = [ANSI_RX.sub("", line) for line in lines]
    structured = any(LOG_ENTRY_RX.match(line) for line in lines)
    kicked = False
    for ln in lines:
        # 多行聊天正文不带日志头，其中提到“下线通知”等字样不算系统事件。
        if structured and not LOG_ENTRY_RX.match(ln):
            continue
        if " 接收 <- " in ln:
            kicked = False
        elif " 发送 -> " in ln:
            continue
        elif KICK_RX.search(ln):
            kicked = True
        elif ALIVE_RX.search(ln):
            kicked = False
    return kicked


def scan_required_in(lines):
    """登录凭据已失效需要人扫码；WS服务启动不能清除这条证据。"""
    lines = [ANSI_RX.sub("", line) for line in lines]
    structured = any(LOG_ENTRY_RX.match(line) for line in lines)
    required = False
    for line in lines:
        if structured and not LOG_ENTRY_RX.match(line):
            continue
        if " 接收 <- " in line:
            required = False
        elif " 发送 -> " in line:
            continue
        elif re.search(r"登录态已失效|登录已失效|快速登录(?:错误|失败).*重新登录", line):
            required = True
        elif re.search(r"本账号数据/缓存目录|(?:登录|登陆)成功", line):
            required = False
    return required


def requires_scan(d):
    path = napcat_log(d)
    return bool(path and scan_required_in(tail(path)))


def automatic_retry_delay(d, now=None):
    """真正自动重启的跨任务冷却；损坏记录保守等待，手动入口不受此限。"""
    path = Path(d) / "logs" / "qq-relogin-attempt.json"
    if not path.exists():
        return 0
    try:
        last = float(json.loads(read_text(path))["at"])
        if not math.isfinite(last) or last <= 0:
            return 900
        elapsed = (time.time() if now is None else now) - last
        return min(900, max(0, math.ceil(900 - elapsed)))
    except (OSError, ValueError, TypeError, KeyError):
        return 900


def relogin_diagnostics(d):
    """供 --once / -DryRun 输出安全依据，不输出日志行或账号。"""
    path = napcat_log(d)
    return {"log_found": bool(path), "needs_scan": bool(path and scan_required_in(tail(path))),
            "login_info": qq_logged_in(d), "automatic_retry_wait": automatic_retry_delay(d)}


def tail(path, size=200_000):
    try:
        with open(path, "rb") as fp:
            fp.seek(0, 2)
            n = fp.tell()
            fp.seek(max(0, n - size))
            if n > size:
                fp.readline()  # 起点可能在一条聊天记录中间，丢掉不完整首行。
            data = fp.read()
    except OSError:
        return []
    return data.decode("utf-8", "replace").splitlines()


def protocol(d):
    p = read_text(Path(d) / "private" / "protocol.txt").strip().lower()
    if p:
        return p
    return "snowluma" if (Path(d) / "start-snowluma.cmd").exists() and not (Path(d) / "start-napcat.cmd").exists() else "napcat"


def tcp_rows():
    """这台电脑的 TCP 连接表（IPv4），[(状态, 本地端口, 对方端口, 进程号)]。直接问系统，不起别的程序。"""
    import ctypes
    iph = ctypes.windll.iphlpapi
    size = ctypes.c_ulong(0)
    iph.GetExtendedTcpTable(None, ctypes.byref(size), False, 2, 5, 0)  # AF_INET, TCP_TABLE_OWNER_PID_ALL
    buf = ctypes.create_string_buffer(size.value + 8192)
    size = ctypes.c_ulong(len(buf))
    if iph.GetExtendedTcpTable(buf, ctypes.byref(size), False, 2, 5, 0):
        return []
    rows = []
    for i in range(struct.unpack_from("I", buf, 0)[0]):
        st, _la, lp, _ra, rp, pid = struct.unpack_from("6I", buf, 4 + i * 24)
        if st == 5 and (
            not socket.inet_ntoa(struct.pack("=I", _la)).startswith("127.")
            or not socket.inet_ntoa(struct.pack("=I", _ra)).startswith("127.")
        ):
            continue  # 远程主机碰巧也用同端口，不能当成本机反向 WS。
        rows.append((st, socket.ntohs(lp & 0xffff), socket.ntohs(rp & 0xffff), pid))
    return rows


def ws_pids(rows, port):
    """连着 ws 端口的两头：(大脑那头的进程, 登 QQ 那头的进程)。"""
    est = [r for r in rows if r[0] == 5]
    return {r[3] for r in est if r[1] == port}, {r[3] for r in est if r[2] == port}


FAST = {}


def fast_online(now):
    """她好好连着时不用每分钟起一次 PowerShell（打游戏时别抢资源）：
    上次完整确认在线的那两个程序之间的连接还在，就还算在线。隔 15 分钟或者连接一变，才完整查。"""
    if not IS_WIN or not FAST or not 0 <= now - FAST["at"] <= FULL_EVERY:
        return False
    try:
        srv, cli = ws_pids(tcp_rows(), FAST["port"])
    except (OSError, ValueError, struct.error, AttributeError):
        return False
    return bool(srv & FAST["srv"] and cli & FAST["cli"])


def remember_online(port, now):
    FAST.clear()
    if IS_WIN:
        try:
            srv, cli = ws_pids(tcp_rows(), port)
        except (OSError, ValueError, struct.error, AttributeError):
            return
        if srv and cli:
            FAST.update(port=port, srv=srv, cli=cli, at=now)

def napcat_http(d):
    """本机那套给 NapCat 加了个只听 127.0.0.1 的 HTTP 口，用来问「QQ 到底登着没有」。"""
    txt = read_text(Path(d) / "private" / "napcat-http.txt")
    base = re.search(r"(http://\S+)", txt)
    tok = re.search(r"token=(\S+)", txt)
    if not base:
        return "", ""
    return base.group(1).strip(), (tok.group(1).strip() if tok else "")


def qq_logged_in(d, timeout=5):
    """True 登着 / False 掉登录 / None 问不到（没配接口或超时）。"""
    base, tok = napcat_http(d)
    if not base:
        return None
    try:
        parsed = urllib.parse.urlsplit(base)
        if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
            return None
        req = urllib.request.Request(base.rstrip("/") + "/get_login_info",
                                     data=b"{}",
                                     headers={"Authorization": "Bearer " + tok,
                                              "Content-Type": "application/json"})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=timeout) as response:
            body = json.loads(response.read(262144).decode("utf-8-sig"))
        if not isinstance(body, dict) or type(body.get("retcode")) is not int or body["retcode"] != 0:
            return None
        data = body.get("data")
        if (not isinstance(data, dict) or "user_id" not in data
                or not isinstance(data["user_id"], (int, str)) or isinstance(data["user_id"], bool)):
            return None
        user_id = int(data["user_id"])
        return user_id > 0
    except (OSError, ValueError, TypeError, OverflowError):
        # 401 是 HTTP token 不对，并不能证明 QQ 登录态失效。
        return None


def local_status(d, *, ignore_relogin=False):
    now = time.time()
    online = fast_online(now)
    if not online:
        import backend_state
        st = backend_state.resolve(d, repair=False)
        if st.get("ambiguous"):
            return "unknown", "好几个实例认不准"
        if st.get("state") != "up":
            FAST.clear()
            return "brain-off", "大脑没开"
        online = bool(st.get("online"))
        if online:
            remember_online(st.get("ws_port") or 6199, now)
        else:
            FAST.clear()
    if not ignore_relogin and relogin_running(d):
        return "busy", "正在重新登录"
    # 被踢后 NapCat 常常还连着大脑，光看连接看不出来，要看它自己的日志。换成 SnowLuma 后旧日志不算数
    if protocol(d) == "napcat":
        log = napcat_log(d)
        if log and kicked_in(tail(log)):
            return "kicked", "NapCat 日志里最后一件事是被踢下线"
        if online:
            logged = qq_logged_in(d)
            if logged is False:
                return "kicked", "QQ 登录态掉了（连接还挂着，所以她一声不响）"
    return ("online", "") if online else ("offline", "小号没连上大脑")


# ---------------------------------------------------------------- 云端：在不在线

def ssh_exe():
    if IS_WIN:
        root = os.environ.get("SystemRoot", r"C:\Windows")
        for c in (os.path.join(root, "System32", "OpenSSH", "ssh.exe"), os.path.join(root, "Sysnative", "OpenSSH", "ssh.exe")):
            if os.path.exists(c):
                return c
    return "ssh"


def cloud_status(d):
    """问服务器一次。连不上一律 unknown：多半是这台电脑没网，不拿这个吓他。"""
    d = Path(d)
    kv = read_kv(d / "private" / "cloud.txt")
    host, user = kv.get("host") or kv.get("ip") or "", kv.get("user") or "root"
    if not re.fullmatch(r"[A-Za-z0-9.:\-\[\]]{1,255}", host) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.\-]{0,31}", user):
        return "unknown", "cloud.txt 没写对"
    key = kv.get("key") or "cloud_key"
    key = key if os.path.isabs(key) else str(d / "private" / key)
    rdir = kv.get("dir") or "/opt/dafeiyu"
    port = kv.get("port") if str(kv.get("port", "")).isdigit() else "22"
    remote = HERE / "workbench" / "cloud_remote.py"
    kh = str(d / "private" / "cloud_known_hosts").replace("\\", "/")
    sudo = "" if user == "root" else "sudo -n "
    cmd = [ssh_exe(), "-i", key, "-p", port, "-o", "BatchMode=yes", "-o", "ConnectTimeout=12", "-o", "StrictHostKeyChecking=accept-new",
           "-o", f'UserKnownHostsFile="{kh}"', "-o", "LogLevel=ERROR", f"{user}@{host}",
           "P=$(command -v python3 || echo /usr/libexec/platform-python); " + sudo + "env PYTHONIOENCODING=utf-8 $P - qqstate --dir " + shlex.quote(rdir)]
    try:
        p = subprocess.run(cmd, input=remote.read_bytes(), capture_output=True, timeout=45, creationflags=NO_WINDOW)
    except (OSError, subprocess.SubprocessError):
        return "unknown", "连服务器出错"
    line = next((ln for ln in reversed(p.stdout.decode("utf-8", "replace").splitlines()) if ln.startswith("DFY_JSON ")), "")
    try:
        r = json.loads(line[len("DFY_JSON "):]) if line else {}
    except ValueError:
        r = {}
    if not r.get("ok"):
        return "unknown", "服务器没回话"
    return cloud_verdict(r)


def cloud_verdict(r):
    if not r.get("brain"):
        return "brain-off", "服务器上的大脑没开"
    if r.get("kicked"):
        return "kicked", "NapCat 日志里最后一件事是被踢下线"
    return ("online", "") if r.get("conns") else ("offline", "小号没连上大脑")


# ---------------------------------------------------------------- 弹通知

def toast(d, kind):
    """调 qq-toast.ps1（要 Windows PowerShell 5.1 才有通知的接口）。返回 (成没成, 说明)。"""
    if not IS_WIN:
        print(f"[toast] {kind}")
        return True, "不是 Windows，只打印"
    root = os.environ.get("SystemRoot", r"C:\Windows")
    ps = os.path.join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
    try:
        p = subprocess.run([ps, "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", str(HERE / "qq-toast.ps1"), "-Dir", str(d), "-Kind", kind],
                           capture_output=True, timeout=40, creationflags=NO_WINDOW, cwd=tempfile.gettempdir())
    except (OSError, subprocess.SubprocessError) as e:
        return False, type(e).__name__
    out = p.stdout.decode("utf-8", "replace").strip().splitlines()
    return p.returncode == 0, (out[-1] if out else f"退出码 {p.returncode}")


# ---------------------------------------------------------------- 什么时候提醒

class Watch:
    """只管时间，不碰外面，方便测。tick 返回要弹的种类（kicked / offline），不弹返回 None。"""

    def __init__(self, interval):
        self.interval = interval
        self.last_tick = 0
        self.since = 0      # 从什么时候开始算掉线
        self.first = 0      # 这次掉线第一回提醒的时间
        self.sent = 0       # 这次掉线提醒了几回
        self.seen_kick = 0  # 连续几轮看到被踢

    def reset(self):
        self.since = self.first = self.sent = self.seen_kick = 0

    def tick(self, status, now):
        elapsed = now - self.last_tick if self.last_tick else 0
        slept = self.last_tick and (elapsed < 0 or elapsed > max(self.interval * 3, 300))
        self.last_tick = now
        if status == "online":
            self.reset()
            return None
        if status not in ("offline", "kicked"):
            # 大脑没开、查不到、正在登：这段不算掉线。已经提醒过的次数留着，登不上时不重新吵满 3 回
            self.since = self.seen_kick = 0
            return None
        if slept:
            self.since = now
            self.seen_kick = 0
            if elapsed < 0 and self.first:
                self.first = now
        self.since = self.since or now
        self.seen_kick = self.seen_kick + 1 if status == "kicked" else 0
        if self.sent >= len(REMIND):
            return None
        due = self.seen_kick >= 2 or now - self.since >= GRACE  # 被踢确认两轮，别的等满 3 分钟
        if not due:
            return None
        if self.sent and now - self.first < REMIND[self.sent]:
            return None
        self.first = self.first or now
        self.sent += 1
        return status


# ---------------------------------------------------------------- 一直跑

def write_state(d, **kw):
    p = Path(d) / "logs" / "qq-watch.json"
    tmp = p.with_name(p.name + f".{os.getpid()}.tmp")
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(json.dumps({**kw, "pid": os.getpid(), "at": time.time()}, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, p)
    except OSError:
        pass
    finally:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass


def log(d, msg):
    p = Path(d) / "logs" / "qq-watch.log"
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        if p.exists() and p.stat().st_size > 200_000:
            p.write_text("", encoding="utf-8")
        with open(p, "a", encoding="utf-8") as fp:
            fp.write(time.strftime("%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


def take_lock(d):
    """同一个工作目录只跑一份。锁跟着进程走，崩了自动释放。"""
    p = Path(d) / "logs" / "qq-watch.lock"
    p.parent.mkdir(parents=True, exist_ok=True)
    fp = open(p, "a+b")
    try:
        if IS_WIN:
            import msvcrt
            fp.seek(0, 2)
            if not fp.tell():
                fp.write(b"0")
                fp.flush()
            fp.seek(0)
            msvcrt.locking(fp.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fp.close()
        return None
    return fp


def status_of(d, *, ignore_relogin=False):
    return cloud_status(d) if is_cloud(d) else local_status(d, ignore_relogin=ignore_relogin)

REL = {"first": 0.0, "last": 0.0, "attempt": 0.0, "tick": 0.0}


def auto_relogin(d, st):
    """掉线自己好不了的时候，按一下「重登」计划任务（带管理员权限，不会被弹窗卡住）。
    规则：连续掉线满 GRACE 秒才动；两次之间至少隔 15 分钟；正在重登就等着；大脑没开不管。"""
    now = time.time()
    elapsed = now - REL["tick"] if REL["tick"] else 0
    REL["tick"] = now
    if elapsed < 0 or elapsed > max(INTERVAL["local"] * 3, 300):
        REL["first"] = 0.0  # 睡醒或时钟跳变后重新确认连续掉线。
    if not IS_WIN or is_cloud(d):
        REL["first"] = 0.0
        return
    if st not in ("offline", "kicked"):
        REL["first"] = 0.0
        if st == "online":
            REL["scan_notice"] = False
        return
    if requires_scan(d):
        REL["first"] = 0.0
        if not REL.get("scan_notice"):
            log(d, "QQ 登录凭据已失效，等待本人扫码；不再自动重启或快速登录")
            REL["scan_notice"] = True
        return
    REL["scan_notice"] = False
    if not REL["first"]:
        REL["first"] = now
        return
    if now - REL["first"] < GRACE or (REL["last"] and now - REL["last"] < 15 * 60):
        return
    if REL["attempt"] and now - REL["attempt"] < INTERVAL["local"]:
        return
    if relogin_running(d):
        return
    if automatic_retry_delay(d, now) > 0:
        return
    REL["attempt"] = now
    try:
        powershell = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"),
                                  "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
        result = subprocess.run([powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                                 "Start-ScheduledTask -TaskName 'Dafeiyu-Relogin' -ErrorAction Stop"],
                                creationflags=NO_WINDOW, timeout=20, check=False,
                                capture_output=True)
        if result.returncode != 0:
            log(d, f"自动重登没按下去（退出码 {result.returncode}），请检查重登计划任务是否启用")
            return
        REL["last"] = now
        log(d, "掉线超过 3 分钟，已经自动按了一次「重登」")
    except Exception as e:  # noqa: BLE001
        log(d, f"自动重登没按下去：{type(e).__name__} {e}")


def run(d):
    lock = take_lock(d)
    if not lock:
        return 0
    try:
        os.chdir(tempfile.gettempdir())  # 当前目录不留在工作目录里：卸载、挪文件夹时别占着
    except OSError:
        pass
    mode = "cloud" if is_cloud(d) else "local"
    w = Watch(INTERVAL[mode])
    try:
        previous = json.loads(read_text(Path(d) / "logs" / "qq-watch.json") or "{}")
        last = float(previous.get("relogin_last", 0))
        if math.isfinite(last) and 0 < last <= time.time():
            REL["last"] = last
    except (ValueError, TypeError, AttributeError):
        pass
    log(d, f"起来了（{mode}）")
    off = Path(d) / "private" / "qq-watch-off.txt"
    while True:
        try:
            if off.exists():
                w.reset()
                REL["first"] = 0.0
                write_state(d, state="off", note="开关关着", relogin_last=REL["last"])
            else:
                st, why = status_of(d)
                auto_relogin(d, st)
                kind = w.tick(st, time.time())
                note = why
                if kind:
                    ok, res = toast(d, kind)
                    log(d, f"提醒第 {w.sent} 回（{kind}，{why}）：{res}")
                    note = why + "；" + ("已弹通知" if ok else "通知没弹出来：" + res)
                write_state(d, state=st, note=note, since=w.since, sent=w.sent, mode=mode,
                            relogin_last=REL["last"])
        except Exception as e:  # noqa: BLE001  后台程序不能因为一次出错就没了
            REL["first"] = 0.0
            w.tick("unknown", time.time())
            log(d, f"这一轮出错：{type(e).__name__} {e}")
            write_state(d, state="unknown", note="这一轮状态检查出错，请看守护日志",
                        mode=mode, relogin_last=REL["last"])
        time.sleep(w.interval)


def main():
    ap = argparse.ArgumentParser(description="大肥鱼掉线提醒")
    ap.add_argument("--dir", default="")
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--ignore-relogin", action="store_true",
                    help="仅配合 --once，供持有重登锁的自救脚本检查真实登录态")
    ap.add_argument("--test", action="store_true")
    a = ap.parse_args()
    if a.ignore_relogin and not a.once:
        ap.error("--ignore-relogin 要和 --once 一起用")
    d = a.dir or (str(HERE.parent) if HERE.name.lower() == "tools" else "")
    if not d:
        ap.error("要给 --dir <工作目录>")
    d = os.path.abspath(d)
    if a.test:
        ok, res = toast(d, "test")
        print(res)
        return 0 if ok else 1
    if a.once:
        st, why = status_of(d, ignore_relogin=a.ignore_relogin)
        mode = "cloud" if is_cloud(d) else "local"
        report = {"state": st, "why": why, "mode": mode}
        if mode == "local":
            report.update(relogin_diagnostics(d))
        print(json.dumps(report, ensure_ascii=False))
        return 0
    return run(d)


if __name__ == "__main__":
    sys.exit(main())
