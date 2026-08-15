---
name: lark
description: 飞书一站式操作（lark.sh，lark-cli 的 bot-only 封装）：IM 读/发/回/附件、sticker 表情、云文档读写、联系人、日历忙闲、云盘/知识库/多维表格、raw api 逃生舱口。当需要与飞书交互（收发信息、读群记录、发表情、读写文档、查人查忙闲）时使用。user-only 操作（消息全文搜索、个人日历/云盘）不在此列，回退原生 lark-cli --as user。
metadata:
  requires:
    bins: ["lark", "lark-cli", "jq"]
---

# lark

**一律用 `lark` 调用，不写路径**（省 token）。若 `lark` 不在 PATH（未安装），提示人类按本目录 `README.md` 安装。

## 规则（先读）

1. **bot-only**：本封装没有 user 身份。消息全文搜索、个人日历/云盘等 user-only 场景用原生 `lark-cli --as user`。
2. **当前会话不要重复发**：agent 的回复文本会自动落到当前 chat/thread；只有跨 chat、私信、sticker 才用 `lark im send/sticker`。
3. **高危门禁**：删文件等操作 lark-cli 会 exit 10 要确认——先向用户确认，同意后在原命令末尾补 `--yes` 重跑，绝不静默加。
4. **判成功用 `ok == true`**（或退出码 0），不要用 `code == 0`。
5. **本机路径参数**（`im dl` 的目录等）只接受 **cwd 内相对路径**；正文载荷统一支持 `文本 | @file | -`（stdin），wrapper 会读出来，不受此限。

## 常用命令

```bash
# IM
lark im read <oc_> -n 20                  # 读群消息：最新的在前；--asc 改成最老的在前
lark im read <oc_> -n 50 --page-token '<tok>'  # 翻下一页：tok 抄上一页返回里的 data.page_token（data.has_more=true 就是还有）
lark im thread <omt_> -n 20               # 读话题里的消息，同上
lark im send <oc_> '文本'                  # 发群消息；把 oc_ 换成 ou_ 就是发私信；长文用 @文件 或 -（stdin）
lark im send <oc_> --markdown '**粗体**'   # 发 markdown
lark im send <oc_> '<at user_id=ou_x>名字</at> 看下'  # @人
lark im reply <om_> '文本'                 # 回复某条消息；加 --thread 回复进话题
lark im sticker <om_> <file_key>          # 用表情回复（自动进话题）；换成 oc_ 就是直接发群。file_key 查 references/stickers.md
lark im dl <om_> ./dir                    # 把消息里的图片/附件下载到目录
lark im members <oc_>                     # 列群成员
lark im find '关键词'                      # 按名字搜群

# 文档
lark doc read <url|token>                 # 读整篇文档；加 -k '关键词' 只取相关片段（大文档省 token）
lark doc create '<h1>标题</h1><p>正文</p>'  # 新建文档（内容写 HTML 片段）
lark doc append <doc> @body.html          # 在文末追加
lark doc replace <doc> <block_id> '<p>新内容</p>'  # 替换指定段落块（block_id 先用 doc read --detail with-ids 拿）

# 表格
lark sheet create '标题'                   # 新建电子表格（归 bot 所有，交付前记得 lark drive share 给人）
lark sheet read --url <url> --range A1:F30  # 读一块区域（CSV 输出）
lark sheet write --url <url> --csv @data.csv  # 写一块区域（= 开头当公式）；更多操作：lark sheet +<shortcut>

# 人 / 日程
lark contact get <ou_>                    # 查这个 open_id 是谁
lark cal freebusy <ou_> <开始> <结束>       # 查某人某段时间的忙闲

# 逃生舱口：封装不够用时直接打飞书 OpenAPI
lark api GET /open-apis/im/v1/messages/<om_> --jq -r '.data.items[0].body.content'   # 例：取单条消息原文
```

## ID 前缀

`oc_`=群，`om_`=消息，`omt_`=话题，`ou_`=用户 open_id，`v3_*`=sticker file_key。

## 深度参考（按需加载）

| 文件 | 内容 |
|---|---|
| `references/im.md` | IM 全命令参数、时间窗读法、sticker 收藏流程 |
| `references/sheets.md` | 电子表格三件套、+shortcut 透传速查、bot 权限坑 |
| `references/docs.md` | 文档 block 编辑、with-ids、批量 batch_update |
| `references/drive-wiki-base.md` | 云盘权限/删除、知识库节点、多维表格查询 |
| `references/contact-calendar.md` | 查人（含批量搜的 user-only 回退）、忙闲 |
| `references/api.md` | raw api 打法与实测可用的路径食谱 |
| `references/stickers.md` | **sticker 收藏夹索引表**（file_key → 内容/场景）；本机文件，可能不存在——见下方 sticker 规则 |


## sticker 规则

- `references/stickers.md` 与 `references/stickers/` 图片是**本机收藏夹，已 gitignore，不随仓库上传 GitHub**；换机器/重新 clone 后需重新采集，不随仓库分发。
- **初始不存在这两个文件**：首次发表情时收藏夹是空的（没有现成 file_key 可用就直接说没有，不要编）；首次收藏表情时按 `im.md` 的收藏流程（内含 `stickers.md` 完整模板）自建，之后随收藏增量维护。
- 采集多了、表格变长后，按场景挑选即可。

### 发送时机（主动发表情时遵守）

- 只在轻松闲聊、斗图、玩梗场景主动发；故障排查、正式汇报、严肃讨论**不发**
- 用户明确要求发某个/某类表情时总是可以发
- 一次最多发一个，不刷屏；默认发在当前会话当前 thread
- 表格里标 ⚠️ 的带粗口/攻击性表情，只对熟人且对方先用同类语气时用
- 批量发、跨会话发第三方属于可见写操作，先向用户确认接收方与内容
