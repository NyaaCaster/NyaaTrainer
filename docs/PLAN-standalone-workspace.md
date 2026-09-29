# NyaaTrainer 独立 Agent 工作区改造计划（SSOT）

> **状态：⏸ 待审核（用户审核通过前不动工）**
> 本文件是本次改造的唯一进度跟踪文档（SSOT）。每个任务前的标记：`⬜ 待办` / `🔄 进行中` / `✅ 完成` / `⛔ 阻塞`。
> 审核意见请直接追加到「§8 决策记录」。开工后本文件随进度更新标记，完工后作为改造复盘归档。

**创建**：2026-09-30 ｜ **改造负责人**：Agent ｜ **决策人**：用户

---

## 0. 目标与非目标

### 目标（用户原话转译）

任何 agent 工具（cc / codex / zcode / opencode / dsh 等）通过**一句指令**：

> 「从 https://github.com/NyaaTrainer/NyaaTrainer.git 安装 NyaaTrainer 项目」（以实际仓库 URL 为准）

即可完成：agent 询问用户拉取到本地哪个目录（若用户没说，就问）→ `git clone` → **bootstrap 一律自主下载 CE 与部署引导**（不问用户是否已装 CE，见 §2 修订1）→ 三条通道 + `make_trainer.py` 生成器全部可用，**不依赖用户任何预装软件**（PowerShell 除外，Windows x64 自带）。

### 非目标

- 不支持 Linux / macOS / ARM：全是 Windows x64 API（UpdateResourceW、命名管道、PE 资源）。
- 不做 agent 工具各自的客户端安装脚本（cc/codex 的 MCP 登记方式只写文档示例，不做自动化）。
- 不改变既有方法论（docs/01~04）与 SOP；只改「安装与环境」层。

---

## 1. 背景事实（调研已完成，写死进计划，不再重问）

