---
name: lark
description: 飞书一站式操作（lark.sh，lark-cli 的 bot-only 封装）：IM 读/发/回/附件、sticker 表情、云文档读写、联系人、日历忙闲、云盘/知识库/多维表格、raw api 逃生舱口。当需要与飞书交互（收发信息、读群记录、发表情、读写文档、查人查忙闲）时使用。
metadata:
  requires:
    bins: ["lark", "lark-cli", "jq"]
---

# lark

**一律用 `lark` 调用，不写路径**（省 token）。若 `lark` 不在 PATH（未安装），提示人类按本目录 `README.md` 安装。

## 规则（先读）

1. **bot-only**：本封装没有 user 身份。
2. **当前会话不要重复发**：agent 的回复文本会自动落到当前 chat/thread；只有跨 chat、私信、sticker 才用 `lark im send/sticker`。
3. **高危门禁**：删文件等操作 lark-cli 会 exit 10 要确认——先向用户确认，同意后在原命令末尾补 `--yes` 重跑，绝不静默加。
4. **判成功用 `ok == true`**（或退出码 0），不要用 `code == 0`。
5. **本机路径参数**（`im dl` 的目录等）只接受 **cwd 内相对路径**；正文载荷统一支持 `文本 | @file | -`（stdin），wrapper 会读出来，不受此限。

## 常用命令

```bash
# IM
lark im read <oc_> -n 20 # 读群消息，最新在前；--asc 最老在前；--verbose 保留卡片折叠（默认剥离）
lark im read <oc_> --page-token '<tok>' # 翻页：带上上页的 page_token
lark im thread <omt_> -n 20 # 读话题消息（--verbose 同 read）
lark im send <oc_> '文本' # 发群消息；换 ou_ 发私信
lark im send <oc_> --markdown '**粗体**' # 发 markdown
lark im send <oc_> --image ./图.png # 发图片（路径/URL/img_key）
lark im send <oc_> --file ./报告.pdf # 发文件（路径/URL/file_key；--video/--audio 同理）
lark im send <oc_> '<at user_id="ou_x">名字</at> 看下' # @人（user_id 必须带引号，否则静默不解析）
lark im reply <om_> '文本' # 回复；--thread 进话题；--markdown 发富文本
lark im sticker <om_> <file_key> # 表情回复（默认回主流，--thread 进话题）；换 oc_ 直发群
lark im dl <om_> ./dir # 下载消息附件
lark im members <oc_> # 列群成员
lark im find '关键词' # 按名搜群

# 文档
lark doc read <url|token> # 读文档；-k '词' 只取相关片段
lark doc create '<h1>标题</h1><p>正文</p>' # 新建文档（HTML 片段；自动订阅）
lark doc append <doc> @body.html # 文末追加
lark doc replace <doc> <block_id> '<p>新</p>' # 替换指定块

# 表格
lark sheet create '标题' # 新建表格（归 bot，记得 share；自动订阅）
lark sheet +info --url <url> # 列工作表（拿 sheet 名/id）
lark sheet read --url <url> --sheet-name Sheet1 --range A1:F30 # 读区域（必带工作表）
lark sheet write --url <url> --sheet-name Sheet1 --start-cell B2 --csv @data.csv # 写区域（必带 --sheet-name/--sheet-id；= 当公式）

# 人 / 日程
lark contact get <ou_> # 查 open_id 是谁
lark cal freebusy <ou_> <起> <止> # 查忙闲

# 画板
lark board create <doc> 'graph TD;A-->B' # 文末新建画板（mermaid）
lark board update --whiteboard-token <tok> --source @a.mmd --input_format mermaid # 更新画板
lark board export --whiteboard-token <tok> --output-type svg --output b.svg # 导出画板

# 逃生舱口
lark api GET /open-apis/im/v1/messages/<om_> --jq '.data.items[0].body.content' | jq -r . # 直打 OpenAPI，例：取消息原文
```

## ID 前缀

`oc_`=群，`om_`=消息，`omt_`=话题，`ou_`=用户 open_id，`v3_*`=sticker file_key。

## 深度参考（按需加载）

| 文件 | 内容 |
|---|---|
| `references/im.md` | IM 全命令参数、时间窗读法、sticker 收藏流程 |
| `references/sheets.md` | 电子表格三件套、+shortcut 透传速查、bot 权限坑 |
| `references/docs.md` | 文档 block 编辑、with-ids、批量 batch_update |
| `references/drive.md` | 云盘删除/加协作者 |
| `references/board.md` | 画板创建/更新/导出 |
| `references/contact-calendar.md` | 查人、忙闲 |
| `references/api.md` | raw api 打法与实测可用的路径食谱 |
| `references/stickers.md` | **sticker 收藏夹索引表**（file_key → 内容/场景）；本机文件，可能不存在——见下方 sticker 规则 |


## sticker 规则

- 收藏夹 = `references/stickers.md` + `stickers/`（本机文件，gitignore 不上传，可能尚不存在）；没有合适的 file_key 就直说没有，**不要编**。收藏流程见 `im.md`。
- 闲聊/玩梗可主动发，正式场合不发；用户点名随意发；一次一个；进当前 thread 就显式加 `--thread`（命令默认回主流）；⚠️ 标记者只对熟人用。
