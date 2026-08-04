# TaskForge Kanban ↔ Apple 提醒事项

一个完全在本机运行的 macOS 双向同步工具：把固定绑定的 TaskForge 自定义
Kanban `Today` 列表映射为多个彩色 Apple 提醒事项列表，并把 Apple 的状态变化
安全回写 TaskForge 源任务。

它不是 TaskForge 或 Apple 官方项目。TaskForge 2.6.1 没有可依赖的官方 CLI/API；
本工具只读取本机 `tasks.v6.bin` 和自定义列表配置，不使用 Computer Use，也不向
网络上传任务内容、路径、列表 ID 或个人资料。

## 同步边界

默认源是 `custom-list`，不是按日期筛选。成员集合由下面两份本机数据按 TaskForge
真实规则计算：

```text
tasks.v6.bin + flutter.ctl_<固定列表 ID>
        │ 组内 all/any、组间 all/any、字段和操作符
        ▼
TaskForge Today 当前成员
```

列表 ID 首次可通过 `--taskforge-list-id` 提供，成功写入时只保存到权限为 `0600`
的私有配置；代码、日志、Git 和 README 不包含真实 ID。列表配置缺失、JSON 损坏、
任务库损坏、未知字段/操作符或未知逻辑时整轮失败关闭，不猜测成员。

`--source scheduled-day` 和旧的 `--date`、`--list-name` 只保留兼容模式；custom-list
模式使用这些旧参数会直接拒绝。

## Apple 状态列表

活动状态按需创建，前缀默认为 `TaskForge`，可用 `--list-prefix` 修改。首次创建
`TaskForge · 待办` 时会把旧的 `TaskForge 今日` 列表原地重命名并复用；不会因重命名
更换源列表。

| TaskForge 状态 | Apple 列表 | 颜色 | 说明 |
|---|---|---|---|
| `todo` | `TaskForge · 待办` | 蓝 | 默认活动状态 |
| `scheduled` | `TaskForge · 已计划` | 紫 | 活动列表 |
| `ready` | `TaskForge · 就绪` | 绿 | 活动列表 |
| `inProgress` | `TaskForge · 进行中` | 青 | 活动列表 |
| `onHold` | `TaskForge · 暂停` | 橙 | 首次出现时创建 |
| `deferred` | `TaskForge · 已推迟` | 灰 | 首次出现时创建 |
| `blocked` | `TaskForge · 已阻塞` | 红 | 首次出现时创建 |
| `someday` | `TaskForge · 将来某天` | 靛蓝 | 首次出现时创建 |
| `done` | 无活动列表 | — | 完成提醒，不删除 TaskForge 任务 |
| `cancelled` | 无活动列表 | — | 完成提醒，标题额外标注“已取消” |

未知但合法的 TaskForge 状态会以同前缀的灰色列表显示；未知状态不会被猜测写回。
列表 ID 被删除或配置丢失时停止同步。

## 双向语义

- TaskForge 标题、原始计划日期/时间和优先级正向更新对应提醒；不会人为添加“今天”。
- Apple 状态列表移动会回写源状态；移动到普通 Apple 列表的受管提醒会被移回正确状态。
- TaskForge 开放状态变化与 Apple 开放状态变化冲突时，TaskForge 优先。
- Apple 新发生的完成操作优先，写回 TaskForge `done`；绝不删除 TaskForge 任务行或文件。
- 受管提醒只由工具标记或私有索引识别；普通 Apple 列表永不扫描、删除或批量修改。
- 已不属于 Today、未完成且无优先级的受管提醒，必须经过至少 60 秒间隔的双扫描、
  备份和回读校验后才可能删除；重要、已完成、无法判断来源的提醒受保护。
- `TaskForge 今日 · 去重归档` 中确认属于历史重复项的提醒可统一完成，但不会触发
  TaskForge 反向完成；完成后退出 Apple “今天”视图由用户自行操作。

### 反向符号学习

首期只允许已确认符号：待办 `[ ]`、已计划 `[>]`、进行中 `[/]`、完成 `[x]`。
工具从真实 TaskForge 记录学习映射并保存到权限为 `0600` 的状态字典。尚未学会、
同一状态冲突或一个符号被多个状态占用时，拒绝写源文件并把提醒移回 TaskForge
当前状态。Markdown/TaskNotes 写回都先校验源身份和原始内容，再备份、原子写入、
SHA-256 校验并等待 TaskForge 回读。

提醒备注只保留简洁工具标记和来源标记；完整源引用、上次状态、哈希和提醒映射只
保存在私有索引中。

## 近实时监听

- `EKEventStoreChanged` 触发约 0.75 秒防抖同步；
- 每秒轮询任务库和自定义列表配置的修改时间；
- 每 60 秒做一次全量校准，恢复漏事件；
- 07:00、11:00、15:00 仅作为额外兜底校准。

这表示本机事件驱动的近实时语义，不是 TaskForge 官方推送。验收目标是本地变化
通常 5 秒内完成，漏事件最迟 60 秒修复。

## 系统要求与安装

- macOS 13 或更高版本；
- 已安装 TaskForge，并使用 `tasks.v6.bin`；
- Swift 5.9 / Xcode Command Line Tools；
- 一个可用的 Apple 提醒事项账户。

```bash
git clone https://github.com/ezbug/taskforge-reminder-sync.git
cd taskforge-reminder-sync
./scripts/build-app.sh
```

第一次只读配置和成员预演（不会请求提醒事项权限，也不会创建私有状态文件）：

