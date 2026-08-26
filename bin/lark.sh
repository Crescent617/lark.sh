#!/usr/bin/env bash
# lark.sh — lark-cli 的轻封装（默认 bot 身份）。
#
# 设计目标：
#   - 内置 LARKSUITE_CLI_NO_UPDATE_NOTIFIER 等环境变量，调用方零配置
#   - 默认 --as "$AS"；首位 -u 全局切 --as user（如 lark -u im read ...）
#   - 按场景分类的短命令，常用路径一行搞定
#
# 建议 symlink 到 PATH 后使用（如 ln -s <repo>/bin/lark.sh /usr/local/bin/lark），
# 之后一律以 `lark` 调用，不要在命令里写长路径。
#
# 用法：lark [-u] <category> <cmd> [args...]   详见各分支的 usage 或 skills/lark/SKILL.md

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

# 拉一个容器内所有 interactive 卡片的"剥离折叠"正文 map（message_id → header 标题 + 顶层 markdown 拼接）。
# 折叠组件 collapsible_panel 被剥掉 —— 默认视图不给别人（bot/人）看 yomi trace 之类的折叠内容；
# header 标题保留：yomi 状态卡的 live 内容全在面板里，标题（🐾 Typing… 等阶段行）是唯一的暂态信号。
# 用法: card_fold_map <chat|thread> <container_id> <page_size> <order>
card_fold_map() {
  local ctype="$1" cid="$2" n="$3" order="$4"
  [ "$n" -gt 50 ] && n=50 # 消息列表 API page_size 上限 50，超了报 99992402
  lark-cli api GET /open-apis/im/v1/messages --as "$AS" \
    --params "$(jq -nc --arg t "$ctype" --arg c "$cid" --arg s "$order" --arg n "$n" \
      '{container_id_type:$t, container_id:$c, sort_type:$s, page_size:$n, card_msg_content_type:"user_card_content"}')" \
    --jq '[ .data.items[] | select(.msg_type=="interactive")
            | { (.message_id): ((.body.content | fromjson? // {}) as $b
                  | ([ ($b.header.title.content // empty) ]
                     + (($b.body.elements // $b.elements // [])
                        | map(select(.tag=="markdown") | .content)))
                  | join("\n")) } ]
          | add // {}' || echo '{}' # 卡片剥离失败不拖垮主列表（退化保留原卡片）
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

# ===== sticker 收藏夹（全局存储 + 按 appId 分目录；file_key 全程不出脚本）=====
# 为什么不让 key 过调用方的手：LLM "复制"长随机串是逐 token 默写，
# 极易拼接出缝合 key（2026-08-25 猫鼠 key 拼接事故）。调用方只递 关键词/行号/om_。
# 存储：<LARK_STICKER_DIR|XDG_DATA_HOME|~/.local/share>/lark/stickers/<appId>/{stickers.md, stickers/}

sticker_dir() {  # 输出当前 bot 的收藏目录（不存在则初始化目录 + 空索引模板）
  local appid dir
  appid="$(lark-cli config show 2>/dev/null | jq -r '.appId // empty')"
  [ -n "$appid" ] || die "sticker: 解析 appId 失败（lark-cli config show）"
  dir="${LARK_STICKER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/lark/stickers}/$appid"
  if [ ! -f "$dir/stickers.md" ]; then
    mkdir -p "$dir/stickers"
    printf '# Sticker 收藏夹索引\n\n| file_key | 内容 | 适用场景 |\n|---|---|---|\n' > "$dir/stickers.md"
  fi
  printf '%s' "$dir"
}

st_key_of() { cut -d'`' -f2 <<<"${1:-$(cat)}"; }  # 数据行 → key（仅内部使用，绝不打印）
st_desc_of() {                                    # 数据行 → '描述 — 场景'（剥 key，安全输出）
  awk -F'|' '{gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); printf "%s — %s", $3, $4}' <<<"${1:-$(cat)}"
}

# st_pick <idx> <关键词|行号>：选唯一数据行；无匹配 die；多匹配候选（含行号，不含 key）打 stderr，exit 3
st_pick() {
  local idx="$1" sel="$2"
  if [[ "$sel" =~ ^[0-9]+$ ]]; then
    local line; line="$(sed -n "${sel}p" "$idx")"
    [[ "$line" == '| `'* ]] || die "sticker: 第 $sel 行不是数据行（用 sticker list 看行号）"
    printf '%s\n' "$line"; return 0
  fi
  local hits n
  hits="$(grep -n '^| `' "$idx" | grep -iF -- "$sel" || true)"
  n="$(grep -c . <<<"$hits" || true)"
  [ "$n" -ge 1 ] || die "sticker: 索引没匹配到「$sel」（sticker list 看看有啥）"
  if [ "$n" -gt 1 ]; then
    echo "$PROG: sticker: 「$sel」匹配 $n 条，换更准的关键词或直接给行号：" >&2
    printf '%s\n' "$hits" | while IFS= read -r l; do
      echo "  L${l%%:*}  $(st_desc_of "${l#*:}")" >&2
    done
    exit 3
  fi
  printf '%s\n' "${hits#*:}"
}

# 底层 sticker 发送：om_=回复该消息（默认回主流，--thread 进话题），oc_=直发群。
st_post() {
  local target="$1" key="$2"; shift 2
  local content data
  content="$(jq -nc --arg k "$key" '{file_key:$k}')"
  case "$target" in
    om_*)
      local in_thread=false
      if [ "${1:-}" = "--thread" ]; then in_thread=true; shift; fi
      data="$(jq -nc --arg c "$content" --argjson t "$in_thread" \
        '{content:$c,msg_type:"sticker",reply_in_thread:$t}')"
      lark-cli api POST "/open-apis/im/v1/messages/$target/reply" --data "$data" --as "$AS" "$@"
      ;;
    oc_*)
      data="$(jq -nc --arg c "$content" --arg r "$target" \
        '{receive_id:$r,content:$c,msg_type:"sticker"}')"
      lark-cli api POST /open-apis/im/v1/messages \
        --params '{"receive_id_type":"chat_id"}' --data "$data" --as "$AS" "$@"
      ;;
    *) die "sticker: target 必须是 om_（回复）或 oc_（群发）：$target" ;;
  esac
}

usage() {
  cat <<'EOF'
lark — lark-cli 的轻封装（环境变量内置；默认 bot 身份，首位 -u 切 user：lark -u im read ...）

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
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }
AS=bot
[ "$1" = "-u" ] && { AS=user; shift; } # 首位 -u：整条命令以 user 身份执行
[ $# -ge 1 ] || { usage; exit 2; }
category="$1"; shift

case "$category" in
im)
  [ $# -ge 1 ] || die "im: 缺子命令（read/thread/send/reply/sticker/dl/mget/chats/find/members/desc）"
  sub="$1"; shift
  case "$sub" in
    read)
      chat="$(need "${1:-}" oc_)"; shift
      n=20; order=desc; verbose=0; extra=()
      # wrapper 自有 flag（-n/--asc/--verbose）任意位置都能出现；其余（--start/--end/--page-token/--page-all 等）原样透传
      while [ $# -gt 0 ]; do case "$1" in
        -n) n="$2"; shift 2 ;;
        --asc) order=asc; shift ;;
        --verbose) verbose=1; shift ;;
        *) extra+=("$1"); shift ;;
      esac; done
      [ "$n" -gt 50 ] && n=50 # API page_size 上限 50；更多用 --page-token 翻页或 --page-all
      if [ "$verbose" = 1 ]; then
        exec lark-cli im +chat-messages-list --chat-id "$chat" --order "$order" \
          --page-size "$n" --no-reactions --format json --as "$AS" "${extra[@]}"
      fi
      cardmap="$(card_fold_map chat "$chat" "$n" "$( [ "$order" = asc ] && echo ByCreateTimeAsc || echo ByCreateTimeDesc )")"
      lark-cli im +chat-messages-list --chat-id "$chat" --order "$order" \
        --page-size "$n" --no-reactions --format json --as "$AS" "${extra[@]}" \
        | jq --argjson cardmap "$cardmap" "$STRIP_FOLD_JQ"
      ;;
    thread)
      tid="$(need "${1:-}" thread_id)"; shift
      n=20; verbose=0; extra=()
      while [ $# -gt 0 ]; do case "$1" in
        -n) n="$2"; shift 2 ;;
        --verbose) verbose=1; shift ;;
        *) extra+=("$1"); shift ;;
      esac; done
      [ "$n" -gt 50 ] && n=50 # API page_size 上限 50；更多用 --page-token 翻页
      if [ "$verbose" = 1 ]; then
        exec lark-cli im +threads-messages-list --thread "$tid" --order desc \
          --page-size "$n" --format json --as "$AS" "${extra[@]}"
      fi
      # card_fold_map 的 thread 容器要 omt_；传 om_（root 消息）时先解析出 thread_id。
      cid="$tid"
      case "$tid" in
        om_*)
          cid="$(lark-cli api GET "/open-apis/im/v1/messages/$tid" --as "$AS" \
            --jq '.data.items[0].thread_id // empty' | tr -d '"')"
          [ -n "$cid" ] || die "im thread: $tid 不在话题内，无法取 thread_id"
          ;;
      esac
      cardmap="$(card_fold_map thread "$cid" "$n" ByCreateTimeDesc)"
      lark-cli im +threads-messages-list --thread "$tid" --order desc \
        --page-size "$n" --format json --as "$AS" "${extra[@]}" \
        | jq --argjson cardmap "$cardmap" "$STRIP_FOLD_JQ"
      ;;
    send)
      target="$(need "${1:-}" 'oc_|ou_')"; shift
      msgtype=text
      case "${1:-}" in
        --markdown) msgtype=markdown; shift ;;
        --image|--file|--video|--audio) msgtype="${1#--}"; shift ;;
      esac
      case "$msgtype" in
        image|file|video|audio)
          # 媒体/文件是路径/URL/key，直接透传（lark-cli 自行上传），不当文本读。
          body="$(need "${1:-}" "$msgtype 路径/URL/key")"; shift || true
          ;;
        *)
          [ $# -ge 1 ] || die "im send: 缺正文（文本、@file 或 -）"
          body="$(load_text "$1")"; shift || true
          ;;
      esac
      case "$target" in
        oc_*) exec lark-cli im +messages-send --chat-id "$target" --"$msgtype" "$body" --as "$AS" "$@" ;;
        ou_*) exec lark-cli im +messages-send --user-id "$target" --"$msgtype" "$body" --as "$AS" "$@" ;;
        *) die "im send: target 必须是 oc_（群）或 ou_（私信）：$target" ;;
      esac
      ;;
    reply)
      mid="$(need "${1:-}" om_)"; shift
      extra=(); msgtype=text
      while [ $# -gt 0 ]; do case "$1" in
        --thread) extra+=(--reply-in-thread); shift ;;
        --markdown) msgtype=markdown; shift ;;
        --image|--file|--video|--audio) msgtype="${1#--}"; shift ;;
        *) break ;;
      esac; done
      case "$msgtype" in
        image|file|video|audio)
          body="$(need "${1:-}" "$msgtype 路径/URL/key")"; shift || true ;;
        *)
          [ $# -ge 1 ] || die "im reply: 缺正文（文本、@file 或 -）"
          body="$(load_text "$1")"; shift || true ;;
      esac
      exec lark-cli im +messages-reply --message-id "$mid" --"$msgtype" "$body" --as "$AS" "${extra[@]}" "$@"
      ;;
    sticker)
      target="$(need "${1:-}" 'om_|oc_')"; key="$(need "${2:-}" file_key)"; shift 2
      st_post "$target" "$key" "$@"
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
          --file-key "$fkey" --type "$rtype" --output "$outdir/$fkey" --as "$AS"
      fi
      # 全量：读消息体枚举 image_key/file_key（post/img/file 消息通吃）
      body="$(lark-cli api GET "/open-apis/im/v1/messages/$mid" --as "$AS" \
        --jq '.data.items[0].body.content' | jq -r .)" || die "im dl: 读消息失败 $mid"
      keys="$(printf '%s' "$body" | jq -r \
        '.. | objects | (.image_key? // empty), (.file_key? // empty)' | sort -u)"
      [ -z "$keys" ] && die "im dl: 消息无附件 $mid"
      rc=0
      for k in $keys; do
        case "$k" in img_*) t=image ;; *) t=file ;; esac
        lark-cli im +messages-resources-download --message-id "$mid" \
          --file-key "$k" --type "$t" --output "$outdir/$k" --as "$AS" || rc=1
      done
      exit $rc
      ;;
    mget)
      ids="$(need "${1:-}" om_ids)"; shift
      exec lark-cli im +messages-mget --message-ids "$ids" --as "$AS" "$@"
      ;;
    chats)
      exec lark-cli im +chat-list --as "$AS" --page-all "$@"
      ;;
    find)
      q="$(need "${1:-}" query)"; shift
      exec lark-cli im +chat-search --query "$q" --as "$AS" "$@"
      ;;
    members)
      chat="$(need "${1:-}" oc_)"; shift
      exec lark-cli im +chat-members-list --chat-id "$chat" --as "$AS" --page-all "$@"
      ;;
    desc)
      chat="$(need "${1:-}" oc_)"; text="$(need "${2:-}" description)"; shift 2
      exec lark-cli im +chat-update --chat-id "$chat" --description "$text" --as "$AS" "$@"
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
      exec lark-cli docs +fetch --doc "$doc" --as "$AS" "${extra[@]}" "$@"
      ;;
    create)
      [ $# -ge 1 ] || die "doc create: 缺内容（html、@file 或 -）"
      body="$(load_text "$1")"; shift || true
      rc=0; out="$(lark-cli docs +create --content "$body" --as "$AS" "$@")" || rc=$?
      printf '%s\n' "$out"
      [ "$rc" -ne 0 ] && exit "$rc"
      # 建完自动订阅（评论/更新通知回流 bot）；订阅失败不拖垮建单
      tok="$(printf '%s' "$out" | jq -r '.data.document_id // .data.document.document_id // empty')"
      if [ -n "$tok" ]; then
        lark-cli api POST "/open-apis/drive/v1/files/$tok/subscribe" \
          --params '{"file_type":"docx"}' --as "$AS" >/dev/null 2>&1 \
          && echo "lark: 已自动订阅 $tok" >&2 \
          || echo "lark: 警告：自动订阅失败（文档已建好）$tok" >&2
      fi
      ;;
    append)
      doc="$(need "${1:-}" doc)"; shift
      [ $# -ge 1 ] || die "doc append: 缺内容（html、@file 或 -）"
      body="$(load_text "$1")"; shift || true
      exec lark-cli docs +update --doc "$doc" --command append --content "$body" --as "$AS" "$@"
      ;;
    replace)
      doc="$(need "${1:-}" doc)"; block="$(need "${2:-}" block_id)"; shift 2
      [ $# -ge 1 ] || die "doc replace: 缺内容（html、@file 或 -）"
      body="$(load_text "$1")"; shift || true
      exec lark-cli docs +update --doc "$doc" --command block_replace \
        --block-id "$block" --content "$body" --as "$AS" "$@"
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
        --data "$(jq -nc --arg t "$title" '{title:$t}')" --as "$AS" "$@")" || rc=$?
      printf '%s\n' "$out"
      [ "$rc" -ne 0 ] && exit "$rc"
      # 建完自动订阅（同 doc create）
      tok="$(printf '%s' "$out" | jq -r '.data.spreadsheet.spreadsheet_token // empty')"
      if [ -n "$tok" ]; then
        lark-cli api POST "/open-apis/drive/v1/files/$tok/subscribe" \
          --params '{"file_type":"sheet"}' --as "$AS" >/dev/null 2>&1 \
          && echo "lark: 已自动订阅 $tok" >&2 \
          || echo "lark: 警告：自动订阅失败（表格已建好）$tok" >&2
      fi
      ;;
    read)
      exec lark-cli sheets +csv-get --as "$AS" "$@"
      ;;
    write)
      exec lark-cli sheets +csv-put --as "$AS" "$@"
      ;;
    +*)
      exec lark-cli sheets "$sub" --as "$AS" "$@"
      ;;
    *) die "sheet: 未知子命令 ${sub}（create/read/write/+shortcut）" ;;
  esac
  ;;

