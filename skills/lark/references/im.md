# IM 参考

## 读消息

```bash
lark im read <oc_> -n 50                 # 最近 50 条（desc）
lark im read <oc_> -n 50 --asc           # 正序
lark im read <oc_> --verbose             # 保留卡片折叠面板（默认剥离）
# 时间窗（wrapper flag 可任意位置混用）：
start=$(date -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S%:z'); end=$(date '+%Y-%m-%dT%H:%M:%S%:z')
lark im read <oc_> --start "$start" --end "$end" --asc --page-all --page-limit 50
lark im thread <omt_> -n 50              # 话题（thread id 也有 om_ 形态；--verbose 同 read）
lark im mget om_a,om_b                   # 按 id 批量取
```

> 时间戳要 **ISO 8601 带冒号时区**（`+08:00`，`%:z`；`+0800` 会被拒）；`--start/--end` 也接受 Unix 时间戳与 `2026-01-01` 纯日期。
> 时间窗模式建议带 `--page-all --page-limit N` 自动翻页拉全量（透传 lark-cli，单页上限 50）。

> `-n` 上限 **50**（消息列表 API page_size 硬顶，超了报 99992402），wrapper 会自动钳到 50；要更多用 `--page-token` 翻页（见下文「翻页」）。

输出是 lark-cli 成功信封 `{ok, data, meta}`；shortcut 已归一化：消息在 `data.messages[]`，正文是**已解码的** `.content`（非字符串化 JSON），时间 `.create_time` 已格式化为 `YYYY-MM-DD HH:MM`。常用裁剪：

```bash
lark im read oc_x -n 20 | jq -r '.data.messages[] | "\(.create_time) \(.sender.id): \(.content)"'
```

注意与 raw api 的形态差异：`lark api GET /open-apis/im/v1/messages?...` 返回的是 `.data.items[]`、正文在 `.body.content`（字符串化 JSON 需二次解析）、时间戳是毫秒字符串。

卡片消息：正文渲染为 `<card>` 包裹的纯文本 = header 标题 + 顶层 markdown（`collapsible_panel` 折叠面板默认剥离，`--verbose` 保留原文）。对 yomi 运行状态卡意味着：阶段行（`🐾 Typing…` 等标题）可见，实时输出与运行轨迹（trace）不可见。

## 翻页

返回的 `data.has_more=true` 时说明还有下页，把 `data.page_token` 带回下一页请求（余参透传给 lark-cli）：

```bash
# 手动翻一页
lark im read oc_x -n 50 --page-token '<上一页的 page_token>'

# 循环拉全量
tok=''
while :; do
  if [ -n "$tok" ]; then out="$(lark im read oc_x -n 50 --page-token "$tok")"; else out="$(lark im read oc_x -n 50)"; fi
  echo "$out" | jq -r '.data.messages[] | "\(.create_time) \(.sender.id): \(.content)"'
  [ "$(echo "$out" | jq -r '.data.has_more')" = true ] || break
  tok="$(echo "$out" | jq -r '.data.page_token')"
done
```

`im thread` 同理。没有一键全量翻页（lark-cli 对 messages 没有 `--page-all`）。

## 发消息

```bash
lark im send oc_x '文本'                  # 群
lark im send ou_x '文本'                  # 私信
lark im send oc_x --markdown '**粗体**'   # markdown
lark im send oc_x --image ./图.png         # 图片（cwd 相对路径/URL/img_key；绝对路径与 .. 被拒）
lark im send oc_x --file ./报告.pdf        # 文件（路径/URL/file_key；--video/--audio 同模式）
lark im send oc_x @body.md                # 文件内容（wrapper 读文件，无相对路径限制）
lark im send oc_x - <<'EOF'               # stdin
长文
EOF
lark im send oc_x '<at user_id="ou_x">XXX</at> 看下'   # @人（user_id 必须带引号，否则静默不解析）
```

## 回复 / sticker

```bash
lark im reply om_x '收到'                 # 主消息流回复
lark im reply om_x '收到' --thread        # 进话题
lark im reply om_x --markdown '**好**'    # markdown 回复（可叠 --thread，顺序任意）
lark im sticker om_x <file_key>           # 以 sticker 回复该消息（默认回主消息流，同 reply）
lark im sticker om_x <file_key> --thread  # 进话题
lark im sticker oc_x <file_key>           # 直接发到群
```

> 落点语义全命令统一：回复类（reply/sticker 接 `om_`）**默认回主消息流，要进话题加 `--thread`**；`oc_` 直发群无话题概念。

收藏夹 file_key 表见 `stickers.md`（本地文件，可能尚不存在——不存在说明收藏夹为空）；发送时机规则见 `SKILL.md` 的「sticker 规则」。

## 下载附件

```bash
lark im dl om_x                           # 下到 cwd（多附件消息全量下）
lark im dl om_x ./dl --file-key <key> --type file   # 指定附件；sticker 必须 --type file
```

`--output-dir` 只接受 cwd 内相对路径。sticker 下载后用 magic bytes 判格式（PNG `\x89PNG` / GIF `GIF8` / JPEG `\xff\xd8\xff` / WebP `RIFF....WEBP`）再改扩展名。

## 群管理

```bash
lark im chats                             # bot 所在群（全量）
lark im find '群名关键词'                  # 搜群
lark im members oc_x                      # 成员（全量分页；结果在 data.users/data.bots，计数在 user_total/bot_total）
lark im desc oc_x '新群描述'               # 改描述
```

## sticker 收藏流程

**一律用 `lark sticker add <om_> '<描述>' '<场景>'`**（自动取 key、去重、存图，key 全程不过手）——收藏夹已迁到全局存储 `~/.local/share/lark/stickers/<appId>/`（按 bot appId 分目录，`LARK_STICKER_DIR` 可覆盖），CRUD/发送细节见 SKILL.md「sticker 规则」。

想看图再写描述：先 `lark im dl <om_> ./tmpdir` 下载到本地看图，再 add。

raw api 逃生路径（调试用，正常不走）：消息列表里 sticker 的 content 只显示 `[Sticker]`，拿 file_key：

```bash
lark api GET /open-apis/im/v1/messages/<om_> --jq '.data.items[0].body.content' | jq -r .
# => "{\"file_key\":\"v3_xxx\"}"（字符串化 JSON，二次解析；--jq 无 -r，用 jq -r 解字符串）
lark im dl <om_> . --file-key <v3_xxx> --type file
```

file_key 与采集租户绑定，跨租户可能失效（这就是按 appId 分目录的原因）。