```bash
APP=./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync
"$APP" --check-config --taskforge-list-id LIST_ID
"$APP" --dry-run --taskforge-list-id LIST_ID
```

预演输出的状态数量必须与 TaskForge Today 当前界面动态数量一致，才能进入写入门槛。
确认后执行一次同步，系统会请求提醒事项完整访问权限：

```bash
"$APP" --sync --taskforge-list-id LIST_ID
"$APP" --watch
```

也可以先使用 `--sync --list-prefix NAME`；后续省略前缀时会复用私有配置。macOS
隐私设置可能还需要允许该 App 读取 TaskForge 容器和 Vault。工具只需要“提醒事项”
权限，不需要“日历”权限；不会自动重置 TCC，也不会自动批准权限。

建议确认一次性同步和专用验收任务后，再安装监督进程：

```bash
./scripts/install-daily-sync.sh
```

安装器不会把真实列表 ID 写入 plist；watcher 从权限为 `0600` 的私有配置读取。卸载：

```bash
./scripts/uninstall-daily-sync.sh
```

## 命令

| 命令 | custom-list 行为 | 写入 |
|---|---|---|
| `--check-config` | 检查 v6、固定列表和状态计数 | 否 |
| `--dry-run` | 匿名输出成员及各状态数量 | 否 |
| `--sync` | 反向冲突处理、正向同步、双扫描推进 | 是 |
| `--reverse-dry-run` | 预览 Apple → TaskForge 候选 | 否（需权限） |
| `--reverse-once` | 执行一次反向状态写回 | 是 |
| `--deduplicate-dry-run` | 预览当前受管重复组 | 否（需权限） |
| `--deduplicate` | 将确认的历史重复提醒移到归档并完成 | 是 |
| `--prune-dry-run` | 只读清理分类，不写账本 | 否（需权限） |
| `--prune-once` | 推进双扫描、备份并按门槛清理 | 是 |
| `--watch` | 常驻近实时双向同步 | 是 |

custom-list 的 `--deduplicate` 只把确认的重复提醒移到
`TaskForge 今日 · 去重归档` 并标记完成；归档标记会阻止它触发 TaskForge 反向完成。
`--restore-last-prune` 仍仅在 `scheduled-day` 兼容模式提供。兼容模式保留旧的
`--audit`、`--deduplicate-*` 等维护命令，但不会改变 custom-list 的源语义。

常用参数：

```text
--source custom-list|scheduled-day   同步源，默认 custom-list
--taskforge-list-id LIST_ID         固定绑定的自定义 Kanban 列表 ID
--list-prefix NAME                  Apple 状态列表前缀
--task-store PATH                   自定义 tasks.v6.bin 路径
--task-id ID                        专用任务验收时只处理一个任务
--backup-root PATH                  源文件反向写入备份目录
--date YYYY-MM-DD                   仅 scheduled-day 兼容模式
--list-name NAME                    仅 scheduled-day 兼容模式
```

## 私有数据、备份与回滚

默认私有运行根目录：

```text
~/Library/Application Support/TaskForgeReminderSync/
├── KanbanSyncConfig.json       0600：列表 ID、前缀、学到的符号
├── KanbanSyncIndex.json        0600：提醒映射、状态、源引用和哈希
├── Backups/                    0700：反向写入前的源文件备份
└── PruneBackups/               0700：清理删除前的提醒事项备份
```

运行根目录和子目录为 `0700`，状态、配置和备份文件为 `0600`。写入前记录涉及
文件的权限与哈希；写入后逐字节回读。发现私有目录、权限、符号链接、扩展 ACL、
配置或索引异常时整轮失败关闭。

回滚顺序：

1. 停止 watcher，避免回滚过程中再次同步；
2. 用 `--restore-last-prune` 恢复最近实际删除的提醒事项批次；
3. 从 `Backups/` 恢复对应 Vault 源文件，保留原权限并重新计算哈希；
4. 检查 TaskForge 回读后，再运行 `--dry-run` 和 `--prune-dry-run`；
5. 必要时移走私有索引后重新用明确的列表 ID做只读预演，不要手动删除普通提醒。

清理不会删除 TaskForge 源任务。若源身份、符号、回读或权限无法确认，工具宁可
把 Apple 提醒移回当前 TaskForge 状态并拒绝写入。

## 验证与生产门槛

本项目使用可执行测试入口而不是 XCTest 自动发现：

```bash
swift build
swift run TaskForgeReminderCoreTests
swift run TaskForgeReminderCLITests
swift run TaskForgeReminderEventKitTests
```

EventKit 隔离测试默认跳过，只有明确设置环境变量才会访问真实提醒事项：

```bash
TASKFORGE_RUN_EVENTKIT_TESTS=1 swift run TaskForgeReminderEventKitTests
```

生产验收至少包括：专用任务“TaskForge同步状态测试”完成
`待办 → 已计划 → 进行中 → Apple 完成`，再测试 Apple 侧状态移动；watcher 连续
运行至少 61 秒，确认事件、防抖、双扫描、重启恢复和 07:00/11:00/15:00 校准。
生产写入前还必须备份提醒事项迁移数据、私有索引及涉及源文件，并记录权限和哈希。

当前代码不会自动执行权限批准、真实写入或合并 `main`；这些是用户可见的验收门槛。

更多架构和排障说明见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)、
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)、[PRIVACY.md](PRIVACY.md)
和 [SECURITY.md](SECURITY.md)。
