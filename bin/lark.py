#!/usr/bin/env python3
# lark.py — lark-cli 的轻封装（默认 bot 身份，首位 -u 切 user）。
#
# 设计目标：
#   - 内置 LARKSUITE_CLI_NO_UPDATE_NOTIFIER 等环境变量，调用方零配置
#   - 默认 --as bot；首位 -u 整条命令切 --as user（如 lark -u im read ...）
#   - 按场景分类的短命令，常用路径一行搞定
#
# 由 bin/lark.sh（bash 版）重写而来（argparse 化、去 jq 依赖）；旧版见 git 历史。
# 用法：lark [-u] <category> <cmd> [args...]   详见 -h 或 skills/lark/SKILL.md

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

os.environ.setdefault("LARKSUITE_CLI_NO_UPDATE_NOTIFIER", "1")
os.environ.setdefault("LARKSUITE_CLI_NO_SKILLS_NOTIFIER", "1")

PROG = "lark"
AS = "bot"  # 首位 -u 切 user（main 里设置）


def die(msg, code=2):
    print(f"{PROG}: {msg}", file=sys.stderr)
    sys.exit(code)


def need(v, name):
    if v is None or v == "":
        die(f"missing arg: {name}")
    return v


def load_text(s):
    """文本载荷归一化：'-' = stdin；'@path' = 读文件内容；其余原样。"""
    if s == "-":
        return sys.stdin.read()
    if s.startswith("@"):
        return Path(s[1:]).read_text()
    return s


def exec_cli(*args):
    """等价 bash 的 exec lark-cli：替换进程，退出码（含 10 高危门禁）原样保留。"""
    try:
        os.execvp("lark-cli", ["lark-cli", *args])
    except FileNotFoundError:
        die("lark-cli 不在 PATH（见 README 安装）", 127)


def cli_run(*args, check=True):
    p = subprocess.run(["lark-cli", *args], capture_output=True, text=True)
    if check and p.returncode != 0:
        sys.stdout.write(p.stdout)
        sys.stderr.write(p.stderr)
        sys.exit(p.returncode)
    return p


def cli_json(*args):
    return json.loads(cli_run(*args).stdout)


def A():
    return ["--as", AS]


def dump(obj):
    print(json.dumps(obj, ensure_ascii=False, indent=2))


# ===== 卡片折叠剥离 =====
# 折叠组件 collapsible_panel 被剥掉 —— 默认视图不给别人（bot/人）看 yomi trace 之类的折叠内容；
# header 标题保留：yomi 状态卡的 live 内容全在面板里，标题（🐾 Typing… 等阶段行）是唯一的暂态信号。

def card_fold_map(ctype, cid, n, order):
    """拉容器内 interactive 卡片的"剥离折叠"正文 map（message_id → header 标题 + 顶层 markdown 拼接）。
    失败返回 {}（退化保留原卡片，不拖垮主列表）。"""
    n = min(n, 50)  # 消息列表 API page_size 上限 50，超了报 99992402
    params = json.dumps(
        {"container_id_type": ctype, "container_id": cid, "sort_type": order,
         "page_size": n, "card_msg_content_type": "user_card_content"},
        separators=(",", ":"))
    try:
        data = cli_json("api", "GET", "/open-apis/im/v1/messages", "--params", params, *A())
        result = {}
        for it in (data.get("data") or {}).get("items") or []:
            if it.get("msg_type") != "interactive":
                continue
            try:
                body = json.loads((it.get("body") or {}).get("content") or "{}")
            except (json.JSONDecodeError, AttributeError):
                body = {}
            parts = []
            title = ((body.get("header") or {}).get("title") or {}).get("content")
            if title:
                parts.append(title)
            inner = body.get("body")
            elems = (inner or {}).get("elements") if isinstance(inner, dict) else None
            if elems is None:
                elems = body.get("elements")
            for e in elems or []:
                if isinstance(e, dict) and e.get("tag") == "markdown" and e.get("content"):
                    parts.append(e["content"])
            result[it.get("message_id")] = "\n".join(parts)
        return result
    except Exception:
        return {}


