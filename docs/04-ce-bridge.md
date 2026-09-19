# Cheat Engine 工具（本机已构建的 DSH → CE 调用通道）

> **本文件说明本机现状**：Cheat Engine 7.7 装在本机 `<CE_DIR>`，已通过 `main.lua` 引导常驻三条
> agent 调用通道；**DSH 用 PowerShell 直连（最快最强）**，其它 agent 工具用**标准 MCP 服务端**接入。
> 建立日期：2026-09-18。面向本机 DSH agent 与 Codex / Claude Code / OpenCode。
>
> ⚠️ 可对外发布的版本（已去本机路径）是 CE 目录下的 `DSH-CE-Bridge.md`，**两份文档内容同源、用途不同**：
> 本文件给本机用（含真实路径与已验证状态），那份给社区用（占位符路径）。

## 0. 本机速查

| 项 | 值 |
|---|---|
| CE 版本 / 位置 | **Cheat Engine 7.7** @ `<CE_DIR>` |
| CE 启动即加载 | `main.lua` 三段引导：① `openLuaServer('CELUASERVER')` ② `dofile dsh_lib.lua` ③ 等主窗体后 `dofile extras\ceMCP.lua` |
| 通道 1（DSH 首选） | `ce-lua.ps1` → 执行**任意 Lua**（多行），文本回传（命名管道 + CE 官方 `luaclient-x86_64.dll`） |
| 通道 2（DSH 快速） | `ce-mcp.ps1` → **8 个成品工具**，走文件协议，**不需要 Python** |
| 通道 3（给其它 agent） | `mcp\ce_mcp_server.py` → **标准 MCP 服务端**（stdio），配进 Codex / Claude Code / OpenCode |
| CE 侧轮询内核 | `extras\ceMCP.lua`（社区扩展 + 2 处补丁：固定文件路径、自动启动） |
| 文件通道 | `<CE_DIR>\mcp_req.txt` ↔ `mcp_res.txt`（CE 侧 20ms 轮询） |
| 已验证 | 通道 1 ✅、通道 2 ✅、端到端改值 ✅（Tutorial 生命值 1000 → 54321，CE 读回 + `kernel32!ReadProcessMemory` 独立复核一致） |
| 通道 3 实跑 | ✅ **2026-09-18 实测通过**：`initialize` / `tools/list`(8 工具) / `get_modules` / `calc` / `read_memory` / `aob_scan` / 经 MCP 完成的"读→写→读"全部正常；stdout 无非 JSON 污染 |

## 1. DSH 怎么用（本机最常用）

### 1.1 通道 1：任意 Lua（首选）

```powershell
$ce = '<CE_DIR>'

& "$ce\ce-lua.ps1" -Code "return 6*7"                    # => RETURN: 42
& "$ce\ce-lua.ps1" -File .\my.lua                        # 多行/复杂脚本走文件
& "$ce\ce-lua.ps1" -Code "..." -StartCe                  # CE 没开就自动拉起并等管道
```

返回约定：`RETURN: <值>` / `PRINT: <行>`（脚本里 print 的输出）/ `ERROR: ...`（运行时错误，带行号）/ `LOAD ERROR: ...`（语法错误）。

**支持任意多行代码**（内部是"代码写文件 → CE 读文件执行"，完全不涉及转义）。

### 1.2 通道 2：8 个成品工具（不需要 Python）

```powershell
& "$ce\ce-mcp.ps1" -Tool get_modules
& "$ce\ce-mcp.ps1" -Tool read_memory  -Addr 0x100000000 -Type 4 -Hex true
& "$ce\ce-mcp.ps1" -Tool write_memory -Addr 0x144BAF0 -Val 54321 -Type 4
& "$ce\ce-mcp.ps1" -Tool aob_scan    -Aob "E8 03 00 00"
& "$ce\ce-mcp.ps1" -Tool calc        -Expr '0x1000+0x234'
& "$ce\ce-mcp.ps1" -Tool auto_assemble -Script $aaScript      # 多行 AA 脚本
& "$ce\ce-mcp.ps1" -Tool get_address -Expr "Game.exe+0x1234"
& "$ce\ce-mcp.ps1" -Tool disassemble -Addr 0x100001000 -Count 8
```

> 8 个工具都需要 **CE 已附加进程**，否则统一返回 `{"status":"error","message":"CE is not attached to any process."}`。

### 1.3 常见任务配方

**（a）附加进程 + 找值 + 改值（一次跑完，推荐）**

