# Docs 参考

## 读

```bash
lark doc read 'https://moonshot.feishu.cn/docx/<token>'   # URL 或裸 token 都行
lark doc read <token> -k '关键词'          # 只取关键词相关片段（大文档省 token）
```

拿 block_id（编辑前必须）：

```bash
lark doc read <token> --detail with-ids   # 输出带 block_id
```

## 写

```bash
lark doc create '<h1>标题</h1><p>正文</p>'            # 新建，返回新文档 token；**建完自动订阅**（评论/更新通知回流 bot，失败只在 stderr 警告不拖垮建单）
lark doc append <doc> '<p>追加一段</p>'               # 文末追加
lark doc append <doc> @body.html                      # 文件/stdin 喂长文
lark doc replace <doc> doxcnXXX '<p>新内容</p>'       # 按 block_id 精确替换
```

内容是 HTML-ish 片段（`<p>` `<h1>` `<ul><li>` 等）。返回信封里 `identity` 可核对身份（文档归属 bot）。

**默认权限坑**：bot 新建的文档默认 `link_share_entity=tenant_readable`（**租户内任何人持链可读**）！要"只有 bot 能看"必须显式关：

```bash
lark api PATCH /open-apis/drive/v1/permissions/<doc>/public \
  --params '{"type":"docx"}' --data '{"link_share_entity":"closed"}'
```

密级标签（secure-label）是 user-only API，bot 设不了。

## shortcut 不够时：block 树 raw api

```bash
# 遍历 block 树
lark api GET /open-apis/docx/v1/documents/<doc>/blocks/<block>/children

# 批量改（大 JSON 走 stdin）
lark api PATCH /open-apis/docx/v1/documents/<doc>/blocks/batch_update --data @- <<'EOF'
{"requests":[ ... ]}
EOF
```