def strip_fold(node, cardmap):
    """递归把 interactive 卡片 content 替换为剥离折叠后的版本（cardmap 没有的 id 保持原样）。"""
    if isinstance(node, dict):
        if node.get("msg_type") == "interactive" and node.get("message_id") in cardmap:
            node = {**node,
                    "content": f"<card>\n{cardmap[node['message_id']]}\n</card>"}
        return {k: strip_fold(v, cardmap) for k, v in node.items()}
    if isinstance(node, list):
        return [strip_fold(x, cardmap) for x in node]
    return node


# ===== sticker 收藏夹（全局存储 + 按 appId 分目录；file_key 全程不出脚本）=====
# 为什么不让 key 过调用方的手：LLM "复制"长随机串是逐 token 默写，
# 极易拼接出缝合 key（2026-08-25 猫鼠 key 拼接事故）。调用方只递 关键词/行号/om_。
# 存储：<LARK_STICKER_DIR|XDG_DATA_HOME|~/.local/share>/lark/stickers/<appId>/{stickers.md, stickers/}

def sticker_dir():
    """当前 bot 的收藏目录（不存在则初始化目录 + 空索引模板）。"""
    p = subprocess.run(["lark-cli", "config", "show"], capture_output=True, text=True)
    appid = ""
    if p.returncode == 0:
        try:
            appid = json.loads(p.stdout).get("appId") or ""
        except json.JSONDecodeError:
            pass
    if not appid:
        die("sticker: 解析 appId 失败（lark-cli config show）")
    base = os.environ.get("LARK_STICKER_DIR") or os.path.join(
        os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share"),
        "lark", "stickers")
    d = Path(base) / appid
    idx = d / "stickers.md"
    if not idx.exists():
        (d / "stickers").mkdir(parents=True, exist_ok=True)
        idx.write_text("# Sticker 收藏夹索引\n\n| file_key | 内容 | 适用场景 |\n|---|---|---|\n")
    return d


def st_rows(idx):
    """索引文件 → [(绝对行号, 数据行)]（数据行 = '| `' 开头）。"""
    return [(i, l) for i, l in enumerate(idx.read_text().splitlines(), 1)
            if l.startswith("| `")]


def st_key_of(row):  # 数据行 → key（仅内部使用，绝不打印）
    parts = row.split("`")
    return parts[1] if len(parts) > 1 else ""


def st_desc_of(row):  # 数据行 → '描述 — 场景'（剥 key，安全输出）
    f = row.split("|")
    d = f[2].strip() if len(f) > 2 else ""
    s = f[3].strip() if len(f) > 3 else ""
    return f"{d} — {s}"


def st_pick(idx, sel, cmd="sticker"):
    """选唯一数据行 → (行号, 行)；无匹配 die；多匹配候选（含行号，不含 key）打 stderr，exit 3。"""
    rows = st_rows(idx)
    if sel.isdigit():
        n = int(sel)
        line = dict(rows).get(n, "")
        if not line:
            die(f"{cmd}: 第 {sel} 行不是数据行（用 sticker list 看行号）"
                if cmd == "sticker" else f"{cmd}: 第 {sel} 行不是数据行")
        return n, line
    hits = [(i, l) for i, l in rows if sel.lower() in l.lower()]
    if not hits:
        die(f"sticker: 索引没匹配到「{sel}」（sticker list 看看有啥）"
            if cmd == "sticker" else f"{cmd}: 索引没匹配到「{sel}」")
    if len(hits) > 1:
        hint = ("换更准的关键词或直接给行号" if cmd == "sticker"
                else "需唯一匹配，请用行号")
        print(f"{PROG}: {cmd}: 「{sel}」匹配 {len(hits)} 条，{hint}：", file=sys.stderr)
        for i, l in hits:
            print(f"  L{i}  {st_desc_of(l)}", file=sys.stderr)
        sys.exit(3)
    return hits[0]


