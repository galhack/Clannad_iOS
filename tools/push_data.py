#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把《CLANNAD》游戏目录通过局域网发送到应用（Wi-Fi 导入）。

应用内打开「局域网接收游戏文件」后，屏幕上会显示 **地址** 和 **配对码**；
在同一 Wi-Fi 的 Mac 上运行（只需要系统自带的 Python 3）：

    python3 tools/push_data.py --host 192.168.1.23 --code 123456 CLANNAD/data

目录参数也可以是游戏根目录的上一级目录（例如 Steam 的 CLANNAD 文件夹），
脚本会自动找到其中包含 SceneZH.pck 与 GameexeZH.dat 的 data/。

脚本发送 `data/` 目录下的全部游戏文件（SceneZH.pck、GameexeZH.dat、dat/、
g00/、bgm/、koe/、wav/、mov/、gan/、savedata_zh/、SAVEDATA/、LICENSE/ 等），
跳过 .DS_Store 等隐藏文件，以及 siglus_rs 在 Apple 平台用不到的 Windows
可执行文件（SiglusEngine_Steam.exe / steam_api.dll / CLANNAD_HD.ico；需要时
加 --include-windows）。

设备上已经存在且大小相同的文件会跳过，所以中断后重新运行即可续传。
只使用 Python 标准库，不需要安装任何依赖。

与服务端的 HTTP 约定（应用内 TransferServer，端口 8765）：

    GET  /info                                     -> {"app","protocol","root","freeBytes"}
    GET  /status?code=<配对码>                      -> {"files":[{"path","size"}]}
    POST /upload?path=<相对路径>&size=<字节>&code=<配对码>
          请求体为文件原始字节，Content-Length=size -> {"ok":true,"path":...}

配对码同时放在查询参数和 X-Clannad-Code 请求头里。路径是相对游戏根目录的
POSIX 路径；服务端先写 `<名字>.part`，完成后原子改名，所以不会留下半个文件。
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import sys
import time
import urllib.parse

APP_NAME = "Clannad"
DEFAULT_PORT = 8765
DEFAULT_TIMEOUT = 300
CHUNK = 1 << 20
# 游戏根目录必须包含的两个文件（官方简体中文资源）。
REQUIRED_FILES = ("SceneZH.pck", "GameexeZH.dat")
# 原版 Windows 程序的文件，siglus_rs 在 Apple 平台上用不到。
WINDOWS_ONLY = {"SiglusEngine_Steam.exe", "steam_api.dll", "CLANNAD_HD.ico"}


class TransferError(Exception):
    """一次传输失败；消息已经是给玩家看的中文。"""


# --------------------------------------------------------------------------- 输出


def human_bytes(n):
    """把字节数变成容易读的字符串。"""
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            if unit == "B":
                return "%d %s" % (n, unit)
            return "%.2f %s" % (n, unit)
        n /= 1024.0


