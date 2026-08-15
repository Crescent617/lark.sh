#!/usr/bin/env bash
# lark.sh — lark-cli 的 bot-only 封装。
#
# 设计目标：
#   - 内置 LARKSUITE_CLI_NO_UPDATE_NOTIFIER 等环境变量，调用方零配置
#   - 全部命令写死 --as bot（user-only 操作请回退原生 lark-cli）
#   - 按场景分类的短命令，常用路径一行搞定
#
# 建议 symlink 到 PATH 后使用（如 ln -s <repo>/bin/lark.sh /usr/local/bin/lark），
# 之后一律以 `lark` 调用，不要在命令里写长路径。
#
# 用法：lark <category> <cmd> [args...]   详见各分支的 usage 或 skills/lark/SKILL.md

set -euo pipefail

export LARKSUITE_CLI_NO_UPDATE_NOTIFIER=1 LARKSUITE_CLI_NO_SKILLS_NOTIFIER=1

PROG="${0##*/}"
die() { echo "$PROG: $*" >&2; exit 2; }
need() { [ -n "${1:-}" ] || die "missing arg: $2"; printf '%s' "$1"; }

# 文本载荷归一化：'-' = stdin；'@path' = 读文件内容；其余原样。
load_text() {
  case "${1:-}" in
    -) cat ;;
    @*) cat -- "${1#@}" ;;
    *) printf '%s' "$1" ;;
  esac
}

usage() {
  cat <<'EOF'
lark — lark-cli 的 bot-only 封装（环境变量内置、--as bot 固化）

IM:
  lark im read <oc_> [-n N] [--asc]        读群消息（默认 desc 最近 20 条）
  lark im thread <omt_|om_> [-n N]         读话题消息
  lark im send <oc_|ou_> <text|@file|->    发消息（oc_=群 ou_=私信；--markdown 切 markdown）
  lark im reply <om_> <text|@file|->       回复消息（--thread 进话题）
  lark im sticker <om_|oc_> <file_key>     发表情（om_=回复该消息进话题，oc_=直发群；--main 回复不进话题）
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
  lark sheet +<shortcut> [args...]         透传 lark-cli sheets（自动 --as bot），速查见 references/sheets.md

CONTACT/CAL:
  lark contact get <ou_>                   open_id 查人
  lark cal freebusy <ou_> <start> <end>    查忙闲（RFC3339）

DRIVE/WIKI/BASE:
  lark drive rm <token> <type> [--yes]     删文件（高危门禁，确认后补 --yes）
  lark drive share <token> [args...]       加协作者（透传 +member-add）
  lark wiki nodes <space_id> [parent]      列知识库节点
  lark wiki new <space_id> <parent> <title>  新建 docx 节点
  lark base tables <base_token>            列出数据表
  lark base query <base_token> <table_id> [keyword]  查记录（其余参数透传）

逃生舱口:
  lark api <METHOD> <path> [args...]       透传 lark-cli api（自动 --as bot），如 --params/--data/--jq

约定：只支持 bot 身份；消息全文搜索、个人日历/云盘等 user-only 操作用原生 lark-cli --as user。
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }
category="$1"; shift

