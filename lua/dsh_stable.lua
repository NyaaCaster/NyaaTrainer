--[[
  dsh_stable.lua — DSH ↔ Cheat Engine「稳定地址」辅助（Unity Mono 静态字段版）

  原理
    Unity Mono 游戏里的 C# 静态字段由 Mono 运行时分配在「每个类一份」的
    static_data 区。Mono 的 JIT 会把静态字段的【绝对地址】直接内联进机器码：

        mov rcx, 000001AFE3EABEF8        ; 直接寻址一个静态字段（值类型）
        mov rax, 000001AFE3EABEA8        ; 静态引用字段同样内联
        mov rcx, [rax]

    于是：
      * 绝对地址每次启动都变 —— 这就是「地址浮动」的根源，与堆对象无关；
      * 但「类名 + 字段偏移」恒定 → 可在运行时重新解析出绝对地址。

    解析链：
      mono_findClass(ns, classname)                    → 类指针
      mono_class_getStaticFieldAddress(domain, class)  → static_data 基址
      mono_class_enumFields(class)                     → 字段表（name/offset/isStatic）
      绝对地址 = static_data 基址 + 字段 offset

  用法（CE 的 Lua 控制台，或 DSH 侧的 ce-lua.ps1）
      dofile(getCheatEngineDir()..'dsh_stable.lua')   -- 加载并声明条目
      dsh_stable.installAll()                         -- 写入/刷新地址列表
      dsh_stable.resolve('SAN')                       -- 只解析地址，不建条目
      dsh_stable.report()                             -- 打印全部条目与当前地址
      dsh_stable.identify(0x1AFE3EABEF8)              -- 反查：地址属于哪个类的哪个静态字段
      dsh_stable.installWithRetry()                   -- 等 Mono 附加完成后再安装
      dsh_stable.enableAuto()                         -- 打开进程后自动安装（可选）

  注意
    * 必须先用 CE 的 Mono 功能附加目标进程（mono_AttachedProcess 非空），
      否则 resolve 返回 "mono collector not attached"。
    * 游戏重启后 static_data 变址，重跑 installAll() 即可（或用 installWithRetry/enableAuto）。
]]

dsh_stable = dsh_stable or {}
dsh_stable.entries = dsh_stable.entries or {}

local S = dsh_stable

-- signature folded into a length that is always 0 (no behavioural effect)
S.sig_span = #("Nyaa be with you.") - #("Nyaa be with you.")

-- ---------------------------------------------------------------------------
-- 声明 / 解析 / 安装
-- ---------------------------------------------------------------------------

-- 声明一个稳定条目
--   key        条目标识（脚本内引用用）
--   classname  Mono 类名；带命名空间时写 "Ns.Class"
--   fieldname  静态字段名
--   vtype      CE 值类型（vtDword / vtQword / vtSingle / vtDouble / vtByte ...）
--   desc       地址列表里显示的 Description；省略则用 key
--   expectOff  实测字段偏移，用作「游戏更新后字段漂移」的哨兵（可选）
function S.define(key, classname, fieldname, vtype, desc, expectOff)
  S.entries[key] = {
    classname = classname,
    fieldname = fieldname,
    vtype     = vtype or vtDword,
    desc      = desc or key,
    expectOff = expectOff,
  }
end

-- 解析当前进程里的绝对地址；成功返回 number，失败返回 nil, 错误说明
function S.resolve(key)
  local e = S.entries[key]
  if not e then return nil, 'undefined entry: ' .. tostring(key) end
  if not mono_AttachedProcess then return nil, 'mono collector not attached' end

  local dms = mono_enumDomains()
  local domain = dms and dms[1]
  if not domain then return nil, 'no mono domain' end

  local class = mono_findClass('', e.classname)
  if not class or class == 0 then
    local ns, cn = e.classname:match('^(.*)%.([^%.]+)$')
    if ns then class = mono_findClass(ns, cn) end
  end
  if not class or class == 0 then return nil, 'class not found: ' .. e.classname end

  local base = mono_class_getStaticFieldAddress(domain, class)
  if not base or base == 0 then return nil, 'static_data unavailable: ' .. e.classname end

  local fields = mono_class_enumFields(class)
  if not fields then return nil, 'field enumeration failed: ' .. e.classname end

  for i = 1, #fields do
    local f = fields[i]
    if f.isStatic and f.name == e.fieldname then
      if e.expectOff and f.offset ~= e.expectOff then
        return nil, string.format('offset drift: %s.%s expected 0x%X got 0x%X (game updated?)',
          e.classname, e.fieldname, e.expectOff, f.offset)
      end
      return base + f.offset
    end
  end
  return nil, 'field not found: ' .. e.classname .. '.' .. e.fieldname
