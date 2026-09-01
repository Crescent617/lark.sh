# Contact / Calendar 参考

## 查人

```bash
lark contact get ou_xxx                    # open_id → 姓名/部门/邮箱/状态
```

姓名 → open_id 是 user-only API，回退原生（可逗号批量）：

```bash
lark-cli contact +search-user --queries '施惠杰,田新天' --as user
```

## 查忙闲

```bash
lark cal freebusy ou_xxx 2026-08-04T00:00:00+08:00 2026-08-10T00:00:00+08:00
```

时间是 RFC3339。返回忙闲块列表；查个人日程详情（agenda）是 user-only，用原生 `lark-cli calendar +agenda --as user`。