def st_post(target, key, extras, capture=True):
    """底层 sticker 发送：om_=回复该消息（默认回主流，--thread 进话题），oc_=直发群。"""
    content = json.dumps({"file_key": key}, separators=(",", ":"))
    if target.startswith("om_"):
        in_thread = False
        if extras and extras[0] == "--thread":
            in_thread = True
            extras = extras[1:]
        data = json.dumps({"content": content, "msg_type": "sticker",
                           "reply_in_thread": in_thread}, separators=(",", ":"))
        argv = ["api", "POST", f"/open-apis/im/v1/messages/{target}/reply",
                "--data", data, *A(), *extras]
    elif target.startswith("oc_"):
        data = json.dumps({"receive_id": target, "content": content,
                           "msg_type": "sticker"}, separators=(",", ":"))
        argv = ["api", "POST", "/open-apis/im/v1/messages",
                "--params", '{"receive_id_type":"chat_id"}',
                "--data", data, *A(), *extras]
    else:
        die(f"sticker: target 必须是 om_（回复）或 oc_（群发）：{target}")
    if capture:
        return cli_run(*argv, check=False)
    return subprocess.run(["lark-cli", *argv])


USAGE = """lark — lark-cli 的轻封装（环境变量内置；默认 bot 身份，首位 -u 切 user：lark -u im read ...）

IM:
  lark im read <oc_> [-n N] [--asc] [--verbose] [--start <ts> --end <ts>] [--page-all]  读群消息（默认 desc 最近 20 条，N 上限 50；--start/--end 时间窗 ISO 8601；--page-all 拉全量；卡片折叠面板默认剥离，--verbose 保留）
  lark im thread <omt_|om_> [-n N] [--verbose]   读话题消息（N 上限 50，折叠同 read）
  lark im send <oc_|ou_> <text|@file|->    发消息（oc_=群 ou_=私信；--markdown 切 markdown；--image/--file/--video/--audio <路径> 发媒体文件）
  lark im reply <om_> <text|@file|->       回复消息（--thread 进话题；--markdown 富文本；--image/--file 等媒体同 send）
  lark im sticker <om_|oc_> <file_key>     发表情（om_=回复该消息默认回主流，oc_=直发群；--thread 进话题）
  lark im dl <om_> [dir] [--file-key K] [--type file]  下载消息附件/图片
  lark im mget <om_>[,<om_>...]            按 id 批量取消息
  lark im chats                            列出 bot 所在群
  lark im find <query>                     按名字搜群
  lark im members <oc_>                    列群成员（全量分页）
  lark im desc <oc_> <text>                改群描述

DOCS:
  lark doc read <url|token> [-k keyword]   读文档（-k 按关键词取片段）
  lark doc create <html|@file|->           新建文档
  lark doc append <doc> <html|@file|->     文末追加
  lark doc replace <doc> <block_id> <html|@file|->  按 block 替换

SHEETS:
  lark sheet create <title>                新建电子表格（返回 token/url）
  lark sheet read --url <url> [--sheet-name S] [--range A1:F30]   读区域（CSV，行首带 [row=N]）
  lark sheet write --url <url> [--start-cell B2] --csv '<csv|@file|->'  写区域（= 开头当公式）
  lark sheet +<shortcut> [args...]         透传 lark-cli sheets，速查见 references/sheets.md

CONTACT/CAL:
  lark contact get <ou_>                   open_id 查人
  lark cal freebusy <ou_> <start> <end>    查忙闲（RFC3339）

DRIVE:
  lark drive rm <token> <type> [--yes]     删文件（高危门禁，确认后补 --yes）
  lark drive share <token> [args...]       加协作者（透传 +member-add）

BOARD:
  lark board create <doc> [--svg] <代码|@file|->   在文档末尾插入画板（默认 mermaid，--svg 切 SVG）
  lark board export [args...]              导出画板（--whiteboard-token 必填；--output-type preview|svg|source|raw）
  lark board update [args...]              更新画板（--whiteboard-token 必填；--source 支持 @file/-；--input_format raw|plantuml|mermaid|svg）

STICKER（收藏夹全局存储，按 appId 分目录；file_key 全程不出脚本，调用方只递 关键词/行号/om_）:
  lark sticker send <oc_|om_> <关键词|行号> [--thread]   按描述/场景关键词或索引行号发表情（多匹配列候选，exit 3）
  lark sticker list [关键词]               列收藏（行号 + 描述 + 场景，不含 key）
  lark sticker add <om_> '<描述>' '<场景>'  收藏消息里的表情（自动取 key、去重、存图到收藏目录）
  lark sticker rm <行号|关键词>              删收藏（关键词须唯一匹配）
  存储：<LARK_STICKER_DIR|XDG_DATA_HOME|~/.local/share>/lark/stickers/<appId>/

逃生舱口:
  lark api <METHOD> <path> [args...]       透传 lark-cli api，如 --params/--data/--jq

约定：默认 bot 身份；首位 -u 整条命令切 user。wrapper 未覆盖的 user-only 命令
（消息全文搜索、个人日历 agenda 等）仍回退原生 lark-cli --as user。
"""