def human_duration(seconds):
    seconds = max(0, int(seconds))
    if seconds >= 3600:
        return "%d:%02d:%02d" % (seconds // 3600, (seconds % 3600) // 60, seconds % 60)
    return "%d:%02d" % (seconds // 60, seconds % 60)


def die(message, code=1):
    print("错误：" + message, file=sys.stderr)
    raise SystemExit(code)


def note(message):
    print(message, flush=True)


# --------------------------------------------------------------------------- 收集文件


def find_game_root(folder):
    """接受游戏根目录或它的上一级目录，返回真正的游戏根目录。"""
    folder = os.path.abspath(folder)
    if not os.path.isdir(folder):
        die("找不到目录 %r，请指向游戏的 data 文件夹（或它的上一级目录）" % folder)

    def is_root(path):
        return all(os.path.isfile(os.path.join(path, name)) for name in REQUIRED_FILES)

    if is_root(folder):
        return folder

    candidates = []
    try:
        names = sorted(os.listdir(folder))
    except OSError as exc:
        die("无法读取目录 %r：%s" % (folder, exc))
    for name in names:
        child = os.path.join(folder, name)
        if name.startswith(".") or not os.path.isdir(child):
            continue
        if is_root(child):
            candidates.append(child)
    if len(candidates) == 1:
        note("已自动找到游戏目录：%s" % candidates[0])
        return candidates[0]
    if len(candidates) > 1:
        die(
            "%r 下有多个可能的游戏目录：\n       %s\n       请直接指定其中一个。"
            % (folder, "\n       ".join(candidates))
        )
    die(
        "%r 不像是 CLANNAD 的游戏目录：缺少 %s。\n"
        "       请指向包含 SceneZH.pck 与 GameexeZH.dat 的文件夹（通常是 Steam 的 CLANNAD/data），\n"
        "       或它的上一级目录。" % (folder, "、".join(REQUIRED_FILES))
    )


def collect(folder, include_windows):
    """返回 (游戏根目录, [(相对路径, 大小)], 被跳过的文件)，根目录文件排在前。"""
    root = find_game_root(folder)
    top, nested, skipped = [], [], []
    skipped_saves = False
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        if dirpath == root and "savedata" in dirnames:
            # `savedata/` belongs to the app (it seeds and writes it), and the
            # device never reports it back in /status, so it is not part of the
            # game data that gets imported.
            dirnames.remove("savedata")
            skipped_saves = True
        for name in sorted(filenames):
            if name.startswith("."):
                continue
            full = os.path.join(dirpath, name)
            if not os.path.isfile(full):
                continue
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            if name in WINDOWS_ONLY and not include_windows:
                skipped.append(rel)
                continue
            size = os.path.getsize(full)
            (top if "/" not in rel else nested).append((rel, size))
    files = top + nested
    if not files:
        die("%r 里没有可发送的文件" % root)
    if skipped_saves:
        note("已跳过应用管理的存档目录 savedata/（游戏文件不受影响）")
    return root, files, skipped


# --------------------------------------------------------------------------- HTTP


def _connect(host, port, timeout):
    try:
        return http.client.HTTPConnection(host, port, timeout=timeout)
    except OSError as exc:  # pragma: no cover - 取决于系统
        raise TransferError("无法连接 %s:%d（%s）" % (host, port, exc))


def _read(body):
    try:
        return json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return None


def _describe_http_error(status, payload, body):
    if status == 403:
        return "配对码错误（或失败次数过多被暂时锁定）。请核对设备屏幕上显示的配对码后重试。"
    if status == 409:
        return "设备收到的字节数与文件大小不一致，传输被丢弃；重新运行即可重传。"
    if status == 400:
        detail = payload.get("error") if isinstance(payload, dict) else None
        return "设备拒绝了请求（400）%s" % ("：" + detail if detail else "")
    if status == 404:
        return "设备上没有这个接口（404）：应用版本可能过旧。"
    detail = ""
    if isinstance(payload, dict) and payload.get("error"):
        detail = "：" + str(payload["error"])
    elif body:
        detail = "：" + body[:160].decode("utf-8", "replace")
    return "设备返回 HTTP %d%s" % (status, detail)


def _get_json(host, port, code, path, timeout=30):
    conn = _connect(host, port, timeout)
    try:
        headers = {"Accept": "application/json"}
        if code:
            headers["X-Clannad-Code"] = code
        conn.request("GET", path, headers=headers)
        resp = conn.getresponse()
        body = resp.read()
        if resp.status != 200:
            raise TransferError(_describe_http_error(resp.status, _read(body), body))
        payload = _read(body)
        if not isinstance(payload, dict):
            raise TransferError("设备的响应不是 JSON：%r" % (body[:160],))
        return payload
    except (OSError, http.client.HTTPException) as exc:
        raise TransferError("与设备通信失败：%s" % (exc,))
    finally:
        conn.close()


def get_info(host, port, code):
    """读取设备信息；不支持 /info 的旧版本返回 None（不阻断传输）。"""
    try:
        return _get_json(host, port, code, "/info")
    except TransferError as exc:
        print("提示：读取 /info 失败（%s），继续尝试 /status。" % exc, file=sys.stderr)
        return None


def get_status(host, port, code):
    """返回设备上已有文件 {相对路径: 大小}。"""
    payload = _get_json(host, port, code, "/status?code=" + urllib.parse.quote(code))
    files = payload.get("files")
    if not isinstance(files, list):
        raise TransferError("设备的 /status 响应缺少 files 列表")
    have = {}
    for item in files:
        if not isinstance(item, dict):
            continue
        rel, size = item.get("path"), item.get("size")
        if isinstance(rel, str) and isinstance(size, int):
            have[rel] = size
    return have


def upload_one(host, port, code, folder, rel, size, progress, timeout):
    path = os.path.join(folder, rel.replace("/", os.sep))
    query = urllib.parse.urlencode(
        [("path", rel), ("size", str(size)), ("code", code)], quote_via=urllib.parse.quote
    )
    conn = _connect(host, port, timeout)
    try:
        try:
            conn.putrequest("POST", "/upload?" + query, skip_accept_encoding=True)
            conn.putheader("Content-Type", "application/octet-stream")
            conn.putheader("Content-Length", str(size))
            conn.putheader("X-Clannad-Code", code)
            conn.endheaders()
            with open(path, "rb") as handle:
                while True:
                    chunk = handle.read(CHUNK)
                    if not chunk:
                        break
                    conn.send(chunk)
                    progress.add(len(chunk))
            resp = conn.getresponse()
            body = resp.read()
            payload = _read(body)
            if resp.status != 200:
                raise TransferError(_describe_http_error(resp.status, payload, body))
            if isinstance(payload, dict) and payload.get("ok") is False:
                raise TransferError("设备没有接受 %s：%s" % (rel, payload.get("error", "未知原因")))
        except (OSError, http.client.HTTPException) as exc:
            raise TransferError("传输 %s 时连接中断：%s" % (rel, exc))
    finally:
        conn.close()


# --------------------------------------------------------------------------- 进度


class Progress:
    """总体进度条（单行，\r 刷新）。"""

    def __init__(self, total_bytes, total_files):
        self.total_bytes = max(total_bytes, 1)
        self.total_files = total_files
        self.done_bytes = 0
        self.done_files = 0
        self.started = time.time()
        self.current = ""
        self.last_render = 0.0
        self.file_size = 1
        self.file_done = 0

    def file_start(self, index, rel, size):
        self.current = rel
        self.file_size = max(size, 1)
        self.file_done = 0
        print(
            "\n[%d/%d] %s (%s)" % (index, self.total_files, rel, human_bytes(size)),
            flush=True,
        )

    def add(self, n):
        self.done_bytes += n
        self.file_done += n
        self.render()

    def rollback(self):
        """一次上传失败后把已计入的字节退回，重试时重新计算进度。"""
        self.done_bytes = max(0, self.done_bytes - self.file_done)
        self.file_done = 0

    def render(self, force=False):
        now = time.time()
        if not force and now - self.last_render < 0.2:
            return
        self.last_render = now
        elapsed = max(now - self.started, 0.001)
        rate = self.done_bytes / elapsed
        remaining = max(self.total_bytes - self.done_bytes, 0)
        eta = remaining / rate if rate > 0 else 0
        pct = self.done_bytes * 100.0 / self.total_bytes
        name = self.current
        if len(name) > 46:
            name = "..." + name[-43:]
        line = "    %6.1f%%  %s  %s/s  剩余 %s  %s" % (
            pct,
            human_bytes(self.done_bytes),
            human_bytes(rate),
            human_duration(eta),
            name,
        )
        print("\r" + line[:160].ljust(120), end="", flush=True)

    def finish(self):
        self.render(force=True)
        print()
        elapsed = time.time() - self.started
        note(
            "完成：%d 个文件，%s，用时 %s（平均 %s/s）。"
            % (
                self.done_files,
                human_bytes(self.done_bytes),
                human_duration(elapsed),
                human_bytes(self.done_bytes / max(elapsed, 0.001)),
            )
        )


# --------------------------------------------------------------------------- main


def build_parser():
    parser = argparse.ArgumentParser(
        description="把 CLANNAD 游戏目录通过局域网发送到 iPhone / iPad / Vision Pro 上的应用。",
        epilog=(
            "示例：python3 tools/push_data.py --host 192.168.1.23 --code 123456 CLANNAD/data\n"
            "设备上已经存在且大小相同的文件会被跳过，中断后重新运行即可续传。"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--host", help="应用屏幕上显示的地址（例如 192.168.1.23）")
    parser.add_argument("--code", help="应用屏幕上显示的 6 位配对码")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="端口，默认 %d" % DEFAULT_PORT)
    parser.add_argument(
        "folder",
        nargs="?",
        help="游戏目录：包含 SceneZH.pck 与 GameexeZH.dat 的那一层（通常是 CLANNAD/data），也可以是它的上一级目录",
    )
    parser.add_argument(
        "--include-windows",
        action="store_true",
        help="连原版 Windows 程序（SiglusEngine_Steam.exe 等）一起发送（默认跳过）",
    )
    parser.add_argument("--dry-run", action="store_true", help="只列出将要发送的文件，不连接设备")
    parser.add_argument("--retries", type=int, default=2, help="单个文件失败后的重试次数（默认 2）")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="单次连接超时秒数（默认 300）")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if not args.folder:
        parser.error("缺少游戏目录参数（包含 SceneZH.pck 的那一层，例如 Clannad/data）")
    if not args.dry_run:
        if not args.host:
            parser.error("缺少 --host（应用屏幕上显示的地址）")
        if not args.code:
            parser.error("缺少 --code（应用屏幕上显示的配对码）")
    if args.retries < 0:
        parser.error("--retries 不能为负数")

    root, files, skipped = collect(args.folder, args.include_windows)
    total = sum(size for _, size in files)
    note("游戏目录：%s" % root)
    note("待发送：%d 个文件，共 %s" % (len(files), human_bytes(total)))
    if skipped:
        note("已跳过 %d 个 Windows 专用文件（%s）" % (len(skipped), "、".join(skipped)))
    if args.dry_run:
        for rel, size in files:
            print("  %10s  %s" % (human_bytes(size), rel))
        note("（--dry-run：未连接设备）")
        return 0

    endpoint = "%s:%d" % (args.host, args.port)
    try:
        info = get_info(args.host, args.port, args.code)
        if info:
            free = info.get("freeBytes")
            extra = "，设备剩余空间 %s" % human_bytes(free) if isinstance(free, int) else ""
            note(
                "设备：%s %s（游戏目录 %s%s）"
                % (info.get("app", APP_NAME), info.get("version", ""), info.get("root", "?"), extra)
            )
        have = get_status(args.host, args.port, args.code)
    except TransferError as exc:
        die(
            "%s\n"
            "       请确认：1) 设备与这台 Mac 在同一个 Wi-Fi；2) 应用里已打开「局域网接收游戏文件」；\n"
            "       3) 地址和配对码与屏幕上显示的一致（地址形如 192.168.1.23）。" % exc
        )

    todo = [(rel, size) for rel, size in files if have.get(rel) != size]
    skipped_count = len(files) - len(todo)
    todo_bytes = sum(size for _, size in todo)
    if not todo:
        note("设备上已经有全部 %d 个文件，无需传输。请在应用里点「重新检查」。" % len(files))
        return 0
    note(
        "需要传输 %d 个文件，共 %s（设备上已有 %d 个，跳过 %s）。"
        % (
            len(todo),
            human_bytes(todo_bytes),
            skipped_count,
            human_bytes(sum(size for rel, size in files if have.get(rel) == size)),
        )
    )

    progress = Progress(todo_bytes, len(todo))
    failed = []
    try:
        for index, (rel, size) in enumerate(todo, 1):
            progress.file_start(index, rel, size)
            attempt = 0
            ok = False
            while True:
                attempt += 1
                try:
                    upload_one(args.host, args.port, args.code, root, rel, size, progress, args.timeout)
                    ok = True
                    break
                except TransferError as exc:
                    progress.rollback()
                    if attempt > args.retries:
                        failed.append((rel, str(exc)))
                        progress.render(force=True)
                        print("\n    失败：%s" % exc, file=sys.stderr)
                        break
                    print("\n    重试 %d/%d：%s" % (attempt, args.retries, exc), file=sys.stderr)
                    time.sleep(1.0 * attempt)
            if ok:
                progress.done_files += 1
                progress.render(force=True)
                print()
    except KeyboardInterrupt:
        progress.render(force=True)
        print(
            "\n已中断。重新运行同一条命令即可从断点续传（已传完的文件会按大小跳过）。",
            file=sys.stderr,
        )
        return 130

    progress.finish()
    if failed:
        print("有 %d 个文件没有传完：" % len(failed), file=sys.stderr)
        for rel, reason in failed[:20]:
            print("  %s：%s" % (rel, reason), file=sys.stderr)
        if len(failed) > 20:
            print("  ……", file=sys.stderr)
        print("重新运行同一条命令即可续传。", file=sys.stderr)
        return 1
    note("全部发送完毕。请在应用里点「重新检查」，然后在启动页点「开始游戏」。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
