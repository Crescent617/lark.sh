# raw api 参考（逃生舱口）

`lark api` 透传 `lark-cli api`，自动带 `--as bot` 与干净环境，其余参数（`--params` / `--data` / `--jq`）原样透传。

## 实测可用的路径食谱

```bash
# 取单条消息正文（body.content 是字符串化 JSON，需二次解码；--jq 无 -r，用 jq -r 解字符串）
lark api GET /open-apis/im/v1/messages/<om_> --jq '.data.items[0].body.content' | jq -r .

# 取 interactive 卡片正文：默认只回降级占位「请升级至最新版本客户端」。必须带未文档化参数
# card_msg_content_type=user_card_content（query 走 --params，拼 URL 会被吃掉），跨应用可读。
lark api GET /open-apis/im/v1/messages/<om_> \
  --params '{"card_msg_content_type":"user_card_content"}' \
  --jq '.data.items[0].body.content' | jq -r .

# 按条件列群消息
lark api GET '/open-apis/im/v1/messages?container_id_type=chat&container_id=<oc_>&sort_type=ByCreateTimeDesc&page_size=20' \
  --jq '.data.items[] | {message_id, msg_type, sender: .sender.id, create_time}'

# 群信息 / 群公告
lark api GET /open-apis/im/v1/chats/<oc_>
lark api GET /open-apis/im/v1/chats/<oc_>/announcement

# docx block 树与批量编辑
lark api GET /open-apis/docx/v1/documents/<doc>/blocks/<block>/children
lark api PATCH /open-apis/docx/v1/documents/<doc>/blocks/batch_update --data @- <<'EOF'
{...}
EOF

# 云盘权限成员
lark api POST /open-apis/drive/v1/permissions/<token>/members --data '...'
```

## 打法要点

- query 参数既可以拼在路径里（注意整体加引号），也可以 `--params '{"k":"v"}'`；**sticker 直发群的 `receive_id_type` 必须走 `--params`**，拼 URL 会被吃掉报 `99992402`。
- 大 body 一律 `--data @-` + heredoc，避免转义。
- 判断成功看信封 `ok == true`；`code` 只在错误信封里。
- 找路径/参数：`lark-cli schema <service>.<resource>.<method> --format json`，或 `lark-cli api --help`。