CATEGORIES = "im/doc/sheet/contact/cal/drive/board/sticker/api"


# ===== im =====

def im_read(a, extras):
    chat = need(a.chat, "oc_")
    n = min(a.n, 50)  # API page_size 上限 50；更多用 --page-token 翻页或 --page-all
    order = "asc" if a.asc else "desc"
    if a.verbose:
        exec_cli("im", "+chat-messages-list", "--chat-id", chat, "--order", order,
                 "--page-size", str(n), "--no-reactions", "--format", "json",
                 *A(), *extras)
    sort = "ByCreateTimeAsc" if order == "asc" else "ByCreateTimeDesc"
    cardmap = card_fold_map("chat", chat, n, sort)
    p = cli_run("im", "+chat-messages-list", "--chat-id", chat, "--order", order,
                "--page-size", str(n), "--no-reactions", "--format", "json",
                *A(), *extras, check=False)
    if p.returncode != 0:
        sys.stdout.write(p.stdout)
        sys.stderr.write(p.stderr)
        sys.exit(p.returncode)
    dump(strip_fold(json.loads(p.stdout), cardmap))


def im_thread(a, extras):
    tid = need(a.tid, "thread_id")
    n = min(a.n, 50)  # API page_size 上限 50；更多用 --page-token 翻页
    if a.verbose:
        exec_cli("im", "+threads-messages-list", "--thread", tid, "--order", "desc",
                 "--page-size", str(n), "--format", "json", *A(), *extras)
    # card_fold_map 的 thread 容器要 omt_；传 om_（root 消息）时先解析出 thread_id。
    cid = tid
    if tid.startswith("om_"):
        msg = cli_json("api", "GET", f"/open-apis/im/v1/messages/{tid}", *A())
        cid = (((msg.get("data") or {}).get("items") or [{}])[0]).get("thread_id") or ""
        if not cid:
            die(f"im thread: {tid} 不在话题内，无法取 thread_id")
    cardmap = card_fold_map("thread", cid, n, "ByCreateTimeDesc")
    p = cli_run("im", "+threads-messages-list", "--thread", tid, "--order", "desc",
                "--page-size", str(n), "--format", "json", *A(), *extras, check=False)
    if p.returncode != 0:
        sys.stdout.write(p.stdout)
        sys.stderr.write(p.stderr)
        sys.exit(p.returncode)
    dump(strip_fold(json.loads(p.stdout), cardmap))


MSGTYPES = ("text", "markdown", "image", "file", "video", "audio")
MEDIA_FLAGS = ("--markdown", "--image", "--file", "--video", "--audio")


def msg_body(msgtype, body, cmd):
    """媒体/文件是路径/URL/key，直接透传（lark-cli 自行上传），不当文本读。"""
    if msgtype in ("image", "file", "video", "audio"):
        return need(body, f"{msgtype} 路径/URL/key")
    if body is None:
        die(f"{cmd}: 缺正文（文本、@file 或 -）")
    return load_text(body)


def im_send(rest):
    # 手搓解析（与 bash 版语义一致）：msgtype flag 只认 target 后第一位。
    # 不用 argparse 的原因：nargs='?' 位置参数遇可选 flag 会提前"吃饱"，
    # 导致 flag 后的正文被挤进 extras（argparse 经典坑）。
    target = need(rest[0] if rest else None, "oc_|ou_")
    rest = rest[1:]
    msgtype = "text"
    if rest and rest[0] in MEDIA_FLAGS:
        msgtype = rest[0][2:]
        rest = rest[1:]
    body = msg_body(msgtype, rest[0] if rest else None, "im send")
    extras = rest[1:] if rest else []
    if target.startswith("oc_"):
        exec_cli("im", "+messages-send", "--chat-id", target,
                 f"--{msgtype}", body, *A(), *extras)
    elif target.startswith("ou_"):
        exec_cli("im", "+messages-send", "--user-id", target,
                 f"--{msgtype}", body, *A(), *extras)
    else:
        die(f"im send: target 必须是 oc_（群）或 ou_（私信）：{target}")


