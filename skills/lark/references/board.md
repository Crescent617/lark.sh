# Board（画板）参考

画板住在文档里：**没有独立创建 API**（`POST /board/v1/whiteboards` 404），创建 = 往文档插 `<whiteboard>` 块。

## 创建

```bash
lark board create <doc> 'graph TD;A-->B'   # 文末插 mermaid 画板
lark board create <doc> @diagram.mmd       # 从文件/stdin 读
lark board create <doc> --svg @fig.svg     # SVG 画板
```

两个服务端怪癖（2026-08-26 e2e 实测，bash/Python 两版一致）：

- **单行 mermaid 会被拒**：`'graph TD;A-->B'` 报 `degrade_code=2107 Whiteboard content parse failed`；改成多行（`graph TD\n  A-->B\n`）即过。
- **mermaid→画板转换有降级时间窗**：同一命令前后相隔 ~15min 可以从全成功变全失败（`degrade_code=2107 + 1003`，`result: failed`），又自行恢复；密集文档编辑会加剧。失败后 sleep 2 重试；持续失败就是服务端窗口，等窗口过去，不是 wrapper 问题。

插文档中间：`lark doc replace` 或 docx block API。

## 更新

```bash
lark board update --whiteboard-token <tok> --source @a.mmd --input_format mermaid [--overwrite]
```

- token 从 `lark doc read <doc> --detail with-ids` 的 board 块拿。
- `--input_format`：raw（原生节点 JSON）/ mermaid / plantuml / svg；`--overwrite` 清空重画。
- 微调：`export --output-type raw` → 改 JSON → `update --input_format raw`。
- 防重试重复画：`--idempotent-token`（≥10 字符）。

## 导出

```bash
lark board export --whiteboard-token <tok> --output-type svg --output b.svg
```

`--output-type`：preview|svg|source|raw；preview 必须给 `--output`，其余缺省输出到 stdout。

## 深入

场景选型、DSL 语法：`lark-cli skills read lark-whiteboard`（单一事实源，不搬第二份）。
