# lark skill

配合 `bin/lark.sh`（lark-cli 的 bot-only 封装）使用的 agent skill。`SKILL.md` 是 agent 操作手册，人类向的说明都在本文件。

## 安装

```bash
# 在仓库根目录下执行

# 1. lark 命令上 PATH
ln -s "$(pwd)/bin/lark.sh" /usr/local/bin/lark   # 或任何 PATH 内目录
lark -h                                           # 验证

# 2. skill 接入 agent（symlink 进 skills 目录）
ln -s "$(pwd)/skills/lark" ~/.agents/skills/lark
```

### 初始化 sticker

follow im.md

## 结构

- `SKILL.md`——agent 操作手册：规则、常用命令、sticker 规则（发送时机等）
- `references/`——agent 按需加载的深度参考（im / docs / sheets / drive / contact-calendar / api）
- `references/stickers.md` + `references/stickers/`——sticker 收藏夹（见下方隐私说明）

## 边界

只支持 bot 身份。

## 隐私说明

sticker 收藏夹（`references/stickers.md` 与 `stickers/` 图片）是**本地产物，已 gitignore，不会上传 GitHub**；换机器/重新 clone 后收藏夹为空，由 agent 在使用中按 `references/im.md` 的收藏流程重新采集积累。