def im_reply(rest):
    # 同 bash：body 前可叠任意个 --thread/媒体 flag（msgtype 后者覆盖前者）。
    mid = need(rest[0] if rest else None, "om_")
    rest = rest[1:]
    pre, msgtype = [], "text"
    while rest:
        if rest[0] == "--thread":
            pre.append("--reply-in-thread")
        elif rest[0] in MEDIA_FLAGS:
            msgtype = rest[0][2:]
        else:
            break
        rest = rest[1:]
    body = msg_body(msgtype, rest[0] if rest else None, "im reply")
    extras = rest[1:] if rest else []
    exec_cli("im", "+messages-reply", "--message-id", mid,
             f"--{msgtype}", body, *A(), *pre, *extras)


def walk_keys(node, acc):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in ("image_key", "file_key") and isinstance(v, str) and v:
                acc.add(v)
            else:
                walk_keys(v, acc)
    elif isinstance(node, list):
        for x in node:
            walk_keys(x, acc)


def im_dl(a):
    mid = need(a.om, "om_")
    outdir = a.outdir or "."
    if os.path.isabs(outdir) or ".." in outdir:
        die("im dl: 目录只接受 cwd 内相对路径")
    os.makedirs(outdir, exist_ok=True)
    if a.file_key:
        rtype = a.type or ("image" if a.file_key.startswith("img_") else "file")
        exec_cli("im", "+messages-resources-download", "--message-id", mid,
                 "--file-key", a.file_key, "--type", rtype,
                 "--output", os.path.join(outdir, a.file_key), *A())
    # 全量：读消息体枚举 image_key/file_key（post/img/file 消息通吃）
    p = cli_run("api", "GET", f"/open-apis/im/v1/messages/{mid}", *A(), check=False)
    if p.returncode != 0:
        sys.stderr.write(p.stderr)
        die(f"im dl: 读消息失败 {mid}")
    content = (((json.loads(p.stdout).get("data") or {}).get("items") or [{}])[0]
               .get("body") or {}).get("content")
    keys = set()
    try:
        walk_keys(json.loads(content), keys)
    except (json.JSONDecodeError, TypeError):
        pass
    if not keys:
        die(f"im dl: 消息无附件 {mid}")
    rc = 0
    for k in sorted(keys):
        t = "image" if k.startswith("img_") else "file"
        r = subprocess.run(["lark-cli", "im", "+messages-resources-download",
                            "--message-id", mid, "--file-key", k, "--type", t,
                            "--output", os.path.join(outdir, k), *A()])
        if r.returncode != 0:
            rc = 1
    sys.exit(rc)


