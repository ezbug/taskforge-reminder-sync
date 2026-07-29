# TaskForge Reminder Sync

一个完全在本机运行的 macOS 双向同步工具：把 TaskForge 日历视图中的今日任务写入 Apple 提醒事项，并把 Apple 端的完成状态安全回写为 TaskForge `done`。

> 非 TaskForge 或 Apple 官方项目。当前版本针对 TaskForge `tasks.v6.bin` 数据格式开发。

## 功能

- **今日任务正向同步**：只为本地当天、状态不是 `done` / `cancelled` 的 TaskForge 任务创建提醒。
- **历史完成反向同步**：扫描目标列表中所有已完成的关联提醒，不受提醒日期限制。
- **近实时响应**：
  - Apple 提醒事项变化通知经过约 0.75 秒防抖后触发；
  - 每秒检查 TaskForge 任务库修改时间；
  - 每分钟主动核对，弥补系统通知漏失；
  - 每天 07:00、11:00、15:00 再做定时兜底。
- **时间保真**：全天任务保持为日期提醒；有时间的任务保留小时和分钟。
- **TaskForge 变动正向推送**：已关联任务的标题、日期、时间和完成状态发生变化后，会更新原来的提醒事项。
- **分层稳定去重**：先按 Vault + TaskForge 任务 ID 精确匹配；TaskForge 重新索引导致 ID 改变时，再按活跃任务源位置复用原提醒，并刷新其 ID 标记。
- **历史实例隔离**：同一笔记行可被不同日期的任务先后复用；已完成提醒只有在源位置和任务日期都相同时才会参与二级匹配。
- **歧义时不新建**：同一 ID 或源位置对应多个提醒时，记录冲突并停止该任务，不会继续制造重复项。
- **持久源映射**：提醒中保存经过 Base64 编码的任务源引用。任务离开 TaskForge 当前缓存后，历史提醒仍能定位原笔记。
- **防止误重开**：任意一端已经完成时，正向同步不会把 Apple 提醒重新打开。
- **先备份再回写**：每次反向修改前保存源文件副本，并记录修改前后的 SHA-256。
- **保守拒绝**：重复任务、非 `keep` 完成策略、Vault 外路径、陈旧或歧义源行都不会被自动修改。
- **不删除源任务**：
  - Markdown 内联任务：`- [ ]` 改为 `- [x]`，并追加完成日期；
  - TaskNotes 文件：frontmatter 改为 `status: done` 并更新 `completedDate`；
  - 工具不会删除任务行或 TaskNotes 文件。

## 工作原理

```text
TaskForge tasks.v6.bin
        │ 读取今日未完成任务
        ▼
Apple 提醒事项 / TaskForge 今日
        │ 完成状态 + 持久源引用
        ▼
Vault Markdown / TaskNotes
        │ TaskForge 重新索引
        ▼
TaskForge done
```

正向同步只**新建今天的任务**，避免把整个 Vault 导入提醒事项；已经关联的任务即使改到其他日期，仍会更新原提醒。反向同步则会检查所有已经建立关联的提醒，因此昨天或更早的任务在 Apple 端完成后仍可闭环。

去重身份按以下顺序选择：

1. 精确的 TaskForge 任务 ID；
2. 未完成提醒使用稳定源位置：
   - Markdown 内联任务：“标准化文件路径 + 行号”；
   - TaskNotes 任务：“标准化文件路径”；
3. 已完成提醒还必须与当前任务的计划日期相同，避免历史任务占用今天的新实例。

第二层命中时不会创建新提醒，而是更新同一个 EventKit 项目，并把提醒中的任务 ID 与源引用替换为 TaskForge 的最新值。如果任一层出现多个候选，工具会保守停止而不是猜测。

详细设计见 [架构说明](docs/ARCHITECTURE.md)，数据与权限边界见 [隐私说明](PRIVACY.md)。

## 系统要求

- macOS 13 或更高版本；
- 已安装 TaskForge；
- TaskForge 使用 `tasks.v6.bin` 数据格式；
- Xcode Command Line Tools / Swift 5.9 或更高版本；
- Apple 提醒事项账户；
- 建议 TaskForge 保持运行，以便反向写入后及时重新索引。

## 安装

```bash
git clone https://github.com/ezbug/taskforge-reminder-sync.git
cd taskforge-reminder-sync
./scripts/build-app.sh
```

`build-app.sh` 默认使用本机 ad hoc 签名，适合自行构建和首次使用。ad hoc
签名只标识当前这一版二进制；重新构建后，macOS 可能要求重新授予提醒事项和文件
访问权限。如果钥匙串中已有稳定的代码签名身份，可在构建时指定：

```bash
TASKFORGE_SYNC_CODESIGN_IDENTITY="Apple Development: Your Name" \
  ./scripts/build-app.sh
```

项目不会自动创建证书、修改钥匙串或重置 TCC 权限。

先做完全无写入的配置检查与今日任务预览：

```bash
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync --check-config
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync --dry-run
```

第一次真实同步：

```bash
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync --sync
```

macOS 会请求“提醒事项”访问权限。工具不需要“日历”权限。根据系统隐私设置，读取 TaskForge 容器或 Vault 时可能还需要为 App 授予“完全磁盘访问权限”。

确认一次性同步正常后，安装常驻 LaunchAgent：

```bash
./scripts/install-daily-sync.sh
```