contact)
  [ "${1:-}" = "get" ] || die "contact: 仅支持 get <ou_>"
  uid="$(need "${2:-}" ou_)"; shift 2
  exec lark-cli contact +get-user --user-id "$uid" --as "$AS" "$@"
  ;;

cal)
  [ "${1:-}" = "freebusy" ] || die "cal: 仅支持 freebusy <ou_> <start> <end>"
  uid="$(need "${2:-}" ou_)"; start="$(need "${3:-}" start)"; end="$(need "${4:-}" end)"; shift 4
  exec lark-cli calendar +freebusy --user-id "$uid" --start "$start" --end "$end" --as "$AS" "$@"
  ;;

drive)
  [ $# -ge 1 ] || die "drive: 缺子命令（rm/share）"
  sub="$1"; shift
  case "$sub" in
    rm)
      token="$(need "${1:-}" file_token)"; type="$(need "${2:-}" type)"; shift 2
      exec lark-cli drive +delete --file-token "$token" --type "$type" --as "$AS" "$@"
      ;;
    share)
      token="$(need "${1:-}" token)"; shift
      exec lark-cli drive +member-add --token "$token" --as "$AS" "$@"
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
      exec lark-cli docs +update --doc "$doc" --command append --content "$body" --as "$AS" "$@"
      ;;
    export|update)
      exec lark-cli whiteboard "+$sub" --as "$AS" "$@"
      ;;
    *) die "board: 未知子命令 $sub（create/export/update）" ;;
  esac
  ;;