def im_main(argv):
    if not argv:
        die("im: 缺子命令（read/thread/send/reply/sticker/dl/mget/chats/find/members/desc）")
    sub, rest = argv[0], argv[1:]

    if sub == "read":
        p = argparse.ArgumentParser(prog="lark im read")
        p.add_argument("chat", nargs="?")
        p.add_argument("-n", type=int, default=20)
        p.add_argument("--asc", action="store_true")
        p.add_argument("--verbose", action="store_true")
        a, ex = p.parse_known_args(rest)
        im_read(a, ex)
    elif sub == "thread":
        p = argparse.ArgumentParser(prog="lark im thread")
        p.add_argument("tid", nargs="?")
        p.add_argument("-n", type=int, default=20)
        p.add_argument("--verbose", action="store_true")
        a, ex = p.parse_known_args(rest)
        im_thread(a, ex)
    elif sub == "send":
        im_send(rest)
    elif sub == "reply":
        im_reply(rest)
    elif sub == "sticker":
        target = need(rest[0] if rest else None, "om_|oc_")
        key = need(rest[1] if len(rest) > 1 else None, "file_key")
        sys.exit(st_post(target, key, rest[2:], capture=False).returncode)
    elif sub == "dl":
        p = argparse.ArgumentParser(prog="lark im dl")
        p.add_argument("om", nargs="?")
        p.add_argument("outdir", nargs="?")
        p.add_argument("--file-key", dest="file_key")
        p.add_argument("--type", dest="type")
        im_dl(p.parse_args(rest))
    elif sub == "mget":
        ids = need(rest[0] if rest else None, "om_ids")
        exec_cli("im", "+messages-mget", "--message-ids", ids, *A(), *rest[1:])
    elif sub == "chats":
        exec_cli("im", "+chat-list", *A(), "--page-all", *rest)
    elif sub == "find":
        q = need(rest[0] if rest else None, "query")
        exec_cli("im", "+chat-search", "--query", q, *A(), *rest[1:])
    elif sub == "members":
        chat = need(rest[0] if rest else None, "oc_")
        exec_cli("im", "+chat-members-list", "--chat-id", chat, *A(), "--page-all", *rest[1:])
    elif sub == "desc":
        chat = need(rest[0] if rest else None, "oc_")
        text = need(rest[1] if len(rest) > 1 else None, "description")
        exec_cli("im", "+chat-update", "--chat-id", chat,
                 "--description", text, *A(), *rest[2:])
    else:
        die(f"im: 未知子命令 {sub}")


# ===== doc =====

def auto_subscribe(tok, file_type, out):
    """建完自动订阅（评论/更新通知回流 bot）；订阅失败不拖垮建单。"""
    if not tok:
        return
    s = subprocess.run(["lark-cli", "api", "POST",
                        f"/open-apis/drive/v1/files/{tok}/subscribe",
                        "--params", json.dumps({"file_type": file_type},
                                               separators=(",", ":")), *A()],
                       capture_output=True)
    if s.returncode == 0:
        print(f"lark: 已自动订阅 {tok}", file=sys.stderr)
    else:
        print(f"lark: 警告：自动订阅失败（文档已建好）{tok}", file=sys.stderr)


def doc_main(argv):
    if not argv:
        die("doc: 缺子命令（read/create/append/replace）")
    sub, rest = argv[0], argv[1:]

    if sub == "read":
        p = argparse.ArgumentParser(prog="lark doc read")
        p.add_argument("doc", nargs="?")
        p.add_argument("-k", dest="keyword")
        a, ex = p.parse_known_args(rest)
        doc = need(a.doc, "url|token")
        extra = ["--scope", "keyword", "--keyword", a.keyword] if a.keyword else []
        exec_cli("docs", "+fetch", "--doc", doc, *A(), *extra, *ex)
    elif sub == "create":
        p = argparse.ArgumentParser(prog="lark doc create")
        p.add_argument("content", nargs="?")
        a, ex = p.parse_known_args(rest)
        body = load_text(need(a.content, "内容（html、@file 或 -）"))
        r = subprocess.run(["lark-cli", "docs", "+create", "--content", body, *A(), *ex],
                           stdout=subprocess.PIPE, text=True)
        print(r.stdout.rstrip("\n"))
        if r.returncode != 0:
            sys.exit(r.returncode)
        tok = ""
        try:
            d = json.loads(r.stdout).get("data") or {}
            tok = d.get("document_id") or (d.get("document") or {}).get("document_id") or ""
        except json.JSONDecodeError:
            pass
        auto_subscribe(tok, "docx", r.stdout)
    elif sub == "append":
        doc = need(rest[0] if rest else None, "doc")
        body = load_text(need(rest[1] if len(rest) > 1 else None, "内容（html、@file 或 -）"))
        exec_cli("docs", "+update", "--doc", doc, "--command", "append",
                 "--content", body, *A(), *rest[2:])
    elif sub == "replace":
        doc = need(rest[0] if rest else None, "doc")
        block = need(rest[1] if len(rest) > 1 else None, "block_id")
        body = load_text(need(rest[2] if len(rest) > 2 else None, "内容（html、@file 或 -）"))
        exec_cli("docs", "+update", "--doc", doc, "--command", "block_replace",
                 "--block-id", block, "--content", body, *A(), *rest[3:])
    else:
        die(f"doc: 未知子命令 {sub}")