安装器使用一个随 App 签名的小型监督进程，再通过 macOS LaunchServices 启动
同步 App，而不是把 App 包内的主二进制当作普通后台命令执行。这样常驻同步进程
与手动运行使用同一个 bundle 身份，系统授予的“提醒事项”权限才能在后台正确
生效；若同步进程退出，LaunchAgent 会重新拉起它。

安装位置：

- App：`~/Applications/TaskForgeReminderSync.app`
- LaunchAgent：`~/Library/LaunchAgents/local.codex.taskforge-reminder-sync.plist`
- 标准日志：`~/Library/Logs/TaskForgeReminderSync.log`
- 错误日志：`~/Library/Logs/TaskForgeReminderSync.error.log`
- 回写备份：`~/Library/Application Support/TaskForgeReminderSync/Backups/`

## 命令

| 命令 | 作用 | 是否写入 |
|---|---|---|
| `--check-config` | 检查 TaskForge、数据版本、Vault 和今日任务数量 | 否 |
| `--dry-run` | 列出今天将被同步的任务 | 否 |
| `--audit` | 区分重复活跃任务、重复历史实例、正常历史源复用和缺失映射；不输出任务内容 | 否 |
| `--deduplicate-dry-run` | 预演重复组、保留数和归档数 | 否 |
| `--deduplicate` | 保留权威提醒，把冗余活跃提醒移到可恢复的归档列表 | 是 |
| `--reverse-dry-run` | 预览 Apple → TaskForge 的源文件修改 | 否 |
| `--reverse-once` | 执行一次反向完成并等待 TaskForge 回读 | 是 |
| `--sync` | 先反向扫描，再执行一次今日任务正向同步 | 是 |
| `--watch` | 常驻近实时双向同步 | 是 |

常用参数：

```text
--list-name NAME       目标提醒事项列表，默认“TaskForge 今日”
--task-store PATH      自定义 tasks.v6.bin 路径
--date YYYY-MM-DD      指定正向预览/同步日期
--task-id ID           只处理一个 TaskForge 任务
--backup-root PATH     自定义反向写入备份目录
```

定向预览或完成一个任务：

```bash
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync \
  --reverse-dry-run --task-id TASK_ID
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync \
  --reverse-once --task-id TASK_ID
```

## 同步与安全规则

1. 提醒必须带有本工具生成的稳定标记，才会参与反向同步。
2. 源文件必须位于当前 TaskForge Vault 内。
3. 任务必须是非重复任务，且 `onCompletion=keep`。
4. 源行必须与保存的引用一致，或能在文件中唯一找到。
5. 写入前创建带时间戳的完整文件备份。
6. 写入后逐字节校验文件，并等待 TaskForge 任务库刷新。
7. TaskForge 可能从缓存中移除已完成的内联任务；这不等于源任务被删除。
8. 早期版本创建、没有持久源引用且已经离开 TaskForge 缓存的提醒会被安全跳过，不会猜测写入。
9. TaskForge 删除任务时，本工具不会自动删除对应提醒；删除属于显式的非自动操作。
10. 去重维护只移动冗余提醒到独立归档列表，不删除提醒或 TaskForge 源任务。

只读检查整个受管列表是否仍然无重复：

```bash
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync --audit
```

审计覆盖当前与历史受管提醒，只输出数量，不输出标题、笔记、Vault 路径或原始任务 ID。“历史源位置复用”是信息项：同一行在不同计划日期承载过不同任务，不等同于重复。

修复早期版本已经产生的活跃重复项：

```bash
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync \
  --deduplicate-dry-run
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync \
  --deduplicate
```

去重优先保留仍与当前 TaskForge ID 精确匹配的提醒；没有精确匹配时保留最早创建项。冗余项不会被删除，而是移到“TaskForge 今日 · 去重归档”，随后保留项会重新关联当前 TaskForge 记录。需要恢复时可在 Apple 提醒事项中手动移回。

## 日志与排障

```bash
tail -f ~/Library/Logs/TaskForgeReminderSync.log
tail -f ~/Library/Logs/TaskForgeReminderSync.error.log
launchctl print "gui/$(id -u)/local.codex.taskforge-reminder-sync"
```

常见问题和恢复方式见 [排障指南](docs/TROUBLESHOOTING.md)。

## 卸载

```bash
./scripts/uninstall-daily-sync.sh
```

卸载会停止 LaunchAgent 并移除安装的 App，不会删除：

- Apple 提醒事项中已经创建的内容；
- Vault 中的任何笔记或任务；
- 反向写入备份。

## 开发与测试

```bash
swift run TaskForgeReminderCoreTests
swift build
./scripts/build-app.sh
```

测试覆盖 MessagePack v6 解码、今日任务筛选、稳定标记、ID 变化后的源位置复用、歧义去重、日期语义比较、正反向完成策略、历史源引用、Markdown / TaskNotes 回写和安全拒绝条件。

## 限制

- TaskForge 改变内部缓存格式后，解码器可能需要更新。
- 同时改动内联任务的文件位置、行号和标题，且 TaskForge 也更换内部 ID 时，没有足够的稳定信息可安全认定为同一任务；工具宁可拒绝猜测。
- 当前不会反向处理重复任务或完成后会移动、归档、删除的任务。
- 当前不会根据 TaskForge 删除操作自动删除 Apple 提醒事项。
- TaskForge 未运行时，源文件可能不会立即被重新索引；建议让 TaskForge 保持运行。
- 本项目不提供云服务、遥测或跨设备同步；Apple 提醒事项自身的 iCloud 同步由系统负责。

## 参与贡献

请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。安全或隐私问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## License

[MIT](LICENSE)