```powershell
& "$ce\ce-lua.ps1" -Code @'
local pid = getProcessIDFromProcessName('Tutorial-x86_64.exe')   -- 换成目标进程名
openProcess(pid)
local hits = AOBScan('E8 03 00 00')            -- int32 1000 的字节模式
local target = nil
for i = 0, math.min(hits.Count - 1, 49) do
  local a = hits[i]
  if readInteger(a) == 1000 then target = a break end
end
if not target then return 'no candidate' end
local before = readInteger(target)
writeInteger(target, 54321)
return string.format('pid=%d addr=%s %d -> %d', pid, target, before, readInteger(target))
'@
```

**（b）只读侦察（最安全的起手式）**

```powershell
& "$ce\ce-mcp.ps1" -Tool get_modules
& "$ce\ce-mcp.ps1" -Tool disassemble -Addr 0x100001000 -Count 8
```

**（c）AOB 特征 + AutoAssembler 注入**

```powershell
& "$ce\ce-mcp.ps1" -Tool aob_scan -Aob "48 8B 05 ?? ?? ?? ?? 48 85 C0"
& "$ce\ce-mcp.ps1" -Tool auto_assemble -Script @'
[ENABLE]
aobscanmodule(INJECT,Tutorial-x86_64.exe,48 8B 05 ?? ?? ?? ??)
alloc(newmem,256)
label(returnhere)
newmem:
  mov [flag],1
  jmp returnhere
INJECT:
  jmp newmem
returnhere:
[DISABLE]
'@
```

### 1.4 状态自检（通道是否还活着）

```powershell
# CE 在跑吗、管道在吗
Get-Process | Where-Object { $_.Path -like '<CE_DIR>\*' } | Select-Object Id,Name
[bool]([IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -ieq '\\.\pipe\CELUASERVER' })

# CE 侧桥接库与 MCP 扩展是否已加载（通道 1 直接问 CE）
& '<CE_DIR>\ce-lua.ps1' -Code "return 'lib='..tostring(type(dsh_eval)=='function')..' mcp='..tostring(type(CEMCP_start)=='function')"

# 手动重启 MCP 轮询（异常时）
& '<CE_DIR>\ce-lua.ps1' -Code "CEMCP_stop() CEMCP_start() return 'mcp restarted'"
```

## 2. 本机文件清单

