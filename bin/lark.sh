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

# 拉一个容器内所有 interactive 卡片的"剥离折叠"正文 map（message_id → 顶层 markdown 拼接）。
# 折叠组件 collapsible_panel 被剥掉 —— 默认视图不给别人（bot/人）看 yomi trace 之类的折叠内容。
# 用法: card_fold_map <chat|thread> <container_id> <page_size> <order>
card_fold_map() {
  local ctype="$1" cid="$2" n="$3" order="$4"
  lark-cli api GET /open-apis/im/v1/messages --as bot \
    --params "$(jq -nc --arg t "$ctype" --arg c "$cid" --arg s "$order" --arg n "$n" \
      '{container_id_type:$t, container_id:$c, sort_type:$s, page_size:$n, card_msg_content_type:"user_card_content"}')" \
    --jq '[ .data.items[] | select(.msg_type=="interactive")
            | { (.message_id): ((.body.content | fromjson? // {}) as $b
                  | ($b.body.elements // $b.elements // [])
                  | map(select(.tag=="markdown") | .content) | join("\n")) } ]
          | add // {}'
}

# 把 lark-cli 消息列表里的 interactive 卡片 content 替换为剥离折叠后的版本。
# 递归处理 thread_replies 嵌套；cardmap 里没有的 id 保持原样。
# 用法: jq 过滤器，$cardmap 经 --argjson 传入。
STRIP_FOLD_JQ='
def rec: if type=="object" then with_entries(.value |= rec) elif type=="array" then map(rec) else . end;
def stripwalk: . as $node
  | if ($node|type)=="object" and ($node.msg_type? == "interactive") and ($cardmap[$node.message_id]? != null)
    then $node + {content: ("<card>\n" + $cardmap[$node.message_id] + "\n</card>")}
    else $node end;
def deep: . as $in
  | if ($in|type)=="object" then
      ($in | stripwalk) | with_entries(.value |= deep)
    elif ($in|type)=="array" then map(deep)
    else $in end;
deep'

usage() {
  cat <<'EOF'
lark — lark-cli 的 bot-only 封装（环境变量内置、--as bot 固化）

IM:
  lark im read <oc_> [-n N] [--asc] [--verbose]  读群消息（默认 desc 最近 20 条；卡片折叠面板默认剥离，--verbose 保留）
  lark im thread <omt_|om_> [-n N] [--verbose]   读话题消息（折叠同 read）
  lark im send <oc_|ou_> <text|@file|->    发消息（oc_=群 ou_=私信；--markdown 切 markdown；--image <路径> 发图）
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

DRIVE:
  lark drive rm <token> <type> [--yes]     删文件（高危门禁，确认后补 --yes）
  lark drive share <token> [args...]       加协作者（透传 +member-add）

BOARD:
  lark board create <doc> [--svg] <代码|@file|->   在文档末尾插入画板（默认 mermaid，--svg 切 SVG）
  lark board export [args...]              导出画板（--whiteboard-token 必填；--output-type preview|svg|source|raw）
  lark board update [args...]              更新画板（--whiteboard-token 必填；--source 支持 @file/-；--input_format raw|plantuml|mermaid|svg）

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
      n=20; order=desc; verbose=0
      while [ $# -gt 0 ]; do case "$1" in
        -n) n="$2"; shift 2 ;;
        --asc) order=asc; shift ;;
        --verbose) verbose=1; shift ;;
        *) break ;;
      esac; done
      if [ "$verbose" = 1 ]; then
        exec lark-cli im +chat-messages-list --chat-id "$chat" --order "$order" \
          --page-size "$n" --no-reactions --format json --as bot "$@"
      fi
      cardmap="$(card_fold_map chat "$chat" "$n" "$( [ "$order" = asc ] && echo ByCreateTimeAsc || echo ByCreateTimeDesc )")"
      lark-cli im +chat-messages-list --chat-id "$chat" --order "$order" \
        --page-size "$n" --no-reactions --format json --as bot "$@" \
        | jq --argjson cardmap "$cardmap" "$STRIP_FOLD_JQ"
      ;;
    thread)
      tid="$(need "${1:-}" thread_id)"; shift
      n=20; verbose=0
      while [ $# -gt 0 ]; do case "$1" in
        -n) n="$2"; shift 2 ;;
        --verbose) verbose=1; shift ;;
        *) break ;;
      esac; done
      if [ "$verbose" = 1 ]; then
        exec lark-cli im +threads-messages-list --thread "$tid" --order desc \
          --page-size "$n" --format json --as bot "$@"
      fi
      # card_fold_map 的 thread 容器要 omt_；传 om_（root 消息）时先解析出 thread_id。
      cid="$tid"
      case "$tid" in
        om_*)
          cid="$(lark-cli api GET "/open-apis/im/v1/messages/$tid" --as bot \
            --jq '.data.items[0].thread_id // empty' | tr -d '"')"
          [ -n "$cid" ] || die "im thread: $tid 不在话题内，无法取 thread_id"
          ;;
      esac
      cardmap="$(card_fold_map thread "$cid" "$n" ByCreateTimeDesc)"
      lark-cli im +threads-messages-list --thread "$tid" --order desc \
        --page-size "$n" --format json --as bot "$@" \
        | jq --argjson cardmap "$cardmap" "$STRIP_FOLD_JQ"
      ;;
    send)
      target="$(need "${1:-}" 'oc_|ou_')"; shift
      msgtype=text
      if [ "${1:-}" = "--markdown" ]; then msgtype=markdown; shift; fi
      if [ "${1:-}" = "--image" ]; then msgtype=image; shift; fi
      if [ "$msgtype" = image ]; then
        # 图片是路径/URL/img_key，直接透传（lark-cli 自行上传），不当文本读。
        body="$(need "${1:-}" '图片路径/URL/img_key')"; shift || true
      else
        [ $# -ge 1 ] || die "im send: 缺正文（文本、@file 或 -）"
        body="$(load_text "$1")"; shift || true
      fi
      case "$target" in
        oc_*) exec lark-cli im +messages-send --chat-id "$target" --"$msgtype" "$body" --as bot "$@" ;;
        ou_*) exec lark-cli im +messages-send --user-id "$target" --"$msgtype" "$body" --as bot "$@" ;;
        *) die "im send: target 必须是 oc_（群）或 ou_（私信）：$target" ;;
      esac
      ;;
    reply)
      mid="$(need "${1:-}" om_)"; shift
      extra=(); msgtype=text
      while [ $# -gt 0 ]; do case "$1" in
        --thread) extra+=(--reply-in-thread); shift ;;
        --markdown) msgtype=markdown; shift ;;
        *) break ;;
      esac; done
      [ $# -ge 1 ] || die "im reply: 缺正文（文本、@file 或 -）"
      body="$(load_text "$1")"; shift || true
      exec lark-cli im +messages-reply --message-id "$mid" --"$msgtype" "$body" --as bot "${extra[@]}" "$@"
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
      # lark-cli 单资源下载（--file-key 必填、--output 为文件路径）：
      # wrapper 在此之上补"全消息枚举附件 + 指定目录"。
      mid="$(need "${1:-}" om_)"; shift
      outdir="."
      if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then outdir="$1"; shift; fi
      case "$outdir" in
        /*|*..*) die "im dl: 目录只接受 cwd 内相对路径" ;;
      esac
      mkdir -p "$outdir"
      fkey="" rtype=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --file-key) fkey="$(need "${2:-}" file_key)"; shift 2 ;;
          --type) rtype="$(need "${2:-}" type)"; shift 2 ;;
          *) die "im dl: 未知参数 $1" ;;
        esac
      done
      if [ -n "$fkey" ]; then
        [ -z "$rtype" ] && case "$fkey" in img_*) rtype=image ;; *) rtype=file ;; esac
        exec lark-cli im +messages-resources-download --message-id "$mid" \
          --file-key "$fkey" --type "$rtype" --output "$outdir/$fkey" --as bot
      fi
      # 全量：读消息体枚举 image_key/file_key（post/img/file 消息通吃）
      body="$(lark-cli api GET "/open-apis/im/v1/messages/$mid" --as bot \
        --jq '.data.items[0].body.content' | jq -r .)" || die "im dl: 读消息失败 $mid"
      keys="$(printf '%s' "$body" | jq -r \
        '.. | objects | (.image_key? // empty), (.file_key? // empty)' | sort -u)"
      [ -z "$keys" ] && die "im dl: 消息无附件 $mid"
      rc=0
      for k in $keys; do
        case "$k" in img_*) t=image ;; *) t=file ;; esac
        lark-cli im +messages-resources-download --message-id "$mid" \
          --file-key "$k" --type "$t" --output "$outdir/$k" --as bot || rc=1
      done
      exit $rc
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
      rc=0; out="$(lark-cli docs +create --content "$body" --as bot "$@")" || rc=$?
      printf '%s\n' "$out"
      [ "$rc" -ne 0 ] && exit "$rc"
      # 建完自动订阅（评论/更新通知回流 bot）；订阅失败不拖垮建单
      tok="$(printf '%s' "$out" | jq -r '.data.document_id // .data.document.document_id // empty')"
      if [ -n "$tok" ]; then
        lark-cli api POST "/open-apis/drive/v1/files/$tok/subscribe" \
          --params '{"file_type":"docx"}' --as bot >/dev/null 2>&1 \
          && echo "lark: 已自动订阅 $tok" >&2 \
          || echo "lark: 警告：自动订阅失败（文档已建好）$tok" >&2
      fi
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
      rc=0; out="$(lark-cli sheets spreadsheets create \
        --data "$(jq -nc --arg t "$title" '{title:$t}')" --as bot "$@")" || rc=$?
      printf '%s\n' "$out"
      [ "$rc" -ne 0 ] && exit "$rc"
      # 建完自动订阅（同 doc create）
      tok="$(printf '%s' "$out" | jq -r '.data.spreadsheet.spreadsheet_token // empty')"
      if [ -n "$tok" ]; then
        lark-cli api POST "/open-apis/drive/v1/files/$tok/subscribe" \
          --params '{"file_type":"sheet"}' --as bot >/dev/null 2>&1 \
          && echo "lark: 已自动订阅 $tok" >&2 \
          || echo "lark: 警告：自动订阅失败（表格已建好）$tok" >&2
      fi
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

board)
  sub="$(need "${1:-}" 'create|export|update')"; shift
  case "$sub" in
    create)
      doc="$(need "${1:-}" doc)"; shift
      fmt=mermaid
      if [ "${1:-}" = "--svg" ]; then fmt=svg; shift; fi
      [ $# -ge 1 ] || die "board create: 缺内容（mermaid/svg 代码、@file 或 -）"
      code="$(load_text "$1")"; shift || true
      body="$(printf '<whiteboard type="%s">\n%s\n</whiteboard>' "$fmt" "$code")"
      exec lark-cli docs +update --doc "$doc" --command append --content "$body" --as bot "$@"
      ;;
    export|update)
      exec lark-cli whiteboard "+$sub" --as bot "$@"
      ;;
    *) die "board: 未知子命令 $sub（create/export/update）" ;;
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
  die "未知分类：${category}（im/doc/sheet/contact/cal/drive/board/api，-h 看帮助）"
  ;;
esac
