# Drive 参考

```bash
# 删除（高危：先确认，exit 10 后补 --yes）
lark drive rm <file_token> <type>          # type: docx/sheet/bitable/file/...
lark drive rm <file_token> docx --yes
# 注意：stdout 会先打一行非 JSON 的「Deleting ...」，管道 jq 前先过滤：
lark drive rm <file_token> docx --yes 2>&1 | sed -n '/^{/,$p' | jq -c '{ok}'

# 加协作者（参数透传 lark-cli drive +member-add，先 --help 看 flags）
lark drive share <token> --member-type openid --member-id <ou_> --perm view

# 权限细查（raw api）
lark api POST /open-apis/drive/v1/permissions/<token>/members --data '...'
```

知识库（wiki）与多维表格（base）未封装，用原生 `lark-cli wiki|base --as bot` 或 `lark api`。
