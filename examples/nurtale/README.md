# 样板：`Nurtale Nesche`（Unity Mono，实例字段型 + 无静态单例 + 调托管方法）

> 数据形态：**实例字段型 + 没有任何静态单例**，且部分数值**必须调用游戏方法**才能改。
> 建立：2026-09-20。这是目前三个样板里**最复杂**的一个，覆盖了前两个没覆盖的情况。

## 为什么单独留这份样板

| 样板 | 覆盖的形态 | 本样板补上的能力 |
|---|---|---|
| `pandora` | 静态字段型（JIT 内联绝对地址） | — |
| `iyohaku` | 实例字段型，**有** `GameManager.Instance` 静态单例 | — |
| **`nurtale`** | 实例字段型，**没有任何静态字段持有数据** | ★ **UI 管理器单例兜底路径** |
| | | ★ **`mono_invoke_method` 调用托管方法改状态** |
| | | ★ **管道健康检查**（防崩溃） |
| | | ★ **「写字段 UI 不动」的识别与解法** |

**新项目如果发现"扫遍静态字段都找不到数据"或"写字段界面没反应"，直接照这份改。**

## 文件

| 文件 | 说明 |
|---|---|
| `stable.CT` | CE 表：10 个数值条目 + LuaScript（内嵌小面板 + 异常状态区） |
| `stable.lua` | 异常状态模块独立版（供 CE 直接 `dofile` 调试） |

## 定位链（跨重启验证通过）

```
GUIHUDManager.instance                     ★ 静态字段 @ offset 0（唯一稳定锚点）
  +0x28  healthGUI    → HealthCanvasManager
           +0x20  health → Health
                    +0x60  maxHealth / +0x64 healthCap / +0x68 currentHealth
                    +0x6C  maxStamina / +0x70 staminaCap / +0x74 currentStamina
                    +0x78  staminaRestoreAmount    ← 体力恢复速度
                    +0x88  IsUnDamagable           ← 无敌
  +0x50  arouseGaugeManager → ArouseGaugeManager

Health --(搜指向它的指针)--> PlayerHealthManager --(+0xD8)--> Player
Player +0x168 → StatusEffectManager
         +0x68 → ProgressiveStatusFamilyService     ← 三个异常状态家族
         +0x80 → _whole  / +0x88 → _active           （托管字典，只读遍历）
Player +0x1B8 → PlayerSexualArousalManager
         （继承 CaptiveSexualHeatManager → SexualHeatManager）
         +0x40 → _heat                              ← 性快感真源
```

## 三条关键经验（细节见 docs/）

### 1. 没有静态单例时，走 UI 管理器兜底

见 `docs/01-mono-recon.md` §2.5「情况 C」与 `docs/02-stable-address.md` §10.1.1。

**排查顺序**：① 静态单例 → ② 全程序集扫静态字段确认没有 →
③ **UI 管理器单例 → 子管理器 → 数据对象** → ④ 指针反查 → ⑤ 才用 AOB。

> **不要优先用 AOB**：实测 AOB 依赖游戏数据里的**具体数值**（`maxHealth=35` 等），
> 玩家一升级（35→39）就失配；而字段引用与数值无关。

### 2. 有些数值光写字段改不动 —— 要调方法

见 `docs/01-mono-recon.md` §8.6。

**症状**：回读值确实变了，但**界面不刷新**，且游戏下次更新就覆盖回来。
**原因**：那个字段只是**显示副本**，UI 靠**事件通知**刷新；真源往往在**父类**里
（`enumFields` / `enumMethods` **只列本类声明的成员，看不到继承的**）。

**本案例**：`ArouseGaugeManager.currentarouse` 是副本 →
真源是父类 `SexualHeatManager._heat` → 调 `SexualHeatManager.Set(v)` 后数据与 UI 同时同步。

### 3. 调托管方法前必须检查管道健康

见 `docs/01-mono-recon.md` §8.4 / §8.5。

`mono_invoke_method` 走**每线程命名管道**，管道失效时继续调用会**让目标进程崩溃**。
配套规矩：

- 调用前 `pipeOK()` 自检（检查 `libmono.monopipes[threadId].Connected` 与 `MDC_ShuttingDownAddress`）
- **一次只做一个操作**，不在一个脚本里连调多个托管方法
- 循环时**每步之间**复查管道
- 周期调用**间隔 ≥200ms** 并做同值限流
- **绝不手工改托管容器的内部结构**（`Dictionary` 的 entries/buckets/count）—— 实测会崩

## 本案例踩过的其他坑（都在 docs 的坑位表里）

| 坑 | 一句话 |
|---|---|
| Lua `local` 作用域 | 共享变量必须声明在脚本最前面；用 `src/check_lua_scope.py` 自查 |
| AOB 依赖具体数值 | 改用「类名 + 字段偏移」 |
| `getScreenWidth()` / `MainForm.Width` 都不可靠 | 面板宽度由内容决定 + 固定上限 + 名字列保底 |
| XML 里裸 `<` / `&` | 会让 LuaScript **静默不执行**；条件写 `>` 形式，位运算改取模 |
| `mono_class_findInstancesOfClass` 返回 nil | 采集器状态不健康时静默失败，重新注入再试 |
| `mono_object_getClass` 假阳性 | 对任意地址都返回字符串，必须严格校验类名 |

## 锁定功能的两条关键经验（本项目实测代价最大）

### 1. 锁定只能有一个入口

本项目一度同时提供两个性快感锁定入口：行内 `□` 按钮（设 `LOCKS.Arouse`）与
底部「快感锁定50%」按钮（设 `AROUSE_LOCK`）。结果：

- 用**行内 `□`** 锁定时，通用重设循环用**写内存**的方式处理它 ——
  而性快感**必须调 `Set()` 方法**才有效 → **看起来锁了、实际没锁**
- 前者设的变量在后者路径里不被识别 → **两条路各自为政**

**结论**：锁定只保留**每个数值条目自己的按钮**这一个入口；
底部快捷区**只放一次性动作**。已作为模板约定写进
`docs/03-standalone-trainer.md` §4.5.1。

### 2. 需要"调方法"的数值要排除出通用写内存循环

```lua
for i = 1, #WANT do
  local k = WANT[i].key
  -- ★ 必须排除！否则通用循环会把无效的写操作当成"已在处理"
  if k ~= 'Arouse' and LOCKS[k] and ADDR[k] and LOCKVAL[k] then
    ...通用写内存...
  end
end
-- 该项走自己的正规重设路径
if LOCKS.Arouse and LOCKVAL.Arouse then setArouse(LOCKVAL.Arouse) end
```

### 3. 定时器线程的管道问题

CE 的**定时器回调可能跑在没有 Mono 管道的线程**上。
早期 `pipeOK()` 是"没管道就返回 false"，导致**定时器里的周期重设永远静默失败** ——
而手动点按钮（另一线程）却正常。

**正解**：`pipeOK()` 发现本线程无管道时**主动调 `getMonoPipe()` 建立**，
断线时销毁重建。详见 `docs/01-mono-recon.md` §8.4。
