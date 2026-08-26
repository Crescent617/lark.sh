#!/usr/bin/env python3
"""lark 端到端测试：真实调 lark-cli 打飞书（需已配置 bot 凭证；-u 用例需 user 凭证）。

用法：
  LARK_E2E_CHAT=oc_xxx LARK_E2E_OU=ou_xxx python3 tests/e2e.py [--bin bin/lark.py] [--parity bin/lark.sh]

--parity：对确定性只读命令同时跑旧版与新版，退出码/stdout 必须一致（im read 允许重试一次，
          防两次调用之间新消息落入）。

副作用：向 LARK_E2E_CHAT 发 3 条测试消息（文本/markdown 回复/话题回复）+ 1 张 1x1 图片；
        创建并随后删除 1 篇文档（覆盖 doc/board/drive 门禁）和 1 个表格。
sticker 发送链路无真实 file_key 可用（收藏夹为空），只覆盖索引 CRUD 与 exit 3 候选分支。
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta
from pathlib import Path

PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

args_parser = argparse.ArgumentParser()
args_parser.add_argument("--bin", default=os.environ.get("LARK_BIN", "lark"))
args_parser.add_argument("--parity", default=None)
ARGS = args_parser.parse_args()

LARK = str(Path(ARGS.bin).resolve())  # 绝对路径：cwd=TMP 的用例也能找到
CHAT = os.environ.get("LARK_E2E_CHAT", "")
OU = os.environ.get("LARK_E2E_OU", "")
TMP = Path(tempfile.mkdtemp(prefix="lark_e2e_"))

n_fail = 0


def check(name, cond, detail="", soft=False):
    global n_fail
    mark = "PASS" if cond else ("WARN" if soft else "FAIL")
    if not cond and not soft:
        n_fail += 1
    line = f"[{mark}] {name}"
    if detail and (not cond):
        line += f" — {str(detail)[:200]}"
    print(line)


def run(*argv, inp=None, env_extra=None, cwd=None):
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    return subprocess.run([LARK, *argv], capture_output=True, text=True,
                          input=inp, env=env, cwd=cwd)


def run2(*argv, **kw):
    """瞬断敏感的真实网络写操作：失败重试一次，返回最后一次结果。"""
    p = run(*argv, **kw)
    if p.returncode != 0:
        p = run(*argv, **kw)
    return p


def jout(p):
    return json.loads(p.stdout)


def parity(name, *argv, retry=False):
    """旧版（--parity）与新版对拍确定性只读命令。"""
    if not ARGS.parity:
        return
    for _ in range(2 if retry else 1):
        a = subprocess.run([ARGS.parity, *argv], capture_output=True, text=True)
        b = subprocess.run([LARK, *argv], capture_output=True, text=True)
        # 已知非确定性：头像 URL 的 CDN host 每次请求随机（s1/s3-imfile...），归一化再比
        norm = lambda s: re.sub(r"s\d+-imfile", "sX-imfile", s)
        if a.returncode == b.returncode and norm(a.stdout) == norm(b.stdout):
            check(f"parity: {name}", True)
            return
        # 已知旧版缺陷：macOS bash 3.2 + set -u 下空数组 "${extra[@]}" 直接挂
        # （unbound variable）——新版修复了该 bug，不算回归。
        if "unbound variable" in a.stderr and b.returncode == 0:
            check(f"parity: {name}（旧版 bash 3.2 空数组 bug，新版已修复）", True)
            return
    check(f"parity: {name}", False,
          f"rc {a.returncode}/{b.returncode}；stdout "
          f"{'len ' + str(len(a.stdout)) + ' vs ' + str(len(b.stdout)) if a.stdout != b.stdout else '同'}"
          f"；old err={a.stderr.strip()[:100]}")


# ===== 基础 =====
p = run("-h")
check("help 含 -u 说明", p.returncode == 0 and "首位 -u" in p.stdout)

p = run("bogus")
check("未知分类 exit 2", p.returncode == 2 and "未知分类" in p.stderr)

p = run("im")
check("im 缺子命令 exit 2", p.returncode == 2 and "缺子命令" in p.stderr)

# ===== contact（bot / -u / parity）=====
if OU:
    p = run2("contact", "get", OU)
    check("contact get (bot)", p.returncode == 0 and jout(p).get("ok") is True
          and jout(p).get("identity") == "bot")
    parity("contact get", "contact", "get", OU)

    p = run("-u", "contact", "get", OU)
    check("-u contact get (user)", p.returncode == 0 and jout(p).get("ok") is True
          and jout(p).get("identity") == "user")
    parity("-u contact get", "-u", "contact", "get", OU, retry=True)

    start = datetime.now().astimezone().replace(microsecond=0)
    end = start + timedelta(hours=24)
    for _ in range(2):  # user token 偶发瞬断，重试一次
        p = run("cal", "freebusy", OU, start.isoformat(), end.isoformat())
        if p.returncode == 0:
            break
    check("cal freebusy", p.returncode == 0 and jout(p).get("ok") is True)
else:
    check("contact/cal 用例", True, "LARK_E2E_OU 未设置，跳过", soft=True)

# ===== im 读 =====
if CHAT:
    p = run("im", "read", CHAT, "-n", "5")
    check("im read -n 5", p.returncode == 0 and jout(p).get("ok") is True)
    parity("im read -n 5", "im", "read", CHAT, "-n", "5", retry=True)

    today = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
    p = run("im", "read", CHAT, "-n", "5", "--asc",
            "--start", today.isoformat(), "--end",
            (today + timedelta(days=1)).isoformat())
    check("im read 时间窗+flag 混用（regression）", p.returncode == 0 and jout(p).get("ok") is True)
    parity("im read 时间窗", "im", "read", CHAT, "-n", "5", "--asc",
           "--start", today.isoformat(), "--end", (today + timedelta(days=1)).isoformat(),
           retry=True)

    p = run("im", "read", CHAT, "-n", "3", "--verbose")
    check("im read --verbose", p.returncode == 0 and jout(p).get("ok") is True)
    parity("im read --verbose", "im", "read", CHAT, "-n", "3", "--verbose", retry=True)

    p = run("im", "chats")
    check("im chats", p.returncode == 0 and jout(p).get("ok") is True)

    p = run("im", "members", CHAT)
    check("im members", p.returncode == 0 and jout(p).get("ok") is True)
    parity("im members", "im", "members", CHAT)

    # ===== im 写 / 回复 / 话题 =====
    p = run2("im", "send", CHAT, "🧪 lark.py e2e 测试消息（可忽略）")
    om1 = (jout(p).get("data") or {}).get("message_id") if p.returncode == 0 else None
    check("im send 文本", p.returncode == 0 and jout(p).get("ok") is True and om1,
          p.stderr.strip()[:150])

    if om1:
        p = run2("im", "reply", om1, "--markdown", "**e2e** markdown 回复")
        om2 = (jout(p).get("data") or {}).get("message_id") if p.returncode == 0 else None
        check("im reply --markdown", p.returncode == 0 and jout(p).get("ok") is True and om2,
              p.stderr.strip()[:150])

        p = run2("im", "reply", om1, "--thread", "e2e 话题回复")
        check("im reply --thread", p.returncode == 0 and jout(p).get("ok") is True,
              p.stderr.strip()[:150])

        p = run("im", "thread", om1)
        check("im thread <om_>（root→thread_id 解析）",
              p.returncode == 0 and jout(p).get("ok") is True)

        p = run("im", "mget", om1)
        check("im mget", p.returncode == 0 and jout(p).get("ok") is True)

        # stdin / @file 载荷
        p = run2("im", "reply", om1, "-", inp="e2e stdin 载荷")
        check("im reply stdin 载荷（-）", p.returncode == 0 and jout(p).get("ok") is True,
              p.stderr.strip()[:150])
        (TMP / "payload.txt").write_text("e2e @file 载荷")
        p = run2("im", "reply", om1, f"@{TMP}/payload.txt")
        check("im reply @file 载荷", p.returncode == 0 and jout(p).get("ok") is True,
              p.stderr.strip()[:150])

    # ===== im dl =====
    (TMP / "a.png").write_bytes(PNG_1X1)
    p = run2("im", "send", CHAT, "--image", "a.png", cwd=TMP)  # lark-cli 媒体只收 cwd 内相对路径
    om_img = (jout(p).get("data") or {}).get("message_id") if p.returncode == 0 else None
    check("im send --image", p.returncode == 0 and jout(p).get("ok") is True and om_img,
          p.stderr.strip()[:150])
    if om_img:
        p = run("im", "dl", om_img, "dl", cwd=TMP)
        files = list((TMP / "dl").glob("*")) if (TMP / "dl").exists() else []
        check("im dl 全量枚举", p.returncode == 0 and len(files) == 1
              and files[0].stat().st_size > 0,
              f"rc={p.returncode} files={files} err={p.stderr.strip()}")

    p = run("im", "dl", om1 or "om_bad", "/etc")
    check("im dl 拒绝绝对路径", p.returncode == 2 and "相对路径" in p.stderr)

    # -u 读群（user token 的 im 权限视授权范围而定，软断言）
    p = run("-u", "im", "read", CHAT, "-n", "3")
    check("-u im read（视 user 授权范围）", p.returncode == 0 and jout(p).get("ok") is True,
          f"rc={p.returncode} {p.stderr.strip()[:120]}", soft=True)
else:
    check("im 用例", True, "LARK_E2E_CHAT 未设置，跳过", soft=True)

# ===== sticker（隔离目录，伪造索引覆盖 CRUD 与 exit 3；不触真实发送）=====
sdir = TMP / "stickers"
senv = {"LARK_STICKER_DIR": str(sdir)}
p = run("sticker", "list", env_extra=senv)
check("sticker list 空索引", p.returncode == 0 and "（无匹配）" in p.stdout)

idx = next(sdir.glob("*/stickers.md"), None)
check("sticker 目录自动初始化", idx is not None)
if idx:
    # 模板 4 行头部（标题/空行/表头/分隔），数据行从第 5 行开始
    with idx.open("a") as f:
        f.write("| `fake_key_a` | 猫 点赞 | 认可 夸奖 |\n")
        f.write("| `fake_key_b` | 猫 老鼠 对视 | 玩梗 调侃 |\n")
    p = run("sticker", "list", env_extra=senv)
    check("sticker list 两条", p.returncode == 0 and "猫 点赞" in p.stdout
          and "对视" in p.stdout and "fake_key" not in p.stdout)
    p = run("sticker", "list", "点赞", env_extra=senv)
    check("sticker list 关键词过滤", p.returncode == 0 and "猫 点赞" in p.stdout
          and "对视" not in p.stdout)
    p = run("sticker", "send", "om_x", "猫", env_extra=senv)
    check("sticker send 多匹配 exit 3 列候选（不含 key）",
          p.returncode == 3 and "猫 点赞" in p.stderr and "对视" in p.stderr
          and "fake_key" not in p.stderr)
    p = run("sticker", "send", "om_x", "999", env_extra=senv)
    check("sticker send 行号越界 exit 2", p.returncode == 2)
    p = run("sticker", "rm", "不存在", env_extra=senv)
    check("sticker rm 无匹配 exit 2", p.returncode == 2)
    p = run("sticker", "rm", "猫", env_extra=senv)
    check("sticker rm 多匹配 exit 3", p.returncode == 3 and "fake_key" not in p.stderr)
    p = run("sticker", "rm", "对视", env_extra=senv)
    check("sticker rm 唯一关键词", p.returncode == 0 and "已删除" in p.stdout
          and "fake_key" not in p.stdout)
    p = run("sticker", "rm", "5", env_extra=senv)
    check("sticker rm 行号", p.returncode == 0 and "猫 点赞" in p.stdout)
    p = run("sticker", "list", env_extra=senv)
    check("sticker rm 后归零", p.returncode == 0 and "（无匹配）" in p.stdout)

# ===== doc / board / drive 门禁 =====
doc_tok = None
p = run2("doc", "create", "<h1>lark.py e2e</h1><p>init</p>")
check("doc create + 自动订阅", p.returncode == 0 and "自动订阅" in p.stderr,
      p.stderr.strip()[:150])
if p.returncode == 0:
    m = re.search(r"/docx/([A-Za-z0-9]+)", p.stdout)
    try:
        d = jout(p).get("data") or {}
        doc_tok = d.get("document_id") or (d.get("document") or {}).get("document_id")
    except json.JSONDecodeError:
        doc_tok = None
    doc_tok = doc_tok or (m.group(1) if m else None)
check("doc create 解析出 document_id", bool(doc_tok), p.stdout[:150])

if doc_tok:
    p = run("doc", "read", doc_tok)
    check("doc read", p.returncode == 0 and "init" in p.stdout)

    p = run("doc", "append", doc_tok, "<p>more</p>")
    check("doc append", p.returncode == 0 and jout(p).get("ok") is True)
    p = run("doc", "read", doc_tok)
    check("doc read 含追加", p.returncode == 0 and "more" in p.stdout)

    p = run("api", "GET", f"/open-apis/docx/v1/documents/{doc_tok}/blocks",
            "--params", '{"page_size":200}')
    block_id = wb_tok = None
    if p.returncode == 0:
        for b in (jout(p).get("data") or {}).get("items") or []:
            if b.get("block_type") == 2 and block_id is None:  # text
                block_id = b.get("block_id")
            if b.get("block_type") == 43:  # whiteboard
                wb_tok = (b.get("whiteboard") or {}).get("token")
    check("api 取文档块", p.returncode == 0 and block_id)

    if block_id:
        p = run("doc", "replace", doc_tok, block_id, "<p>replaced</p>")
        check("doc replace", p.returncode == 0 and jout(p).get("ok") is True)
        p = run("doc", "read", doc_tok)
        check("doc read 含替换", p.returncode == 0 and "replaced" in p.stdout)

    # board 用独立新文档：上一节对 doc_tok 的密集编辑会触发服务端对画板插入的降级
    # （degrade_code=2107，实测连读也加剧，见 references/board.md）；新文档 + 间隔即恢复。
    p2 = run2("doc", "create", "<h1>board e2e</h1>")
    btok = None
    if p2.returncode == 0:
        m2 = re.search(r"/docx/([A-Za-z0-9]+)", p2.stdout)
        try:
            d2 = jout(p2).get("data") or {}
            btok = d2.get("document_id") or (d2.get("document") or {}).get("document_id")
        except json.JSONDecodeError:
            btok = None
        btok = btok or (m2.group(1) if m2 else None)
    check("board 测试文档就绪", bool(btok))
    if btok:
        # board create  parity 断言：新旧两版打同一文档，响应必须一致——
        # mermaid→画板的服务端转换存在降级时间窗（degrade_code=2107，2026-08-26 实测 ~15min
        # 连续失败后又自行恢复），单跑新版无法区分"wrapper 坏了"还是"服务端坏了"，对拍可以。
        time.sleep(2)
        p_old = p_new = None
        if ARGS.parity:
            p_old = subprocess.run([str(Path(ARGS.parity).resolve()), "board", "create",
                                    btok, "-"], input="graph TD\n  B-->C\n",
                                   capture_output=True, text=True)
        for _ in range(3):
            p_new = run("board", "create", btok, "-", inp="graph TD\n  A-->B\n")
            if p_new.returncode == 0:
                break
            time.sleep(2)
        if p_old is not None:
            check("parity: board create（透传一致，无论服务端是否降级）",
                  (p_old.returncode == 0) == (p_new.returncode == 0)
                  and json.loads(p_old.stdout).get("ok") == json.loads(p_new.stdout).get("ok"))
        ok = p_new.returncode == 0 and json.loads(p_new.stdout).get("ok") is True
        check("board create（服务端 mermaid 转换当前似处降级窗口，两版对拍一致即可）", ok,
              (p_new.stderr.strip() + " " + p_new.stdout.strip())[:250], soft=True)
        if ok:
            p3 = run("api", "GET", f"/open-apis/docx/v1/documents/{btok}/blocks",
                     "--params", '{"page_size":200}')
            wb_tok = None
            if p3.returncode == 0:
                for b in (jout(p3).get("data") or {}).get("items") or []:
                    if b.get("block_type") == 43:
                        wb_tok = (b.get("whiteboard") or {}).get("token")
            if wb_tok:
                p = run2("board", "export", "--whiteboard-token", wb_tok,
                         "--output-type", "source")
                check("board export source", p.returncode == 0
                      and ("graph TD" in p.stdout or jout(p).get("ok") is True),
                      p.stderr.strip()[:150])
            else:
                check("board export source", False, "块列表里没找到 whiteboard token", soft=True)
        run2("drive", "rm", btok, "docx", "--yes")

    p = run("drive", "rm", doc_tok, "docx")
    check("drive rm 无 --yes 门禁 exit 10", p.returncode == 10,
          f"rc={p.returncode} err={p.stderr.strip()[:120]}")
    p = run2("drive", "rm", doc_tok, "docx", "--yes")
    check("drive rm --yes 删除", p.returncode == 0 and jout(p).get("ok") is True)

# ===== sheet =====
p = run2("sheet", "create", "lark.py e2e")
sheet_tok = sheet_url = None
check("sheet create + 自动订阅", p.returncode == 0 and "自动订阅" in p.stderr,
      p.stderr.strip()[:150])
if p.returncode == 0:
    try:
        sp = (jout(p).get("data") or {}).get("spreadsheet") or {}
        sheet_tok, sheet_url = sp.get("spreadsheet_token"), sp.get("url")
    except json.JSONDecodeError:
        pass
if sheet_url:
    p = run("sheet", "+info", "--url", sheet_url)
    sheet_name = None
    if p.returncode == 0:
        try:
            s = (jout(p).get("data") or {}).get("sheets")
            # 兼容两种结构：list 直给，或 dict 里嵌 sheets 列表
            cand = s if isinstance(s, list) else (s or {}).get("sheets") or []
            sheet_name = (cand[0] or {}).get("title") if cand else None
        except (json.JSONDecodeError, IndexError, AttributeError, KeyError, TypeError):
            pass
    check("sheet +info 取首个工作表名", bool(sheet_name), p.stdout[:150])
    if sheet_name:
        p = run("sheet", "write", "--url", sheet_url, "--sheet-name", sheet_name,
                "--start-cell", "A1", "--csv", "k1,v1\nfoo,42")
        check("sheet write", p.returncode == 0 and jout(p).get("ok") is True,
              p.stderr.strip()[:150])
        p = run("sheet", "read", "--url", sheet_url, "--sheet-name", sheet_name,
                "--range", "A1:B2")
        check("sheet read 回读", p.returncode == 0 and "foo" in p.stdout
              and "42" in p.stdout)
if sheet_tok:
    p = run2("drive", "rm", sheet_tok, "sheet", "--yes")
    check("sheet 清理删除", p.returncode == 0 and jout(p).get("ok") is True)

# ===== api 逃生舱口 =====
p = run2("api", "GET", "/open-apis/im/v1/chats", "--params", '{"page_size":1}')
check("api GET chats", p.returncode == 0 and jout(p).get("ok") is True)
parity("api GET chats", "api", "GET", "/open-apis/im/v1/chats",
       "--params", '{"page_size":1}')

print(f"\n产物目录：{TMP}")
if n_fail:
    print(f"❌ {n_fail} 个 FAIL")
    sys.exit(1)
print("✅ 全部通过（WARN 为软断言/权限相关，不计失败）")