case "$category" in
im)
  [ $# -ge 1 ] || die "im: 缺子命令（read/thread/send/reply/sticker/dl/mget/chats/find/members/desc）"
  sub="$1"; shift
  case "$sub" in
    read)
      chat="$(need "${1:-}" oc_)"; shift
      n=20; order=desc
      while [ $# -gt 0 ]; do case "$1" in
        -n) n="$2"; shift 2 ;;
        --asc) order=asc; shift ;;
        *) break ;;
      esac; done
      exec lark-cli im +chat-messages-list --chat-id "$chat" --order "$order" \
        --page-size "$n" --no-reactions --format json --as bot "$@"
      ;;
    thread)
      tid="$(need "${1:-}" thread_id)"; shift
      n=20
      while [ $# -gt 0 ]; do case "$1" in
        -n) n="$2"; shift 2 ;;
        *) break ;;
      esac; done
      exec lark-cli im +threads-messages-list --thread "$tid" --order desc \
        --page-size "$n" --format json --as bot "$@"
      ;;
    send)
      target="$(need "${1:-}" 'oc_|ou_')"; shift
      msgtype=text
      if [ "${1:-}" = "--markdown" ]; then msgtype=markdown; shift; fi
      [ $# -ge 1 ] || die "im send: 缺正文（文本、@file 或 -）"
      body="$(load_text "$1")"; shift || true
      case "$target" in
        oc_*) exec lark-cli im +messages-send --chat-id "$target" --"$msgtype" "$body" --as bot "$@" ;;
        ou_*) exec lark-cli im +messages-send --user-id "$target" --"$msgtype" "$body" --as bot "$@" ;;
        *) die "im send: target 必须是 oc_（群）或 ou_（私信）：$target" ;;
      esac
      ;;
    reply)
      mid="$(need "${1:-}" om_)"; shift
      extra=()
      if [ "${1:-}" = "--thread" ]; then extra=(--reply-in-thread); shift; fi
      [ $# -ge 1 ] || die "im reply: 缺正文（文本、@file 或 -）"
      body="$(load_text "$1")"; shift || true
      exec lark-cli im +messages-reply --message-id "$mid" --text "$body" --as bot "${extra[@]}" "$@"
      ;;
    sticker)
      target="$(need "${1:-}" 'om_|oc_')"; key="$(need "${2:-}" file_key)"; shift 2
      content="$(jq -nc --arg k "$key" '{file_key:$k}')"
      case "$target" in
        om_*)
          in_thread=true
          if [ "${1:-}" = "--main" ]; then in_thread=false; shift; fi
          data="$(jq -nc --arg c "$content" --argjson t "$in_thread" \
            '{content:$c,msg_type:"sticker",reply_in_thread:$t}')"
          exec lark-cli api POST "/open-apis/im/v1/messages/$target/reply" --data "$data" --as bot "$@"
          ;;
        oc_*)
          data="$(jq -nc --arg c "$content" --arg r "$target" \
            '{receive_id:$r,content:$c,msg_type:"sticker"}')"
          exec lark-cli api POST /open-apis/im/v1/messages \
            --params '{"receive_id_type":"chat_id"}' --data "$data" --as bot "$@"
          ;;
        *) die "im sticker: target 必须是 om_（回复）或 oc_（群发）：$target" ;;
      esac
      ;;
    dl)
      mid="$(need "${1:-}" om_)"; shift
      outdir="."
      if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then outdir="$1"; shift; fi
      exec lark-cli im +messages-resources-download --message-id "$mid" \
        --output-dir "$outdir" --as bot "$@"
      ;;
    mget)
      ids="$(need "${1:-}" om_ids)"; shift
      exec lark-cli im +messages-mget --message-ids "$ids" --as bot "$@"
      ;;
    chats)
      exec lark-cli im +chat-list --as bot --page-all "$@"
      ;;
    find)
      q="$(need "${1:-}" query)"; shift
      exec lark-cli im +chat-search --query "$q" --as bot "$@"
      ;;
    members)
      chat="$(need "${1:-}" oc_)"; shift
      exec lark-cli im +chat-members-list --chat-id "$chat" --as bot --page-all "$@"
      ;;
    desc)
      chat="$(need "${1:-}" oc_)"; text="$(need "${2:-}" description)"; shift 2
      exec lark-cli im +chat-update --chat-id "$chat" --description "$text" --as bot "$@"
      ;;
    *) die "im: 未知子命令 $sub" ;;
  esac
  ;;

doc)
  [ $# -ge 1 ] || die "doc: 缺子命令（read/create/append/replace）"
  sub="$1"; shift
  case "$sub" in
    read)
      doc="$(need "${1:-}" 'url|token')"; shift
      extra=()
      if [ "${1:-}" = "-k" ]; then extra=(--scope keyword --keyword "$2"); shift 2; fi
      exec lark-cli docs +fetch --doc "$doc" --as bot "${extra[@]}" "$@"
      ;;
    create)
      [ $# -ge 1 ] || die "doc create: 缺内容（html、@file 或 -）"
      body="$(load_text "$1")"; shift || true
      exec lark-cli docs +create --content "$body" --as bot "$@"
      ;;
    append)
      doc="$(need "${1:-}" doc)"; shift
      [ $# -ge 1 ] || die "doc append: 缺内容（html、@file 或 -）"
      body="$(load_text "$1")"; shift || true
      exec lark-cli docs +update --doc "$doc" --command append --content "$body" --as bot "$@"
      ;;
    replace)
      doc="$(need "${1:-}" doc)"; block="$(need "${2:-}" block_id)"; shift 2
      [ $# -ge 1 ] || die "doc replace: 缺内容（html、@file 或 -）"
      body="$(load_text "$1")"; shift || true
      exec lark-cli docs +update --doc "$doc" --command block_replace \
        --block-id "$block" --content "$body" --as bot "$@"
      ;;
    *) die "doc: 未知子命令 $sub" ;;
  esac
  ;;

