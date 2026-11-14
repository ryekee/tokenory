# 本地存储维护

## 自动备份与预览

自动备份只识别 `backups` 目录中名称严格符合 `YYYYMMDDTHHMMSS.nnnnnnnnn-{已知动作}.sqlite3` 的普通文件，并保留最近 3 份。手工命名和未知命名的文件不受此策略影响。保留的备份仍占用空间，但自动备份不会无限增长。

导入预览与价格重估预览分别保留最近 3 份，有效期为 24 小时；成功应用后删除对应预览。旧版缺少创建时间的预览会清除。启动和生成预览时执行清理。预览 ID 使用 `app_state` 中预留的单调序列，避免删除后复用。本次维护不升级数据库 schema。

清理不删除实际的 `usage_records`、`codex_turns`、`import_batches`、覆盖信息或价格数据。连续的 schema 升级只创建一次备份。

## 压缩数据库

退出 Tokenory App 后执行：

```sh
tokenory --data-dir PATH compact
```

命令获取 `writer.lock`，创建备份，执行 `VACUUM` 并截断 WAL。`PATH` 是要维护的数据目录。

## 开发构建缓存

已清理以下可再生目录：

- `cli/target`
- `.build/xcode/Build/Intermediates.noindex`
- `.build/xcode/Index.noindex`
- `.build/swift-module-cache`
- `.build/xcode/SDKExplicitPrecompiledModules`

清理后构建会重新生成所需缓存。工具链、源码、发布归档和 App 产物保留。

## 本机维护构建与验收

已将 Release 优化的本地 ad-hoc 签名维护构建安装到 `~/Applications/Tokenory.app`，版本保持 0.1.6 (8)，没有新的公开 release。Apple 公证提交因未明确授权上传而被自动审批拒绝；该构建不是新公证包。

清理时已暂停 App。工程目录从 7.43 GiB 降至 1.81 GiB，生产数据目录从 977.5 MiB 降至 360.6 MiB，合计释放 6.228 GiB。主数据库从 83.6 MiB 降至 35.3 MiB。4 份导入预览和 7 份重估预览已清除，保留 2 份手工备份和 3 份自动备份。

账本和历史表的排序内容 SHA-256 及两份手工备份的 SHA-256 在维护前后完全一致，SQLite `integrity_check` 返回 `ok`。88 项 Rust 测试和 29 项原生测试通过；App 与 helper 已重启，并使用正式数据目录运行。这些检查不代表完整的实际界面验收。

维护前后数据见 `.build/storage-maintenance/before.json`、`.build/storage-maintenance/after.json` 和 `.build/storage-maintenance/summary.json`。