| 路径 | 角色 |
|---|---|
| `<CE_DIR>\main.lua` | CE 启动引导（三段；原文备份 `main.lua.orig-backup`） |
| `…\dsh_lib.lua` | CE 侧桥接库：`dsh_eval` / `dsh_run_file` / `dsh_out` + `print` 捕获 |
| `…\ce-lua.ps1` | DSH 客户端：任意 Lua（通道 1） |
| `…\ce-mcp.ps1` | DSH 客户端：8 个成品工具（通道 2） |
| `…\mcp\ce_mcp_server.py` | **MCP 服务端**（通道 3，stdio JSON-RPC） |
| `…\extras\ceMCP.lua` | CE 侧轮询内核（社区扩展 + 2 补丁） |
| `…\extras\ceMCP.lua.orig` | 扩展原始副本（对照/回退） |
| `…\extras\ceMCP_config.lua` | 作者原配置（内嵌 Python，本机**不使用**） |
| `…\DSH-CE-Bridge.md` | **社区发布版**文档（去本机路径，内嵌 MCP 服务端代码） |
| `…\dsh_bridge.lua.disabled` | 失败方案留档（TCP REPL：CE 7.7 的 `acceptConnection` 不可用） |
| `…\CheatEngine-Manage.ps1` | CE 安装管理：`Status` / `Sync` / `Migrate` / `Uninstall` |
| `…\languages\ch_cn\` | 简体中文语言包（2017 年版，7.7 缺约 823 条） |
| `…\ceserver\` | CEServer 7.7 跨平台服务端（Android/Linux 目标用） |

## 3. 三条通道怎么选

| 场景 | 用哪条 | 理由 |
|---|---|---|
| 多步逻辑、循环、复杂扫描/复筛 | **通道 1** | CE Lua 全量 API，一次往返 |
| 单点查询/写入 | 通道 2（或其它 agent 的 MCP 工具） | 参数化、返回 JSON |
| Codex / Claude Code / OpenCode 里顺手改 | **通道 3** | 标准 MCP，各自会话内直接调 |
| 需要与其它 agent 完全一致的调用形态 | 通道 3（DSH 侧可用 PowerShell 模拟 MCP 客户端） | 见社区版文档 §3.3 |

⚠️ **并发限制**：通道 2 与 3 共用同一对文件（`mcp_req.txt` / `mcp_res.txt`），**多个 agent 同时调用会互相覆盖请求**——多 agent 场景必须串行。通道 1 走命名管道，不受此限。

## 4. 其它 agent 工具接入（本机配置位置；**尚未写入，仅为方案**）

| 工具 | 配置文件 | 现状 |
|---|---|---|
| **Codex CLI** | `~/.codex/config.toml` | 已有 `[mcp_servers.node_repl]` 样本，字段：`command` / `args` / `startup_timeout_sec` / `[mcp_servers.<名>.env]`；TOML 里 Windows 路径用**单引号** |
| **Claude Code** | `~/.claude/settings.json` | 顶层只有 `env`，**无 MCP 段**；建议用 `claude mcp add` 命令式添加（本机未装 `claude` 可执行文件） |
| **OpenCode** | `~/.config/opencode/opencode.json` | 顶层键 `$schema / provider / model / permission`，**无 `mcp` 段**；按官方字段新增：`type:"local"`、`command:[…]`、`environment:{}`、`enabled`、`timeout` |

三者通用参数：

```
command : C:\Python314\python.exe          （python 绝对路径）
args    : ["<CE_DIR>\mcp\ce_mcp_server.py"]
env     : CE_DIR = <CE_DIR>    （可选 CE_MCP_TIMEOUT = 15）
```

具体配置片段（TOML / JSON / CLI 三种写法）见社区版文档 `<CE_DIR>\DSH-CE-Bridge.md` §5。

## 5. 已验证 / 未验证 / 已知限制

**已验证**

- 通道 1：`return 6*7` → `RETURN: 42`；多行脚本 → `RETURN: 77` + `PRINT: a+b=123`；运行时/语法错误分类回传。
- 通道 2：`calc` → `0x1234`；`get_modules` → Tutorial base `0x100000000`；`aob_scan` → 命中列表；`read_memory` 读模块首 4 字节 → `0x905A4D`（PE 头 `MZ`）。
- 端到端改值：CE 附加 `Tutorial-x86_64.exe`（pid 1560）→ `AOBScan('E8 03 00 00')` 573 命中 → 定位 `015FE560 = 1000` → 写 54321 → CE 读回 54321 → **`kernel32!ReadProcessMemory` 独立复读 54321**。
- 目录迁移自适应性：CE 可以任意搬家（桥按自身位置与 config.yaml 定位，不含硬编码路径），无需改任何东西即用。

**通道 3（MCP）实跑结果（2026-09-18）**

- 通道 3 的 **MCP stdio 往返已实跑**：用 `cmd /c "python ce_mcp_server.py" < req.jsonl` 喂 `initialize` / `tools/list` / `tools/call`，8 个工具全部列出且调用正常；stdout 无协议污染；**全程经 MCP 工具完成一次真实改值**（`aob_scan` 定位 → 读 1000 → 写 54321 → 读 54321），并用独立 `kernel32!ReadProcessMemory` 复核为 54321。
- **`aob_scan` 返回有上限**：实测同一目标用 CE 原生 `AOBScan` 得 573 个命中，而 MCP 的 `aob_scan` 只返回前 20 条 → **需要全量命中时走通道 1**（`ce-lua.ps1` 里自己遍历 `hits`）。

**已知限制（踩坑记录）**

- **CE 7.x 不执行 `autorun\` 脚本**：落盘探针（含 `shellExecute` 绕沙箱）连试 3 次均未执行 → 引导必须挂 `main.lua`。
- **CE 的 Lua `acceptConnection` 拿不到连接**：端口能监听、telnet 能连上，CE 侧恒返回 `nil` → 放弃自建 TCP REPL。
- **官方 `celua.txt` 函数名写错**：实际是 `createSocketServer`，文档写的 `createServerSocket` 不存在。
- 文件通道有 ~20ms 轮询延迟；单请求串行。
- MCP 那 8 个工具表达力有限，复杂逻辑请走通道 1。

## 6. 故障排查

| 症状 | 处理 |
|---|---|
| `CE 的 LuaServer 管道 'CELUASERVER' 不存在` | 启动 CE（或 `ce-lua.ps1 -StartCe`）；确认 `main.lua` 里 `openLuaServer` 那行没被注释 |
| 工具返回 `CE is not attached to any process.` | 先在 CE 里附加进程，或通道 1 执行 `openProcess(getProcessIDFromProcessName('x.exe'))` |
| 通道 2/3 响应超时 | 通道 1 执行 `return type(CEMCP_start)=='function'` 检查；必要时 `CEMCP_stop() CEMCP_start()`；核对 `CE_DIR` |
| CE 启动后 CPU 偏高 | 确认没有遗留的 socket 轮询脚本（`dsh_bridge.lua` 应为 `.disabled`） |
| 改了 `main.lua` 后 CE 异常 | 用 `main.lua.orig-backup` 还原 |

## 7. 安全与开关

- `openLuaServer('CELUASERVER')` 是**无认证的本机命名管道**：本机任何进程都能让 CE 执行任意 Lua（= CE 的全部权限）。仅限本机自用。
- **临时关闭**：注释 `main.lua` 里 `pcall(function() openLuaServer('CELUASERVER') end)` → 重启 CE。
- **彻底移除**：删 `dsh_lib.lua` / `ce-lua.ps1` / `ce-mcp.ps1` / `mcp\` / `extras\`，并用 `main.lua.orig-backup` 还原 `main.lua`。
- **写值必须回读**；`auto_assemble` 会真的注入代码，先只读侦察。
- CE 目录整体搬迁后**无需改任何配置**（脚本用 `$PSCommandPath` / `getCheatEngineDir()` 自定位）；搬迁走 `CheatEngine-Manage.ps1 -Action Migrate -TargetDir <新路径> -Force`（注册表、快捷方式、卸载入口会一起同步）。

## 8. 实战记录：在真实游戏里定位 SAN 值（2026-09-18，跨会话）

目标：`<GAMES_DIR>\2026-6\パンドラメイズ260427`（`Pandora.exe`，Unity），界面上 SAN 显示 84%。

**跨会话结论：完全可用**。DSH 在 Session 0，CE 在用户桌面会话（Session 1）；`ce-lua.ps1` 直接连上并执行 Lua
（`RETURN: cross-session OK`），`openProcess(getProcessIDFromProcessName('Pandora.exe'))` 正常附加，
`createMemScan` / `createFoundList` 全部可用，单次往返约 0.2～3 秒。

### 定位流程（可复用的"两次筛选法"）

1. **初扫**：先限定私有内存，再按多种"假设表示"分别扫描并**保留 memscan 对象**（本机存进 `_G.dsh_scans`）：
   `float 0.89`｜`float 89`｜`double 89`｜`dword 89`｜`dword 890`｜`dword 8900`
2. **让玩家改变数值**（84% → 100%），对每组执行 `ScanOption = soChanged` 的 **next scan**（只保留"值变了"的地址）
3. 再加一条条件：**当前值 == 满值对应值**（`1.0` / `100` / `1000` / `10000`）→ 收敛到 3 个候选
4. **写入测试**（写 50）→ 玩家看界面确认 → 命中

结果：`1AFE3EABEF8`，**类型是 `dword` 百分比**（不是浮点归一化）。其周围是属性数组：`100,100,100,50,30,0,23,1,54,...`

### 本次踩到的坑（都已在实测中撞到并解决）

| 坑 | 现象 | 正解 |
|---|---|---|
| 用"0~1 浮点紧跟 1.0"当特征 | 筛出的 8 个"副本"值全是 `0.839216`，其实是 **214/255 颜色分量**；`nvwgf2umx.dll`（NVIDIA 驱动）里同样模式命中 5 次 | **不要用模式猜测**，改用两次筛选 |
| 忽略"副本必须一致" | 第二轮 6 个候选值各异（0.887~0.893，UI/渲染近似值） | 真值的多份副本会**完全一致**，不一致即可排除 |
| 没排除 DLL/mapped 内存 | 命中大量驱动与渲染数据 | 扫描前 `setSpecialScanOptionsOverride({MEM_PRIVATE=true, MEM_IMAGE=false, MEM_MAPPED=false})` |
| 删除地址列表记录 | `AddressList` 上**没有** `removeRecord` / `deleteRecord` / `delete`（调用 nil 报错，`pcall` 静默吞掉） | 用 **`memoryrecord:delete()`**（对象自删），逐个删 |
| CE 记录描述用中文 | `string.find(desc,'SAN候选')` 匹配不上（编码不一致） | 记录名与匹配关键字**一律用 ASCII** |
| Lua `string.format` 里裸写 `%` | `invalid option '%~'` / `bad argument #6 to 'format'` | 字面百分号写 `%%`，或干脆别用 `format` |
| 非对齐命中 | `dword 8900` 剩余候选值很怪（`4213047228`/`0`），地址尾数非 4 的倍数 | 按类型对齐扫描，拒绝非对齐命中 |

### 地址易失性（重要）

`1AFE3EABEF8` 是本次运行的**堆地址**，游戏重启即失效。要长期使用必须做 **pointer scan**（得到
「模块基址 + 偏移链」），或改用 CE 的 Mono/IL2CPP 字段定位。`ce-lua.ps1` 里可用 `getAddress`、
`AOBScan` 配合指针表达式来固化。