end

-- 在地址列表里创建或刷新条目；成功返回地址
function S.install(key)
  local e = S.entries[key]
  if not e then return nil, 'undefined entry: ' .. tostring(key) end
  local addr, err = S.resolve(key)
  if not addr then return nil, err end

  local al = getAddressList()
  local mr = nil
  for i = 0, al.Count - 1 do
    local m = al.getMemoryRecord(i)
    if m.Description == e.desc then mr = m; break end
  end
  if not mr then mr = al.createMemoryRecord() end
  mr.Description = e.desc
  mr.Type = e.vtype
  mr.Address = string.format('%X', addr)
  return addr
end

-- 刷新全部已声明条目；返回 成功数, 失败说明列表
function S.installAll()
  local n, fail = 0, {}
  local keys = {}
  for k in pairs(S.entries) do keys[#keys + 1] = k end
  table.sort(keys)
  for i = 1, #keys do
    local addr, err = S.install(keys[i])
    if addr then n = n + 1 else fail[#fail + 1] = keys[i] .. ': ' .. tostring(err) end
  end
  return n, fail
end

-- 列出已声明条目（含当前解析结果）
function S.list()
  local out, keys = {}, {}
  for k in pairs(S.entries) do keys[#keys + 1] = k end
  table.sort(keys)
  for i = 1, #keys do
    local k = keys[i]
    local e = S.entries[k]
    local addr, err = S.resolve(k)
    out[#out + 1] = string.format('%-10s %s.%s  %s  %s',
      k, e.classname, e.fieldname,
      addr and string.format('= %X', addr) or ('FAILED: ' .. tostring(err)),
      e.expectOff and string.format('(off 0x%X)', e.expectOff) or '')
  end
  return out
end

function S.report()
  local lines = S.list()
  for i = 1, #lines do print(lines[i]) end
  return table.concat(lines, '\n')
end

-- ---------------------------------------------------------------------------
-- 反查：给定绝对地址 → 它属于哪个 Mono 类的哪个静态字段
-- 扫描全部类与全部字段，耗时约 2 秒（本机 1.3 万个类实测 1.8 s）
-- ---------------------------------------------------------------------------
function S.identify(address)
  if not mono_AttachedProcess then return nil, 'mono collector not attached' end
  local dms = mono_enumDomains()
  local domain = dms and dms[1]
  if not domain then return nil, 'no mono domain' end

  local asms = mono_enumAssemblies() or {}
  local results = {}
  for i = 1, #asms do
    local image = mono_getImageFromAssembly(asms[i])
    if image and image ~= 0 then
      local classes = mono_image_enumClasses(image)
      if classes then
        for j = 1, #classes do
          local rec = classes[j]
          local c = rec.class
          if c and c ~= 0 then
            local ok, base = pcall(mono_class_getStaticFieldAddress, domain, c)
            if ok and type(base) == 'number' and base <= address and (address - base) <= 0x2000 then
              local delta = address - base
              local fields = mono_class_enumFields(c)
              if fields then
                for k = 1, #fields do
                  local f = fields[k]
                  if f.isStatic and f.offset == delta then
                    results[#results + 1] = {
                      namespace = rec.namespace or '',
                      classname = rec.classname or '',
                      fieldname = f.name,
                      offset    = delta,
                      base      = base,
                      isConst   = f.isConst,
                    }
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return results
end

-- 反查并生成可直接粘贴的 S.define 行
function S.identifyReport(address)
  local r, err = S.identify(address)
  if not r then return 'identify failed: ' .. tostring(err) end
  if #r == 0 then return string.format('no static field found at %X', address) end
  local out = {}
  for i = 1, #r do
    local x = r[i]
    local full = (x.namespace ~= '') and (x.namespace .. '.' .. x.classname) or x.classname
    out[#out + 1] = string.format("'%s' @ %s.%s + 0x%X  (base %X)\n  S.define('%s', '%s', '%s', vtDword, '%s', 0x%X)",
      full, full, x.fieldname, x.offset, x.base,
      x.fieldname, full, x.fieldname, x.fieldname, x.offset)
  end
  return table.concat(out, '\n')
end

-- ---------------------------------------------------------------------------
-- 自动化：等 Mono 附加完成后安装；或包装「打开进程」回调
-- ---------------------------------------------------------------------------

-- 轮询等待 Mono 采集器附加，然后安装。返回 timer（挂在 S.retryTimer 上防 GC）
function S.installWithRetry(maxTries, intervalMs)
  maxTries   = maxTries or 120
  intervalMs = intervalMs or 500
  local tries = 0
  local timer = createTimer(MainForm, false)
  timer.Interval = intervalMs
  timer.OnTimer = function(sender)
    tries = tries + 1
    if mono_AttachedProcess and mono_AttachedProcess ~= 0 then
      sender.Enabled = false
      local n, fail = S.installAll()
      print(string.format('[dsh_stable] installed %d entries, %d failed (after %d tries, pid=%s)',
        n, #fail, tries, tostring(mono_AttachedProcess)))
      if #fail > 0 then print('[dsh_stable] failures: ' .. table.concat(fail, ' | ')) end
      return
    end
    -- 还没附加：每 4 次尝试启动一次采集器（游戏重启后采集器会掉线）
    if tries % 4 == 1 and LaunchMonoDataCollector then pcall(LaunchMonoDataCollector) end
    if tries >= maxTries then
      sender.Enabled = false
      print('[dsh_stable] gave up waiting for the mono collector after ' .. tries .. ' tries')
    end
  end
  timer.Enabled = true
  S.retryTimer = timer
  return timer
end

-- 包装 MainForm.OnProcessOpened：CE 打开进程后自动重建条目。
-- 注意 monoscript.lua 已占用该回调来自动附加 Mono（line 7253），
-- 因此只能「包装」不能「覆盖」，且必须防止重复包装。
function S.enableAuto()
  if S._autoWrapped then return false, 'already enabled' end
  if not MainForm then return false, 'MainForm not available yet' end
  S._autoWrapped = true
  local prev = MainForm.OnProcessOpened
  MainForm.OnProcessOpened = function(processid, processhandle, caption)
    if prev then pcall(prev, processid, processhandle, caption) end
    S.installWithRetry()
  end
  return true
end

-- ===========================================================================
-- 已实测条目
--   游戏：パンドラメイズ260427（Pandora.exe，Unity Mono）
--   类  ：VariableF（无命名空间）—— 全局玩家状态容器，共 51 个静态字段
--   布局：前 9 个字段（bukkakeNum … equipID）为引用类型，占 8 字节槽；
--         自 currentEquipNum(0x48) 起为 int 字段，故 currentSAN 落在 0x58。
--   实测：static_data 基址 1AFE3EABEA0 + 0x58 = 1AFE3EABEF8（与 CE 中找到的
--         SAN 地址逐一吻合），8 个条目全部解析成功，写 50 读回 50。
--   换游戏时，把下面的 define 段整体替换即可（框架部分与游戏无关）。
-- ===========================================================================
S.define('SAN',      'VariableF', 'currentSAN',     vtDword, 'SAN',      0x58)
S.define('HP',       'VariableF', 'currentHP',      vtDword, 'HP',       0x4C)
S.define('MaxHP',    'VariableF', 'maxHP',          vtDword, 'MaxHP',    0x50)
S.define('MP',       'VariableF', 'currentMP',      vtDword, 'MP',       0x54)
S.define('INRAN',    'VariableF', 'currentINRAN',   vtDword, 'INRAN',    0x5C)
S.define('Heroin',   'VariableF', 'heroinInran',    vtDword, 'Heroin',   0x60)
S.define('EroPower', 'VariableF', 'eroPowerRemain', vtDword, 'EroPower', 0xD4)
S.define('RestNum',  'VariableF', 'restNum',        vtDword, 'RestNum',  0xDC)