# ===== sheet =====

def sheet_main(argv):
    if not argv:
        die("sheet: 缺子命令（create/read/write/+shortcut 透传）")
    sub, rest = argv[0], argv[1:]

    if sub == "create":
        title = need(rest[0] if rest else None, "title")
        data = json.dumps({"title": title}, separators=(",", ":"))
        r = subprocess.run(["lark-cli", "sheets", "spreadsheets", "create",
                            "--data", data, *A(), *rest[1:]],
                           stdout=subprocess.PIPE, text=True)
        print(r.stdout.rstrip("\n"))
        if r.returncode != 0:
            sys.exit(r.returncode)
        tok = ""
        try:
            tok = ((json.loads(r.stdout).get("data") or {}).get("spreadsheet") or {}) \
                .get("spreadsheet_token") or ""
        except json.JSONDecodeError:
            pass
        auto_subscribe(tok, "sheet", r.stdout)
    elif sub == "read":
        exec_cli("sheets", "+csv-get", *A(), *rest)
    elif sub == "write":
        exec_cli("sheets", "+csv-put", *A(), *rest)
    elif sub.startswith("+"):
        exec_cli("sheets", sub, *A(), *rest)
    else:
        die(f"sheet: 未知子命令 {sub}（create/read/write/+shortcut）")


# ===== contact / cal / drive / board =====

def contact_main(argv):
    if not argv or argv[0] != "get":
        die("contact: 仅支持 get <ou_>")
    uid = need(argv[1] if len(argv) > 1 else None, "ou_")
    exec_cli("contact", "+get-user", "--user-id", uid, *A(), *argv[2:])


def cal_main(argv):
    if not argv or argv[0] != "freebusy":
        die("cal: 仅支持 freebusy <ou_> <start> <end>")
    uid = need(argv[1] if len(argv) > 1 else None, "ou_")
    start = need(argv[2] if len(argv) > 2 else None, "start")
    end = need(argv[3] if len(argv) > 3 else None, "end")
    exec_cli("calendar", "+freebusy", "--user-id", uid,
             "--start", start, "--end", end, *A(), *argv[4:])


def drive_main(argv):
    if not argv:
        die("drive: 缺子命令（rm/share）")
    sub, rest = argv[0], argv[1:]
    if sub == "rm":
        token = need(rest[0] if rest else None, "file_token")
        type_ = need(rest[1] if len(rest) > 1 else None, "type")
        exec_cli("drive", "+delete", "--file-token", token, "--type", type_,
                 *A(), *rest[2:])
    elif sub == "share":
        token = need(rest[0] if rest else None, "token")
        exec_cli("drive", "+member-add", "--token", token, *A(), *rest[1:])
    else:
        die(f"drive: 未知子命令 {sub}")


def board_main(argv):
    sub = need(argv[0] if argv else None, "create|export|update")
    rest = argv[1:]
    if sub == "create":
        doc = need(rest[0] if rest else None, "doc")
        rest = rest[1:]
        fmt = "mermaid"
        if rest and rest[0] == "--svg":
            fmt = "svg"
            rest = rest[1:]
        code = load_text(need(rest[0] if rest else None, "内容（mermaid/svg 代码、@file 或 -）"))
        body = f'<whiteboard type="{fmt}">\n{code}\n</whiteboard>'
        exec_cli("docs", "+update", "--doc", doc, "--command", "append",
                 "--content", body, *A(), *rest[1:])
    elif sub in ("export", "update"):
        exec_cli("whiteboard", f"+{sub}", *A(), *rest)
    else:
        die(f"board: 未知子命令 {sub}（create/export/update）")


# ===== sticker（收藏夹 CRUD + 关键词发送：file_key 只在脚本内部流转，不向 stdout 暴露）=====