| # | 事实 | 证据 |
|---|---|---|
| F1 | 「从 CE 上游源码拆 MCP 最小合集」物理不成立：三条通道的执行体都是完整 CE 主程序；`make_trainer.py` 依赖的 `.cepack` 模板是构建产物，源码仓库里不存在 | 本轮调研（源码目录树 + G:\game CE 实物） |
| F2 | CE 官方安装器 = Inno Setup，`7z x CheatEngine77.exe` 可解开完整文件树（免装、免注册表、免驱动） | AGENTS.md 工作区总纲实测（2026-09-14）；G 盘样本佐证 |
| F3 | 本项目方法论**全部用户态**，MonoDataCollector{32,64}.dll 注入用户可做，不依赖 dbk 内核驱动 | docs/01 全流程；G 盘 7.7 无驱动实际用 |
| F4 | 三个 Python 脚本只用标准库，无 pip 第三方包 | grep `import` 全量核验 |
| F5 | ceMCP.lua 只存在于本机 `G:\game\Cheat Engine\extras\`，**当前 GitHub 仓库没有** | 仓库文件清单 |
| F6 | G 盘 ceMCP.lua 已含 2 处补丁（文件路径固定 + 自动启动） | D:\Hgame\NyaaTrainer\docs\04-ce-bridge.md §2 |
| F7 | CE 上游 GitHub 只有 7.5 tag、release assets 空；7.7 二进制仅在官网 | GitHub API（2026-09-30 实测） |
| F8 | NyaaTrainer 三个通道指向 CE 的脚本，现有版本全用「本脚本所在目录」自定位 | `src/ce-lua.ps1`、`src/ce-mcp.ps1` 读取验证 |

## 2. 已拍板事项（用户确认，含本轮修订）

| Q | 拍板 | 备注 |
|---|---|---|
| Q1 路线 | **方案 A：runtime 自装配** | 下载 CE 7.7 安装包 → 7z 免安装解压到 `runtime/ce/CE` → 部署引导 → 自检 |
| Q1 修订-a | **不依赖用户已装 CE**：一律走下载解压（版本不可控风险规避）；安装包解压后**自动删除** | 不再询问用户 CE 路径 |
| Q1 修订-b | **所有外网下载前先做连通性探测**，失败/超时 → 提示用户「请开启翻墙软件后重试」 | 见 §5 下载源表 |
| Q2 CE 落地 | **7z 免安装解压**（不用 `/VERYSILENT` 静默安装） | 解压后无需配置，路径由脚本自定位 |
| Q2.1 ceMCP.lua | **用户下载服务器分发**，不走论坛下载+打补丁。**URL 待用户提供后填入 §5**（占位 `<用户服务器URL>`） | 补丁版绝对路径：`G:\game\Cheat Engine\extras\ceMCP.lua` |
| Q2.2 失败留档 | **直接删 `lua/dsh_bridge.lua.failed`**，同步清理所有文档对它的引用 | docs/04 两处、AGENT.md(→AGENTS.md) 无引用但需确认 |
| Q3 Python | **内嵌 Python 3.12 embeddable zip**（纯文件解压即用）到 `runtime/tools/python/` | 用户指定 ComfyUI python_embeded 同思路 |

用户追加指令：**`AGENT.md` 改名 `AGENTS.md`**（通用规范命名，多维 agent 工具通吃该名）。
CE 7.7 下载+解压的实测放在阶段 C 一并验证（先动代码骨架，装配验证合并做）。

## 3. 目录方案（目标态）

```
NyaaTrainer/
├── AGENTS.md                ★ AGENT.md 改名（内容同步改，见 §4-B）
├── README.md / USAGE.md     # 同步改安装章节
├── LICENSE                  # MIT 保留（不引入 GPL 源码进仓库本体）
├── config.example.yaml      # 重写：去掉 paths.cheat_engine / games_root（见 §4-A.4）
├── .gitignore               # 追加 runtime/ 相关忽略
├── docs/
│   ├── 01~04 方法论四份     # 不动方法论，只改路径类引用（AGENT.md→AGENTS.md、lua/dsh_*→bootstrap/）
│   ├── PLAN-standalone-workspace.md   # ← 本文件（改造完归档）
│   └── history/             # （可选）dsh_bridge.lua.failed 移进此处或直接删 —— Q2.2 已拍板：直接删
│
├── bootstrap/                  # ★ 新增：引导原料（进仓库，都是 agent 可读文本）
│   ├── main_boot.lua              # 由 G 盘 main.lua 提取的三段引导（openLuaServer/dsh_lib/ceMCP timer）
│   ├── dsh_lib.lua                # ← 现 lua/dsh_lib.lua 移动过来
│   ├── dsh_stable.lua             # ← 现 lua/dsh_stable.lua 移动过来
│   ├── ceMCP.lua                  # ← 新增（用户服务器下载入库，已含 2 处补丁）
│   └── THIRD_PARTY.md             # Cheat Engine 来源、版本、许可与免责声明
│
├── runtime/
│   ├── bootstrap.ps1           # ★ 新增：装配器（下载→解压→部署→自检→清理安装包）
│   ├── ce/                     # CE 解压目录（装配后产生；gitignore，不进仓库）
│   │   └── Cheat Engine/       # <CE_DIR>
│   └── tools/
│       └── python/             # ★ 内嵌 Python 3.12 embeddable（put 15MB，解压即用）
│
├── src/                        # 现有脚本，全部轻改（见 §4-A）
│   ├── ce-lua.ps1     （改 CeDir 默认 → runtime/ce/Cheat Engine）
│   ├── ce-mcp.ps1     （同上）
│   ├── ce_mcp_server.py （改 _resolve_ce_dir 加 runtime 分支）
│   ├── make_trainer.py  （--ce-dir 默认改 runtime 路径）
│   ├── check_lua_scope.py（不动）
│   └── CheatEngine-Manage.ps1（保留但降级为可选维护工具；不再作为装配路径）
│
├── skills/                     # 不动（ce-stable-address / ce-standalone-trainer）
└── examples/                   # 不动（已验证无硬编码路径）
```

### `.gitignore` 追加

```gitignore
# runtime 装配后产生的 CE 副本 + 临时安装包 + 下载缓存
runtime/ce/
runtime/downloads/
*.exe.tmp
 bzw gewöhnlich  runtime 下这几个路径整体忽略即可
