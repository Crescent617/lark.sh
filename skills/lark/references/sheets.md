# Sheets 参考

术语：**电子表格**（spreadsheet/工作簿，用 `--url` 或 `--spreadsheet-token` 定位）内含多个**工作表**（sheet/子表/tab，用 `--sheet-name` 或 `--sheet-id` 定位）。范围用 A1 记法（`A1:F30`），不带工作表前缀。

## 三件套（覆盖 80% 场景）

```bash
lark sheet create '标题'                                    # 新建，返回 token/url
lark sheet read --url <url>                                 # 读首个工作表（CSV，行首带 [row=N]）
lark sheet read --url <url> --sheet-name 'Sheet1' --range A1:F30
lark sheet write --url <url> --start-cell B2 --csv 'a,b
c,d'                                                        # 从锚点向右下铺开；= 开头当公式
lark sheet write --url <url> --csv @data.csv                # @file / - (stdin) 原生支持
```

要点：

- write 默认**覆盖**非空单元格；要保护加 `--allow-overwrite=false`。大范围写入先 `--dry-run`。
- read 大表默认上限 50 万字符；只要摘要就 `--range` 收窄或 `--max-chars` 调小。
- **bot 新建的表格只有 bot 自己看得见**，交付给用户时用 `lark drive share <token> --member-type openid --member-id <ou_> --perm full_access` 加协作者；同理，操作别人的表格前确保 bot 已被加为协作者。

## 长尾：`+shortcut` 透传

`lark sheet +<shortcut> [flags]` 原样透传 `lark-cli sheets`（自动 `--as bot` + 干净环境）。每个命令的 flag 看 `lark sheet +xxx --help`，完整列表 `lark-cli sheets --help`。常用对照：

| 意图 | shortcut |
|---|---|
| 富写（值/公式/样式/批注/单元格图片一次搞定） | `+cells-set` |
| 只设样式不动值 | `+cells-set-style` |
| 查找 / 替换 | `+cells-search` / `+cells-replace` |
| 插入/删除/隐藏/冻结行列 | `+insert-dimension` / `+dim-delete` / `+dim-hide` / `+dim-freeze` |
| 列宽 | `+cols-resize` |
| 合并 / 拆分 | `+cells-merge` / `+cells-unmerge` |
| 图表、条件格式、浮动图片 | `+chart-*` / `+cond-format-*` / `+float-image-*` |
| 多个写操作原子提交 | `+batch-update` |

删行列、清空等不可逆操作同样受高危门禁约束（exit 10 → 用户确认后补 `--yes`）。