def sticker_main(argv):
    if not argv:
        die("sticker: 缺子命令（send/list/add/rm）")
    sub, rest = argv[0], argv[1:]
    idx = sticker_dir() / "stickers.md"

    if sub == "send":
        target = need(rest[0] if rest else None, "oc_|om_")
        sel = need(rest[1] if len(rest) > 1 else None, "关键词|行号")
        _, row = st_pick(idx, sel)
        key = st_key_of(row)
        if not key:
            die("sticker send: 数据行解析不出 file_key（索引格式坏了？）")
        p = st_post(target, key, rest[2:])
        if p.returncode != 0:
            sys.stderr.write(p.stderr)
            sys.exit(p.returncode)
        # 结果剥掉 body（含 file_key）再输出
        try:
            out = json.loads(p.stdout)
        except json.JSONDecodeError:
            out = {}
        dump({"ok": out.get("ok"), "identity": out.get("identity"),
              "message_id": (out.get("data") or {}).get("message_id"),
              "sent": st_desc_of(row), "error": out.get("error")})
    elif sub == "list":
        rows = st_rows(idx)
        if rest:
            rows = [r for r in rows if rest[0].lower() in r[1].lower()]
        if not rows:
            print("（无匹配）")
            return
        for i, l in rows:
            print(f"L{str(i):<5} {st_desc_of(l)}")
    elif sub == "add":
        om = need(rest[0] if rest else None, "om_")
        desc = need(rest[1] if len(rest) > 1 else None, "描述")
        scene = need(rest[2] if len(rest) > 2 else None, "场景关键词")
        msg = cli_json("api", "GET", f"/open-apis/im/v1/messages/{om}", *A())
        item = ((msg.get("data") or {}).get("items") or [{}])[0]
        if item.get("msg_type") != "sticker":
            die("sticker add: 该消息不是 sticker")
        content = (item.get("body") or {}).get("content")
        if isinstance(content, str):
            try:
                content = json.loads(content)
            except json.JSONDecodeError:
                pass
        key = content.get("file_key") if isinstance(content, dict) else None
        if not key:
            die("sticker add: 消息里解析不出 file_key")
        text = idx.read_text()
        if key in text:
            old = next((l for l in text.splitlines() if key in l), "")
            print(f"{PROG}: 已收藏过，不重复入库：{st_desc_of(old)}")
            return
        with idx.open("a") as f:
            f.write(f"| `{key}` | {desc.replace('|', '、')} | {scene.replace('|', '、')} |\n")
        r = subprocess.run(["lark-cli", "im", "+messages-resources-download",
                            "--message-id", om, "--file-key", key, "--type", "file",
                            "--output", str(idx.parent / "stickers" / key), *A()],
                           capture_output=True)
        if r.returncode != 0:
            print(f"{PROG}: 警告：表情图片下载失败（索引已入）{om}", file=sys.stderr)
        print(f"{PROG}: 已收藏：{desc} — {scene}")
    elif sub == "rm":
        sel = need(rest[0] if rest else None, "行号|关键词")
        lineno, row = st_pick(idx, sel, cmd="sticker rm")
        lines = idx.read_text().splitlines(keepends=True)
        del lines[lineno - 1]
        idx.write_text("".join(lines))
        print(f"{PROG}: 已删除 L{lineno}：{st_desc_of(row)}")
    else:
        die(f"sticker: 未知子命令 {sub}（send/list/add/rm）")


# ===== api 逃生舱口 =====

def api_main(argv):
    method = need(argv[0] if argv else None, "METHOD")
    path = need(argv[1] if len(argv) > 1 else None, "path")
    exec_cli("api", method, path, *A(), *argv[2:])


def main():
    global AS
    args = sys.argv[1:]
    if not args:
        sys.stdout.write(USAGE)
        sys.exit(2)
    if args[0] == "-u":
        AS = "user"
        args = args[1:]
        if not args:
            sys.stdout.write(USAGE)
            sys.exit(2)
    category, rest = args[0], args[1:]
    if category in ("-h", "--help", "help"):
        sys.stdout.write(USAGE)
        return
    handler = {
        "im": im_main, "doc": doc_main, "sheet": sheet_main,
        "contact": contact_main, "cal": cal_main, "drive": drive_main,
        "board": board_main, "sticker": sticker_main, "api": api_main,
    }.get(category)
    if not handler:
        die(f"未知分类：{category}（{CATEGORIES}，-h 看帮助）")
    handler(rest)


if __name__ == "__main__":
    main()