```

（实际写时以清晰为准：`runtime/ce/` 与 `runtime/downloads/` 整目录忽略，`runtime/tools/python/` **不忽略**——它是内嵌的。）

## 4. 任务分解（含验收判据）

> 实施顺序：先 A（代码/物料）→ B（文档）→ C（装配验证，含真实下载）→ D（收尾）。
> CE 7.7 下载+解压实机验证合并到 C（用户拍板：正式工作验证中一起测试）。

### §4-A 代码与物料改造

- ✅ **A1** `bootstrap/` 目录建立（2026-09-30）：
  - `main_boot.lua`（从 G 盘 main.lua 的 DSH 三段引导提取，标记对 `--==== NyaaTrainer bootstrap`)
  - `dsh_lib.lua` / `dsh_stable.lua`（`git mv` 自 `lua/`，保留历史）
  - `THIRD_PARTY.md`（CE 7.7 / Python embeddable / ceMCP topic 623995 来源与许可）
- ✅ **A2** `lua/dsh_bridge.lua.failed` 已删（`git rm`，2026-09-30）。
- ✅ **A3** `bootstrap/ceMCP.lua + .sha256` 入库：来源=用户服务器 `https://h.nyaa.host:5245/sd/kgjhJnTI/`，SHA256 `ace987049e7aafb510018ab1c8a2036334af196e718ec8cf3eb209c21831ec2d`（与 G 盘部署版逐位一致，已核）。
- ✅ **A4** `runtime/bootstrap.ps1`（语法解析通过；功能验证在阶段 C）。
- ✅ **A5** `src/ce-lua.ps1` / `src/ce-mcp.ps1`：`CeDir` 默认改 `<repo>\runtime\ce\Cheat Engine`（两级上溯），`-CeDir` 保留覆盖。
- ✅ **A6** `src/ce_mcp_server.py`：`_resolve_ce_dir()` 增加 runtime 分支（env > runtime > legacy 父目录），docstring 同步。
- ✅ **A7** `src/make_trainer.py`：`--ce-dir` 默认改 `_default_ce_dir()`（runtime 优先，legacy 回退）。
- ✅ **A8** `src/CheatEngine-Manage.ps1`：AGENTS.md §2 索引行标注 legacy 定位（脚本本体不动，PLAN 定的方案）。
- ✅ **A9** `runtime/tools/python/`：Python 3.12.10 embeddable 官方包，22MB 入库；ctypes/wintypes/py_compile 全验证通过。
- ✅ **A10** `config.example.yaml` 重写：删 `paths.cheat_engine`/`games_root`；`games[]` 降为可选注释示例；登记 bootstrap 获取方式。
- ✅ **A11** `AGENT.md` → `AGENTS.md`（`git mv`）+ §0 重写（runtime 就绪判定 + bootstrap 流程 + 不接用户预装 CE）+ §9 重写（5 项依赖表 + 翻墙提示原则）。

### 验收判据 A（ Commit 前）

- [ ] `git ls-files` 里 `bootstrap/` 有四个文件（含 ceMCP.lua，非空且头几行含 `-- Added by NyaaTrainer / DSH` 的注释）
- [ ] `src/ce-lua.ps1 -Code "return 42"`（无 -CeDir 参数）在 `runtime/ce/Cheat Engine` 存在时**按新默认路径找 CE**
- [ ] 上两项都过 → A 完成，标 ✅

### §4-B 文档同步

受影响文件（引用 `AGENT.md` / `lua/dsh_*` / `dsh_bridge` 已 grep 清点）：

- ✅ **B1** `README.md`：`AGENT.md` 引用 → `AGENTS.md`；目录结构图加 `bootstrap/`、`runtime/`；安装章节改为 bootstrap 流程。
- ✅ **B2** `USAGE.md`：
  - 7 处 `AGENT.md` → `AGENTS.md`；
  - 目录树结构段落（第 183 行附近）同步新布局；
  - 第 4 章「安装」重写：不装本地 CE，走 runtime/bootstrap.ps1；
  - `docs/04` 提及的 `dsh_bridge.lua.disabled` 行删除，注释同步（Q2.2）。
- ✅ **B3** `docs/02-stable-address.md`:10 引用 `lua/dsh_stable.lua` → `bootstrap/dsh_stable.lua`。
- ✅ **B4** `docs/04-ce-bridge.md`：
  - `<CE_DIR>` 概念改为「`<repo>/runtime/ce/Cheat Engine`（bootstrap 装配产生）」；
  - 二处 `dsh_bridge` 引用删除（第 129 行条目、第 192 行排查行）；
  - §5「已验证/未验证」不变，注明本机现状（G 盘 CE）属于 legacy 部署，新装机器走 bootstrap。
- ✅ **B5** `.gitignore` 追加 runtime 忽略项（§3 已列）。
- ⬜ **B6** 本文件（PLAN）归档时的新路径引用 / 「AGENTS.md」命名转发（防止外部 agent 老的文件名引用找不到）。

### §4-C 装配与端到端验证（真人操作 + agent 检查）

