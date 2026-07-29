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
- **可恢复自动清理**：只在配置的提醒列表中，把“未完成、不重要、且 TaskForge 当前缓存和持久源都确认不存在”的提醒经过至少相隔 60 秒的两次扫描后删除。
- **重要提醒保护**：Apple 内建优先级大于零，或标题去除开头空白后以 `!`、`！`、`❗`、`‼️`、`⭐`、`📌` 开头的提醒永不进入清理候选。
- **删除前本机备份**：每批清理先写入并回读校验权限为 `0600` 的备份；最近一个尚未恢复的批次可以一键恢复。
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
        ├─ 完成状态 + 持久源引用 ─▶ Vault Markdown / TaskNotes ─▶ TaskForge done
        └─ 双源确认不存在 ─▶ 两次扫描 ─▶ 本机备份 ─▶ 删除 Apple 提醒
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
- 清理候选账本：`~/Library/Application Support/TaskForgeReminderSync/PruneCandidates.json`
- 清理备份：`~/Library/Application Support/TaskForgeReminderSync/PruneBackups/`
- 清理日志匿名化盐：`~/Library/Application Support/TaskForgeReminderSync/PruneHashSalt`

候选账本、清理备份和匿名化盐均为本机私有运行数据，文件权限为 `0600`
（父目录为 `0700`），不会进入 Git 仓库。备份可能包含恢复提醒所需的标题、
笔记、日期、闹钟、重复规则和原始系统标识，请像保护 Vault 一样保护该目录。

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
| `--prune-dry-run` | 严格只读分类，报告首次候选和已满足二次确认的数量；不写账本、备份或盐，不修改提醒 | 否 |
| `--prune-once` | 推进一次候选状态；首次登记，至少 60 秒后的下一次扫描才可能备份并删除 | 是 |
| `--restore-last-prune` | 恢复最近一个尚未恢复的实际删除批次 | 是 |
| `--sync` | 依次反向扫描、正向同步并推进一次自动清理 | 是 |
| `--watch` | 常驻近实时双向同步，并在每轮末推进自动清理 | 是 |

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

## 自动清理与恢复

清理候选必须同时满足全部条件：

1. 位于 `--list-name` 指定的列表（默认 `TaskForge 今日`）；
2. 尚未完成；
3. EventKit 优先级为零，且标题没有六个受保护前缀；
4. 当前 TaskForge 快照没有对应任务；
5. 持久源引用也无法在 Vault 中确认任务存在。

第 4、5 项是“双源不存在”检查。源文件不可读、引用越出 Vault、源行同名或
位置有歧义、TaskForge 快照解码失败、权限或 I/O 出错时，结果属于“无法判定”
而不是“不存在”，清理会失败关闭并保留提醒。旧版提醒若既不在当前缓存中，
也没有可验证的持久源引用，则可能成为候选。

清理只向 EventKit 请求目标列表中的提醒；其他 Apple 提醒列表、去重归档列表
和已完成历史都不参与清理。同名目标列表若出现多个匹配，工具会拒绝猜测并
整轮停止。目标列表不存在时，清理返回零，不会为了清理新建列表。

先运行严格只读预演：

```bash
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync \
  --prune-dry-run
```

真实推进需要两次独立扫描，且两次至少相隔 60 秒：

```bash
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync \
  --prune-once
# 至少 60 秒后，由 watcher / --sync / 第二次 --prune-once 再确认
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync \
  --prune-once
```

期间只要提醒被完成、加入优先级或重要前缀、恢复 TaskForge 身份、移出目标
列表或候选属性改变，旧候选就会撤销；属性改变后仍符合条件也要重新计时。
删除前必须成功写入并校验整批备份，否则整批不删除。

恢复按创建时间选择最新一个“尚未恢复、实际删除结果已解析且非空”的批次。
更新但删除结果尚未解析的备份，以及实际删除数为零的备份，会保留在磁盘上但
不会阻塞更早的真实删除批次，也不会被错误标记为已恢复。

