# lark skill

配合 `bin/lark.py`（lark-cli 的轻封装：默认 bot 身份，`-u` 切 user）使用的 agent skill。`SKILL.md` 是 agent 操作手册，人类向的说明都在本文件。依赖：python3、lark-cli、jq。

## 安装

```bash
# 在仓库根目录下执行

# 1. lark 命令上 PATH
ln -s "$(pwd)/bin/lark.py" ~/.local/bin/lark   # 或任何 PATH 内且持久的目录
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

默认 bot 身份；`lark` 后首位加 `-u` 切 user 身份（user 写操作先经人确认）。

## 隐私说明

sticker 收藏夹（`references/stickers.md` 与 `stickers/` 图片）是**本地产物，已 gitignore，不会上传 GitHub**；换机器/重新 clone 后收藏夹为空，由 agent 在使用中按 `references/im.md` 的收藏流程重新采集积累。