- ✅ **C1**（用户服务器 URL: https://h.nyaa.host:5245/sd/yAwpTSjT/ + SHA256 1cd9a83e…，7z 格式含一层目录） 用户给出服务器 ceMCP.lua URL → 填入 §5 并 commit 到 `bootstrap/`。
- ✅ **C2**（2026-09-30 本体仓库实跑：下载 14.7MB → SHA256 白名单 → 7z 解压 → 目录归一 → 引导一致化 → 18 项自检全绿） 在一台**无现有 CE 环境**的路径（或临时 `$env:TEMP\nt_test`）验证 `bootstrap.ps1` 全流程：连通性探测 → 下载 CE 7.7 → 7z 解压 → 部署引导 → 删安装包 → 三通道自检全绿。
- ✅ **C3**（三通道默认路径全绿：42/引导态/get_modules/MCP stdio 四步） 三通道各自实测（对 Tutorial 目标进程）：
  - `ce-lua.ps1 -Code "return 6*7"` → `RETURN: 42`
  - `ce-mcp.ps1 -Tool get_modules` 有 JSON 返回
  - `python ce_mcp_server.py` stdio 至少 `initialize` + `tools/list` 通
- ⬜ **C4** `make_trainer.py` 用 `examples/pandora/stable.CT` 出一个独立 exe，双击弹面板可改值（G 盘 Pandora 游戏）。
- ✅ **C5**（downloads/ 用后即删已验证为空） 安装包清理验证：`runtime/downloads/` 空。
- ⬜ **C6** 修改器 exe 在用户桌面双击可用（Solar 替换/改值/锁定都到位）。

### §4-D DSH 工作区联动（改完 A/B/C 后）

- ✅ **D1** `D:\Hgame\AGENTS.md`（工作区总纲）NyaaTrainer 行：路径引用 `AGENT.md` → `AGENTS.md`，加一句「独立工作区已自带 runtime；CE 路径不再需要 NYAA_TRAINER_CE_DIR」。
- ✅ **D2** AGENTS.md（NyaaTrainer 内）§9 外部工具来源改写。

## 5. 外网下载源与翻墙清单（bootstrap 依赖的完备集合）

| # | 用途 | URL | 翻墙风险 | bootstrap 行为 |
|---|---|---|---|---|
| 1 | CE 7.7 安装包 | `https://ilmnoise-cheatengine.org/dl/CheatEngine77.exe`（官方） | **大概率要代理** | 连通性探测 → 失败提示「开翻墙后重试」；重试 3 次 |
| 2 | ceMCP.lua | `<用户服务器URL>`（补丁版，含 hash 校验） | 用户服务器，通常无 | 直连；hash 校验失败报错退出 |
| 3 | Python 3.12 embeddable | `https://www.python.org/ftp/python/…/python-3.12.*-embed-amd64.zip` | 直连可用但偶发不稳 | 探测 → 失败提示翻墙；重试 3 次 |
| 4 | 7-Zip（如新机无） | `https://www.7-zip.org/a/7z2409-extra.7z` | 同 3 | 仅系统无 7z 才触发提示；用完自动清 |
| 5 | Git clone 仓库 | GitHub | 国内普遍要 | 交给上层 agent 提示 |

**网络探测规则**：对每个外网下载，先 `Invoke-WebRequest -Method Head` 5 秒超时；失败再现 2 次；三次失败统一报错「该站点在国内网络环境下可能需要翻墙，请开启后重新运行 bootstrap.ps1」。

## 6. 风险与回滚

| 风险 | 缓解 |
|---|---|
| CE 官网 URL 变动（ilmnoise-cheatengine.org 域名不是永久） | bootstrap 支持从本地目录 `$env:NYAA_TRAINER_CE_PKG` 或命令行 `-CePackage <path>` 注入已下载包 → 不联网也能装配 |
| Python embeddable zip 内没有 pip / venv 支持 | 本方案**不需要**（脚本纯_stdlib）；若未来引入第三方包依赖，再补 get-pip 步骤 |
| `7z x CheatEngine77.exe` 解压出的文件树与 G 盘样本不完全一致（未知 build 差异） | C2 阶段做**文件级对比**（md5 关键 5 件套），差异记录进本文件 §7 |
| `main.lua` 是官方文件、直接 append 引导段会被 CE 从新版本 main.lua 覆盖 | bootstrap 采用「读原文件 → append 引导段 → 写回」，**先备份 `.orig-backup`**（沿用仓库既有硬规矩） |
| `.cepack → .dat` 转换需要写权限在 `<CE_DIR>`；若用户把 repo 放只读路径 | bootstrap 检测可写性，不可写就提示换位置 |
| GPL-2.0 传染（CE 二进制再分发 Clar） | 本方案 A 不 vendor CE；用户自己下载 → **许可证无传染**，仓库保持 MIT |
| cx_Freeze / 杀软对 `runtime/tools/python/python.exe` 误报 | 概率低（官方 embeddable），若遇再评估 md5 白名单 |