sheet)
  [ $# -ge 1 ] || die "sheet: 缺子命令（create/read/write/+shortcut 透传）"
  sub="$1"; shift
  case "$sub" in
    create)
      title="$(need "${1:-}" title)"; shift
      exec lark-cli sheets spreadsheets create \
        --data "$(jq -nc --arg t "$title" '{title:$t}')" --as bot "$@"
      ;;
    read)
      exec lark-cli sheets +csv-get --as bot "$@"
      ;;
    write)
      exec lark-cli sheets +csv-put --as bot "$@"
      ;;
    +*)
      exec lark-cli sheets "$sub" --as bot "$@"
      ;;
    *) die "sheet: 未知子命令 ${sub}（create/read/write/+shortcut）" ;;
  esac
  ;;

contact)
  [ "${1:-}" = "get" ] || die "contact: 仅支持 get <ou_>"
  uid="$(need "${2:-}" ou_)"; shift 2
  exec lark-cli contact +get-user --user-id "$uid" --as bot "$@"
  ;;

cal)
  [ "${1:-}" = "freebusy" ] || die "cal: 仅支持 freebusy <ou_> <start> <end>"
  uid="$(need "${2:-}" ou_)"; start="$(need "${3:-}" start)"; end="$(need "${4:-}" end)"; shift 4
  exec lark-cli calendar +freebusy --user-id "$uid" --start "$start" --end "$end" --as bot "$@"
  ;;

drive)
  [ $# -ge 1 ] || die "drive: 缺子命令（rm/share）"
  sub="$1"; shift
  case "$sub" in
    rm)
      token="$(need "${1:-}" file_token)"; type="$(need "${2:-}" type)"; shift 2
      exec lark-cli drive +delete --file-token "$token" --type "$type" --as bot "$@"
      ;;
    share)
      token="$(need "${1:-}" token)"; shift
      exec lark-cli drive +member-add --token "$token" --as bot "$@"
      ;;
    *) die "drive: 未知子命令 $sub" ;;
  esac
  ;;

wiki)
  [ $# -ge 1 ] || die "wiki: 缺子命令（nodes/new）"
  sub="$1"; shift
  case "$sub" in
    nodes)
      space="$(need "${1:-}" space_id)"; shift
      extra=()
      if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then extra=(--parent-node-token "$1"); shift; fi
      exec lark-cli wiki +node-list --space-id "$space" --as bot "${extra[@]}" "$@"
      ;;
    new)
      space="$(need "${1:-}" space_id)"; parent="$(need "${2:-}" parent_node_token)"; title="$(need "${3:-}" title)"; shift 3
      exec lark-cli wiki +node-create --space-id "$space" --parent-node-token "$parent" \
        --obj-type docx --title "$title" --as bot "$@"
      ;;
    *) die "wiki: 未知子命令 $sub" ;;
  esac
  ;;

base)
  [ $# -ge 1 ] || die "base: 缺子命令（tables/query）"
  sub="$1"; shift
  case "$sub" in
    tables)
      tok="$(need "${1:-}" base_token)"; shift
      exec lark-cli base +table-list --base-token "$tok" --as bot "$@"
      ;;
    query)
      tok="$(need "${1:-}" base_token)"; table="$(need "${2:-}" table_id)"; shift 2
      extra=()
      if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then extra=(--keyword "$1"); shift; fi
      exec lark-cli base +record-search --base-token "$tok" --table-id "$table" --as bot "${extra[@]}" "$@"
      ;;
    *) die "base: 未知子命令 $sub" ;;
  esac
  ;;

api)
  method="$(need "${1:-}" METHOD)"; path="$(need "${2:-}" path)"; shift 2
  exec lark-cli api "$method" "$path" --as bot "$@"
  ;;

-h|--help|help)
  usage
  ;;

*)
  die "未知分类：${category}（im/doc/sheet/contact/cal/drive/wiki/base/api，-h 看帮助）"
  ;;
esac
