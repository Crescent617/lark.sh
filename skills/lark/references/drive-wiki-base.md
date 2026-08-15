# Drive / Wiki / Base 参考

## Drive

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

## Wiki

```bash
lark wiki nodes <space_id>                 # 列顶层节点
lark wiki nodes <space_id> <parent_node>   # 列子节点
lark wiki new <space_id> <parent_node> '标题'   # 新建 docx 节点
```

## Base（多维表格）

```bash
lark base tables <base_token>              # 列数据表
lark base query <base_token> <table_id>                # 全量记录
lark base query <base_token> <table_id> '关键词'       # 关键词
lark base query <base_token> <table_id> --filter-json '{"conjunction":"and",...}'  # 条件（透传）
```

URL 换 token：`lark-cli base +url-resolve --url <链接>`（原生，不常用故未封装）。