**回滚**：一套 `git reset --hard <改造前commit>`；`runtime/` 与 `bootstrap/` 目录还未 git 内成型前属于 _work 范畴，删除即回滚。本机 G 盘 CE 是 legacy 独立部署，改造不碰它，无回滚需求。

## 7. 施工边界（AGENT 说明）

- 本文件审核通过前，任何文件**不动**（含 `git mv` 这类看似无损的改动也不能做）。
- 施工过程中涉及「用户在用的程序」（用户正跑着的 G 盘 CE、游戏）**不许动**（沿用仓库硬规矩第 3、10 条）。
- 施工全周期用简体中文与用户交流；产物文件/代码注释按仓库现状（中文为主，部分英文 signature `Nyaa be with you.`）。

## 8. 决策记录（APPEND ONLY）

- 2026-09-30 初次制定：Q1=A（方案 A: 自装配）、Q2=7z 免安装、Q2.1=原版+补丁、Q2.2=删 .failed、Q3=Python embeddable 内嵌、AGENTS.md 通用命名。
- 2026-09-30 修订：
  1. 「是否已装 CE」分支整体**删除**（用户修订 1），一律走下载解压。
  2. ceMCP.lua 来源改为**用户提供的服务器 URL**（用户修订 2），论坛直链方案取消。补丁版绝对路径已确认：`G:\game\Cheat Engine\extras\ceMCP.lua`。
- 2026-09-30 中文语言包顺手修正（用户要求）：ch_cn/cheatengine-x86_64.po 中 3 组 `msgid "Cheat Engine 6.7"` 的 **msgstr 译文改为 "Cheat Engine 7.7"**（msgid 保留不动——它必须与 7.7 源码遗留字面量精确匹配才能命中；VersionCheck.po 为 %s 占位符无需改）。修正前备份 `.orig-backup`；纯净包与 G:\game\Cheat Engine 原部署双份同步。引擎自报 getCEVersion()=7.7 复验不变，语言包加载无报错。
- 2026-09-30 版本显示澄清（用户不再深究）：纯净包 CE 引擎自报 getCEVersion()=7.7（PE 资源 7.7.0.10621 一致），三通道/mono/make_trainer 全部正常；"6.7" 系 2017 年中文语言包 ch_cn/cheatengine-x86_64.po 的陈旧 UI 字符串（mainunit2.cename 段，6 处），纯显示不影响 agent 调用，纯净包与源逐字节一致未做改动。
- 2026-09-30 事故与再拍板：
  1. **事故**：CE 官网 downloads 页的 Windows 直链实为 ReasonLabs/Razer 多产品捆绑投放器（静默执行装出 RAV Endpoint Protection + Razer Axon + 真 CE 7.7 三件），已全部清理干净（服务/进程/目录/卸载表/计划任务全绿）。教训写死进 bootstrap.ps1：**未经内容验证的 URL 一律不入库、一律不执行；永不执行安装器，只解压已校验 zip**。
  2. **ceMCP 内嵌拍板（用户）**：纯净便携包直接内嵌补丁版 extras\ceMCP.lua，服务器不再单独提供 ceMCP.lua 下载；bootstrap\ceMCP.lua 保留为仓库对照/修复源。
  3. **分发物形态（用户）**：CE 7.7 纯净便携 zip（从已验证的 G:\game\Cheat Engine 中文补丁版构建，72MB/347 文件，含引导三件+ceMCP，开箱即用），放用户服务器；bootstrap 改为「下载 zip → SHA256 白名单校验 → Expand-Archive 解压即成品」。
  4. 纯净包验证全绿：17 项关键件 + license + 三通道（42/引导态/get_modules/calc/MCP stdio 四步）+ make_trainer 冒烟（pandora 表 → 10.4MB exe 产出正常）。
- 2026-09-30 追加确认（本轮）：**下载清单翻墙审查完成**，CE 官网安装包 +（新机器时的）7-Zip 是唯二「大概率需翻墙」项；ceMCP.lua 走用户服务器、Python 走 python.org 直连皆可用，bootstrap 统一前置连通性探测 + 明确提示。

---

*本文件为 NyaaTrainer 仓库 ssent 施工计划的唯一 SSOT。完成后此文件移入 `docs/history/`。*
