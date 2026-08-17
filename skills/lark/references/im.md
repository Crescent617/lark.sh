# IM 参考

## 读消息

```bash
lark im read <oc_> -n 50                 # 最近 50 条（desc）
lark im read <oc_> -n 50 --asc           # 正序
lark im read <oc_> --start '<ts>' --end '<ts>'   # 时间窗（透传 lark-cli 同名参数）
lark im thread <omt_> -n 100             # 话题（thread id 也有 om_ 形态）
lark im mget om_a,om_b                   # 按 id 批量取
```

输出是 lark-cli 成功信封 `{ok, data, meta}`；shortcut 已归一化：消息在 `data.messages[]`，正文是**已解码的** `.content`（非字符串化 JSON），时间 `.create_time` 已格式化为 `YYYY-MM-DD HH:MM`。常用裁剪：

```bash
lark im read oc_x -n 20 | jq -r '.data.messages[] | "\(.create_time) \(.sender.id): \(.content)"'
```

注意与 raw api 的形态差异：`lark api GET /open-apis/im/v1/messages?...` 返回的是 `.data.items[]`、正文在 `.body.content`（字符串化 JSON 需二次解析）、时间戳是毫秒字符串。

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
lark im send oc_x @body.md                # 文件内容（wrapper 读文件，无相对路径限制）
lark im send oc_x - <<'EOF'               # stdin
长文
EOF
lark im send oc_x '<at user_id=ou_x>张辉</at> 看下'   # @人
```

## 回复 / sticker

```bash
lark im reply om_x '收到'                 # 主消息流回复
lark im reply om_x '收到' --thread        # 进话题
lark im sticker om_x <file_key>           # 以 sticker 回复该消息并进话题（最常用）
lark im sticker om_x <file_key> --main    # 回复但不进话题
lark im sticker oc_x <file_key>           # 直接发到群
```

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

消息列表里 sticker 的 content 只显示 `[Sticker]`，拿 file_key 要走 raw api：

```bash
lark api GET /open-apis/im/v1/messages/<om_> --jq '.data.items[0].body.content' | jq -r .
# => "{\"file_key\":\"v3_xxx\"}"（字符串化 JSON，二次解析；--jq 无 -r，用 jq -r 解字符串）
lark im dl <om_> . --file-key <v3_xxx> --type file
```

然后看图写描述，图片存 `references/stickers/<file_key>.<ext>`，在 `stickers.md` 索引表追加一行。file_key 与采集租户绑定，跨租户可能失效。

**首次收藏时 `stickers.md` 与 `stickers/` 目录都不存在，自行创建**。这两个文件已 gitignore（本地收藏夹，不上传 GitHub），**不要 git add / 提交**。新建 `stickers.md` 用以下模板起手（之后只在表格里追加行）：

```markdown
# Sticker 收藏夹索引


| file_key | 内容 | 适用场景 |
|---|---|---|
| `<file_key>` | <画面描述含配字；粗口/攻击性加 ⚠️ 前缀> | <逗号分隔的触发场景关键词> |

```
