# lark-sh

> Lark skills for pragmatist.

`lark.sh`：lark-cli 的轻封装（默认 bot 身份，首位 `-u` 切 user）+ 单一整合的 `lark` skill。

## 为什么

实战 session 里 751 条 lark-cli 命令暴露的重复逻辑：每条命令都要重打两个 `_NOTIFIER` 环境变量、`--as bot`、冗长的 shortcut 名（`+chat-messages-list`）。本仓库把它收敛成一件事：

- `bin/lark.sh`——内置环境变量、默认 `--as bot`（首位 `-u` 切 user）、按场景分类的短命令；
- `skills/lark/`——一个 skill 装全部：SKILL.md 只放常用命令，细节在 `references/`。

## 安装 / 使用

见 [skills/lark/README.md](skills/lark/README.md)。