sticker)
  # 收藏夹 CRUD + 关键词发送：file_key 只在脚本内部流转，不向 stdout 暴露。
  [ $# -ge 1 ] || die "sticker: 缺子命令（send/list/add/rm）"
  sub="$1"; shift
  dir="$(sticker_dir)"; idx="$dir/stickers.md"
  case "$sub" in
    send)
      target="$(need "${1:-}" 'oc_|om_')"; sel="$(need "${2:-}" '关键词|行号')"; shift 2
      row="$(st_pick "$idx" "$sel")"
      key="$(st_key_of "$row")"
      [ -n "$key" ] || die "sticker send: 数据行解析不出 file_key（索引格式坏了？）"
      out="$(st_post "$target" "$key" "$@")"
      # 结果剥掉 body（含 file_key）再输出
      printf '%s\n' "$out" | jq --arg sent "$(st_desc_of "$row")" \
        '{ok, identity, message_id: .data.message_id, sent: $sent, error}'
      ;;
    list)
      hits="$(grep -n '^| `' "$idx" || true)"
      [ $# -ge 1 ] && hits="$(grep -iF -- "$1" <<<"$hits" || true)"
      [ -n "$hits" ] || { echo "（无匹配）"; exit 0; }
      printf '%s\n' "$hits" | while IFS= read -r l; do
        printf 'L%-5s %s\n' "${l%%:*}" "$(st_desc_of "${l#*:}")"
      done
      ;;
    add)
      om="$(need "${1:-}" om_)"; desc="$(need "${2:-}" 描述)"; scene="$(need "${3:-}" 场景关键词)"; shift 3
      raw="$(lark-cli api GET "/open-apis/im/v1/messages/$om" --as "$AS" \
        --jq '.data.items[0] | {t: .msg_type, c: .body.content}')"
      [ "$(jq -r '.t // empty' <<<"$raw")" = "sticker" ] || die "sticker add: 该消息不是 sticker"
      key="$(jq -r '.c | if type == "string" then (fromjson // .) else . end | .file_key // empty' <<<"$raw")"
      [ -n "$key" ] || die "sticker add: 消息里解析不出 file_key"
      if grep -qF "$key" "$idx"; then
        echo "$PROG: 已收藏过，不重复入库：$(grep -F "$key" "$idx" | head -1 | st_desc_of)"
        exit 0
      fi
      printf '| `%s` | %s | %s |\n' "$key" "${desc//|/、}" "${scene//|/、}" >> "$idx"
      ( cd "$dir" && lark-cli im +messages-resources-download --message-id "$om" \
          --file-key "$key" --type file --output "stickers/$key" --as "$AS" >/dev/null 2>&1 ) \
        || echo "$PROG: 警告：表情图片下载失败（索引已入）$om" >&2
      echo "$PROG: 已收藏：$desc — $scene"
      ;;
    rm)
      sel="$(need "${1:-}" '行号|关键词')"
      if [[ "$sel" =~ ^[0-9]+$ ]]; then
        lineno="$sel"; row="$(sed -n "${sel}p" "$idx")"
        [[ "$row" == '| `'* ]] || die "sticker rm: 第 $sel 行不是数据行"
      else
        hits="$(grep -n '^| `' "$idx" | grep -iF -- "$sel" || true)"
        n="$(grep -c . <<<"$hits" || true)"
        [ "$n" -ge 1 ] || die "sticker rm: 索引没匹配到「$sel」"
        if [ "$n" -gt 1 ]; then
          echo "$PROG: sticker rm: 「$sel」匹配 $n 条，需唯一匹配，请用行号：" >&2
          printf '%s\n' "$hits" | while IFS= read -r l; do
            echo "  L${l%%:*}  $(st_desc_of "${l#*:}")" >&2
          done
          exit 3
        fi
        lineno="${hits%%:*}"; row="${hits#*:}"
      fi
      sed -i "${lineno}d" "$idx"
      echo "$PROG: 已删除 L$lineno：$(st_desc_of "$row")"
      ;;
    *) die "sticker: 未知子命令 $sub（send/list/add/rm）" ;;
  esac
  ;;

api)
  method="$(need "${1:-}" METHOD)"; path="$(need "${2:-}" path)"; shift 2
  exec lark-cli api "$method" "$path" --as "$AS" "$@"
  ;;

-h|--help|help)
  usage
  ;;

*)
  die "未知分类：${category}（im/doc/sheet/contact/cal/drive/board/sticker/api，-h 看帮助）"
  ;;
esac
