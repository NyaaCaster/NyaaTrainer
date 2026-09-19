--[[
  nn_status.lua — 三个异常状态（服从/淫乱/受虐倾向）的读取与修改  [v2 安全版]

  ================== v2 相比 v1 的改动（重要） ==================

  v1 崩溃过两次：
    ① 手工改托管 Dictionary 内部结构（写 entries / _count / buckets 链表）
       -> 哈希表不一致，游戏崩溃。**这个手段已彻底废弃，本文件不再出现。**
    ② 在 Mono 管道已失效的情况下连续调用 3 次 Deactivate
       -> 带病操作，游戏崩溃。

  从 CE 源码（autorun/monoscript.lua）读到的关键机制：

    function getMonoPipe()
      local tid = getCurrentThreadID()
      local result = libmono.monopipes[tid]     -- ★ 管道是按【线程 ID】缓存的
      if result and (result.Connected == false) then
        result.destroy(); libmono.monopipes[tid] = nil; result = nil
      end

    以及开头：
      if readInteger(libmono.MDC_ShuttingDownAddress) ~= 0 then
        return nil                              -- 采集器正在关闭 -> 一律不调用
      end

  所以 v2 的三条硬规矩：
    A. **每次调用托管方法前，先确保管道健康**（本线程管道存在且 Connected）
    B. **一次只做一件事**，不在一个脚本里连续调用多个托管方法
    C. **管道不健康就拒绝调用**，宁可失败也不带病操作

  ================== 可用方法（签名来自 mono_method_get_parameters 实测） ==================

    ProgressiveStatusFamilyService:
      TrySetLevel(familyId, level)      -- ★ 已验证安全，三个家族都成功
      TryActivateLevel(statusId)
      TryUpgrade / TryDowngrade(familyId)
      TryGetActive(familyId)
      DowngradeAllActiveFamilies()

    StatusEffectManager:
      ForceActivate(id) / Deactivate(id) / ContainsActiveId(id) / IsActive(id)
      -- ⚠️ Deactivate 在管道不健康时会崩，v2 默认不用它

  ================== 定位链（已稳定验证，跨重启有效） ==================

    GUIHUDManager.instance  (静态字段 @ offset 0)
      + healthGUI -> HealthCanvasManager
      + health    -> Health
    Health --(搜指向它的指针)--> PlayerHealthManager --(+0xD8)--> Player
    Player +0x168 -> StatusEffectManager
    StatusEffectManager +0x68 -> ProgressiveStatusFamilyService

  Nyaa be with you.
]]

local M = {}

M.VERSION = 'v2-safe'

-- ============ 管道健康检查（v2 核心） ============

-- 返回 true 表示当前线程的 mono 管道可用
function M.pipeOK()
  if type(libmono) ~= 'table' then return false, 'libmono 不存在' end
  if libmono.abort then return false, 'libmono.abort 已置位' end
  -- 采集器正在关闭 -> 一律不调用
  if libmono.MDC_ShuttingDownAddress then
    local sd = readInteger(libmono.MDC_ShuttingDownAddress)
    if sd == nil or sd ~= 0 then return false, 'MDC_ShuttingDown' end
  end
  local pipes = libmono.monopipes
  if type(pipes) ~= 'table' then return false, 'monopipes 不存在' end
  local tid = getCurrentThreadID()
  local p = pipes[tid]
  if p == nil then return false, '本线程无管道 (tid=' .. tostring(tid) .. ')' end
  if p.Connected == false then return false, '管道未连接' end
  if libmono.monopipe == nil then return false, 'libmono.monopipe 为 nil' end
  return true
end

-- 丢弃本线程的旧管道，迫使下次调用重建
function M.dropPipe()
  if type(libmono) ~= 'table' then return false end
  if type(libmono.monopipes) ~= 'table' then return false end
  local tid = getCurrentThreadID()
  local p = libmono.monopipes[tid]
  if p then
    pcall(function() p.destroy() end)
    libmono.monopipes[tid] = nil
  end
  return true
end

-- ============ 基础工具 ============

function M.clsName(p)
  if not p or p == 0 then return 'nil' end
  local n = nil
  pcall(function() n = mono_class_getName(mono_object_getClass(p)) end)
  if not n then return 'nil' end
  if n:find('[%z\1-\31]') then return 'nil' end
  return n
end

function M.fieldOffset(clsName, fieldName)
  local c = mono_findClass('', clsName)
  if not c or c == 0 then return nil, 'no class ' .. clsName end
  local fds = mono_class_enumFields(c)
  if not fds then return nil, 'no fields for ' .. clsName end
  for i = 1, #fds do
    if fds[i].name == fieldName then return fds[i].offset end
  end
  return nil, 'no field ' .. clsName .. '.' .. fieldName