```bash
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync \
  --restore-last-prune
```

恢复会重建用户可编辑字段，但 EventKit 会生成新的系统 ID。恢复项享有至少
24 小时的本机清理宽限；宽限结束后仍符合条件，也必须重新经历两次扫描。
如果原列表已经不存在，恢复只会尝试在备份记录的原提醒事项账户中重建；账户
缺失或同一账户中有多个同名列表时失败关闭，备份保持未消费。

## 同步与安全规则

1. 提醒必须带有本工具生成的稳定标记，才会参与反向同步。
2. 源文件必须位于当前 TaskForge Vault 内。
3. 任务必须是非重复任务，且 `onCompletion=keep`。
4. 源行必须与保存的引用一致，或能在文件中唯一找到。
5. 写入前创建带时间戳的完整文件备份。
6. 写入后逐字节校验文件，并等待 TaskForge 任务库刷新。
7. TaskForge 可能从缓存中移除已完成的内联任务；这不等于源任务被删除。
8. 早期版本创建、没有持久源引用且已经离开 TaskForge 缓存的提醒会被安全跳过，不会猜测写入。
9. 自动清理只删除符合上述五项条件并通过双扫描确认的 Apple 提醒；不会删除或移动 TaskForge 源任务。
10. Apple → TaskForge 反向同步仍只把源任务改为 `done`，绝不会因清理删除任务行或 TaskNotes 文件。
11. 去重维护只移动冗余提醒到独立归档列表，不删除提醒或 TaskForge 源任务；去重归档列表也不在自动清理范围内。

只读检查整个受管列表是否仍然无重复：

```bash
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync --audit
```

审计覆盖当前与历史受管提醒，只输出数量，不输出标题、笔记、Vault 路径或原始任务 ID。“历史源位置复用”是信息项：同一行在不同计划日期承载过不同任务，不等同于重复。

清理日志也只输出首次候选、等待、撤销、删除、恢复和失败的数量，必要的单项
关联使用本机随机盐生成的截断哈希。清理日志不会输出标题、笔记、Vault /
源文件路径、原始 TaskForge ID 或原始 EventKit ID。EventKit 读取若 30 秒
未完成，会取消该次请求并以匿名错误失败关闭，不会继续删除。

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
- 反向写入备份；
- 清理候选账本、清理备份、匿名化盐和运行日志。

如果需要找回已清理提醒，请在删除这些本机运行数据前执行
`--restore-last-prune`。App 已卸载时，可以重新构建后从 `dist` 运行恢复命令；
备份被恢复后仍会保留，并记录为已恢复。

## 开发与测试

```bash
swift run TaskForgeReminderCoreTests
swift build
./scripts/build-app.sh
```

测试覆盖 MessagePack v6 解码、今日任务筛选、稳定标记、ID 变化后的源位置
复用、歧义去重、日期语义比较、正反向完成策略、历史源引用、Markdown /
TaskNotes 回写、清理判定、双扫描状态机、私有备份、恢复宽限、EventKit
跨列表隔离以及读取超时取消。

## 限制

- TaskForge 改变内部缓存格式后，解码器可能需要更新。
- 同时改动内联任务的文件位置、行号和标题，且 TaskForge 也更换内部 ID 时，没有足够的稳定信息可安全认定为同一任务；工具宁可拒绝猜测。
- 当前不会反向处理重复任务或完成后会移动、归档、删除的任务。
- 自动清理判断的是“当前缓存与真实源都确认不存在”，不会仅凭 TaskForge 缓存暂时缺席就删除 Apple 提醒；已完成、重要或其他列表中的提醒不清理。
- TaskForge 未运行时，源文件可能不会立即被重新索引；建议让 TaskForge 保持运行。
- 本项目不提供云服务、遥测或跨设备同步；Apple 提醒事项自身的 iCloud 同步由系统负责。

## 参与贡献

请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。安全或隐私问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## License

[MIT](LICENSE)