end

function M.staticBase(cn)
  local dms = mono_enumDomains()
  local dom = dms and dms[1]
  if not dom then return nil, 'no domain' end
  local c = mono_findClass('', cn)
  if not c or c == 0 then return nil, 'no class ' .. cn end
  local b = nil
  pcall(function() b = mono_class_getStaticFieldAddress(dom, c) end)
  if not b or b == 0 then return nil, 'no static for ' .. cn end
  return b, nil, dom
end

function M.findPtrTo(addr)
  local b = {}
  for i = 0, 7 do b[#b+1] = string.format('%02X', (addr >> (i*8)) & 0xFF) end
  return AOBScan(table.concat(b, ' '))
end

-- ============ 对象链解析（纯只读） ============

function M.health()
  local sb, e1 = M.staticBase('GUIHUDManager')
  if not sb then return nil, e1 end
  local o1, e2 = M.fieldOffset('GUIHUDManager', 'instance')
  if not o1 then return nil, e2 end
  local hud = readPointer(sb + o1)
  if not hud or hud == 0 then return nil, 'GUIHUDManager.instance 为 nil（未进场景）' end
  local o2, e3 = M.fieldOffset('GUIHUDManager', 'healthGUI')
  if not o2 then return nil, e3 end
  local hc = readPointer(hud + o2)
  if not hc or hc == 0 then return nil, 'healthGUI 为 nil' end
  local o3, e4 = M.fieldOffset('HealthCanvasManager', 'health')
  if not o3 then return nil, e4 end
  local h = readPointer(hc + o3)
  if not h or h == 0 then return nil, 'Health 为 nil' end
  return h
end

function M.player()
  local h, err = M.health()
  if not h then return nil, err end
  local h1 = M.findPtrTo(h)
  if not h1 then return nil, 'no ptr to health' end
  for i = 0, h1.Count - 1 do
    local mgr = getAddress(h1[i]) - 0x20
    if M.clsName(mgr) == 'PlayerHealthManager' then
      local h2 = M.findPtrTo(mgr)
      if h2 then
        for j = 0, h2.Count - 1 do
          local p = getAddress(h2[j]) - 0xD8
          if M.clsName(p) == 'Player' then return p end
        end
      end
      break
    end
  end
  return nil, 'Player not found'
end

function M.sem()
  local p, err = M.player()
  if not p then return nil, err end
  local off = M.fieldOffset('PlayerGroup.Player', 'StatusEffectManager')
  if not off then off = 0x168 end
  local s = readPointer(p + off)
  if not s or s == 0 then return nil, 'StatusEffectManager 为 nil' end
  return s, nil, p
end

function M.familyService()
  local s, err = M.sem()
  if not s then return nil, err end
  local off, e2 = M.fieldOffset('StatusEffectManager', '_progressiveFamilies')
  if not off then return nil, e2 end
  local svc = readPointer(s + off)
  if not svc or svc == 0 then return nil, 'FamilyService 为 nil' end
  return svc, nil, s
end

-- ============ 只读字典遍历（绝不写） ============

function M.readDict(dict)
  local res = {}
  if not dict or dict == 0 then return res end
  local cnt = readInteger(dict + 0x40)
  if not cnt or cnt <= 0 or cnt > 100000 then return res end
  local entries = readPointer(dict + 0x18)
  if not entries or entries == 0 then return res end
  local arrLen = readInteger(entries + 0x18)
  if not arrLen or arrLen <= 0 or arrLen > 100000 then return res end
  local base = entries + 0x20
  for i = 0, arrLen - 1 do
    local e = base + i * 0x18
    local kp = readPointer(e + 0x08)
    local vp = readPointer(e + 0x10)
    if kp and kp ~= 0 and vp and vp ~= 0 then
      local k = nil
      pcall(function() k = readString(kp + 0x14, 128, true) end)
      if k and k ~= '' then res[#res + 1] = { key = k, val = vp } end
    end
  end
  return res
end

function M.activeIds()
  local s, err = M.sem()
  if not s then return nil, err end
  local off, e2 = M.fieldOffset('StatusEffectManager', '_active')
  if not off then return nil, e2 end
  local d = readPointer(s + off)
  local list = {}
  for _, e in ipairs(M.readDict(d)) do list[#list + 1] = e.key end
  return list
end

M.FAMILIES = { 'obedience', 'nymphomania', 'masochism' }

M.FAMILY_CN = {
  obedience = '服从',
  nymphomania = '淫乱',
  masochism = '受虐倾向',
}

-- 三个家族当前等级（0 表示无）
function M.familyLevels()
  local ids, err = M.activeIds()
  if not ids then return nil, err end
  local set = {}
  for _, k in ipairs(ids) do set[k] = true end
  local res = {}
  for _, fam in ipairs(M.FAMILIES) do
    local lvl = 0
    for i = 1, 3 do
      if set['status_effect.' .. fam .. '.' .. i] then lvl = i end
    end
    res[fam] = lvl
  end
  return res, nil, set
end

-- ============ 修改（严格：管道健康才调用） ============

function M.method(clsName, methodName)
  local c = mono_findClass('', clsName)
  if not c or c == 0 then return nil, 'no class ' .. clsName end
  local ms = mono_class_enumMethods(c)
  if not ms then return nil, 'no methods for ' .. clsName end
  for i = 1, #ms do
    if ms[i].name == methodName then return ms[i].method end
  end
  return nil, 'no method ' .. clsName .. '.' .. methodName
end

--[[
  设定家族等级。
  level: 1~3 -> 对应等级；0 -> 清除（尝试 TrySetLevel(fam,0)，失败则用 TryDowngrade 循环）

  ⚠️ 只做【一次】托管调用；调用后管道可能失效，由调用方决定是否重连。
  返回: ok(boolean), detail(string)
]]
function M.setLevelOnce(fam, level)
  -- 硬规矩 C：管道不健康就拒绝调用
  local okPipe, why = M.pipeOK()
  if not okPipe then
    return false, 'pipe not healthy: ' .. tostring(why)
  end

  local dms = mono_enumDomains()
  local dom = dms and dms[1]
  if not dom then return false, 'no domain' end

  local svc, err = M.familyService()
  if not svc then return false, tostring(err) end

  if level > 0 then
    local setLvl, e4 = M.method('ProgressiveStatusFamilyService', 'TrySetLevel')
    if not setLvl then return false, tostring(e4) end
    local fs = mono_new_string(dom, fam)
    if not fs or fs == 0 then return false, 'mono_new_string 失败' end
    local ok, r = pcall(mono_invoke_method, dom, setLvl, svc, { fs, level })
    if not ok then return false, 'invoke error: ' .. tostring(r) end
    return true, string.format('TrySetLevel(%s,%d) -> %s', fam, level, tostring(r))
  end

  -- 清除：TrySetLevel(fam, 0) 实测【不接受】0（会返回失败），
  -- 正确做法是 TryDowngrade 逐级降到 0。
  -- ⚠️ 但【绝不能在一个脚本里循环调用】—— 那是 2026-09-20 第二次崩溃的原因。
  -- 本函数只降【一级】，调用方负责循环 + 每次之间检查管道。
  local down, e5 = M.method('ProgressiveStatusFamilyService', 'TryDowngrade')
  if not down then return false, tostring(e5) end
  local fs = mono_new_string(dom, fam)
  if not fs or fs == 0 then return false, 'mono_new_string 失败' end
  local ok, r = pcall(mono_invoke_method, dom, down, svc, { fs })
  if not ok then return false, 'invoke error: ' .. tostring(r) end
  return true, string.format('TryDowngrade(%s) -> %s', fam, tostring(r))
end

--[[
  downgradeSteps(fam, maxSteps) — 分步降级（每步之间由调用方检查管道）

  返回: steps(实际执行的级数), log(字符串)
  ⚠️ 本函数内部【每一步之间】都会重新检查 pipeOK()，
     并且每步都重新 dofile —— 避免持有失效的管道引用。
     这是刻意的保守设计：宁可慢，不可崩。
]]
function M.downgradeSteps(fam, maxSteps)
  maxSteps = maxSteps or 3
  local log = {}
  local steps = 0
  for i = 1, maxSteps do
    local okPipe, why = M.pipeOK()
    if not okPipe then
      log[#log + 1] = string.format('  第%d步: 管道不健康(%s)，中止', i, tostring(why))
      break
    end
    -- 读当前等级，已经是 0 就停
    local lv = M.familyLevels()
    if not lv then
      log[#log + 1] = string.format('  第%d步: 等级读取失败，中止', i)
      break
    end
    if lv[fam] <= 0 then
      log[#log + 1] = string.format('  第%d步: 已经是 0 级，结束', i)
      break
    end
    local okc, detail = M.setLevelOnce(fam, 0)
    log[#log + 1] = string.format('  第%d步: %s', i, tostring(detail))
    if not okc then break end
    steps = steps + 1
  end
  return steps, table.concat(log, '\n')
end

return M
