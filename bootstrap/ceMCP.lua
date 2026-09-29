-- ============================================
-- CE MCP Daemon
-- Memory Communication Protocol for Cheat Engine
-- Menu-controlled: MCP Server -> Debug / Start/Stop
-- ============================================

local __dsh_dir = getCheatEngineDir() if __dsh_dir:sub(-1) ~= "\\" then __dsh_dir = __dsh_dir .. "\\" end
local pipe_request = __dsh_dir .. "mcp_req.txt"
local pipe_response = __dsh_dir .. "mcp_res.txt"

-- ============================================
-- Debug Mode
-- ============================================

local DEBUG = false
local mcpTimer = nil
local mcpRunning = false

-- ============================================
-- Helper Functions
-- ============================================

local function safe_get_address(addr_expr)
    if not addr_expr then return nil end
    local result = getAddressSafe(addr_expr)
    if result and result ~= 0 then
        return result
    end
    return nil
end

local function debug_print(msg)
    if DEBUG then
        print("[CE MCP] " .. msg)
    end
end

-- ============================================
-- Command Processing
-- ============================================

local function process_command(action, params)
    if getOpenedProcessID() == 0 then
        return {status = "error", message = "CE is not attached to any process."}
    end

    -- Read Memory
    if action == "read_memory" or action == "read" then
        local target_addr = safe_get_address(params.addr)
        if not target_addr then
            return {status = "error", message = "Invalid memory address parameter."}
        end

        local bytes_to_read = tonumber(params.type) or 4
        local as_hex = params.hex and string.lower(params.hex) == "true"

        if bytes_to_read > 8 then
            local byte_table = readBytes(target_addr, bytes_to_read, true)
            if not byte_table then
                return {status = "error", message = "Read block failed. Invalid address or size too large."}
            end
            local hex_parts = {}
            for _, b in ipairs(byte_table) do
                table.insert(hex_parts, string.format("%02X", b))
            end
            local hex_dump = table.concat(hex_parts, " ")
            local value_field = as_hex and string.format("0x%s", string.gsub(hex_dump, " ", "")) or hex_dump
            return {
                status = "success",
                action = "read_block",
                address = params.addr,
                size = bytes_to_read,
                hex = hex_dump,
                value = value_field,
                is_hex = as_hex
            }
        end

        local val = nil
        if bytes_to_read == 4 then
            val = readInteger(target_addr)
        elseif bytes_to_read == 8 then
            val = readQword(target_addr)
        elseif bytes_to_read == 1 then
            val = readBytes(target_addr, 1)
        elseif bytes_to_read == 2 then
            val = readSmallInteger(target_addr)
        end

        if val == nil then
            return {status = "error", message = "Read failed. Invalid address."}
        else
            local read_value = as_hex and string.format("0x%X", val) or val
            return {status = "success", action = "read", address = params.addr, value = read_value, is_hex = as_hex}
        end

    -- Write Memory
    elseif action == "write_memory" or action == "write" then
        local target_addr = safe_get_address(params.addr)
        if not target_addr then
            return {status = "error", message = "Invalid memory address parameter."}
        end

        local bytes_to_write = tonumber(params.type) or 4
        local as_hex = params.hex and string.lower(params.hex) == "true"
        local write_val = as_hex and tonumber(params.val, 16) or tonumber(params.val)
        local success = false
        if bytes_to_write == 4 then
            success = writeInteger(target_addr, write_val)
        elseif bytes_to_write == 8 then
            success = writeQword(target_addr, write_val)
        elseif bytes_to_write == 2 then
            success = writeSmallInteger(target_addr, write_val)
        end

        if success then
            return {status = "success", action = "write", address = params.addr, value = params.val, is_hex = as_hex}
        else
            return {status = "error", message = "Write failed."}
        end

    -- Disassemble
    elseif action == "disassemble" or action == "disasm" then
        local count = tonumber(params.count) or 5
        local current_addr = safe_get_address(params.addr)
        if not current_addr then
            return {status = "error", message = "Invalid address syntax."}
        end

        local asm_list = {}
        for i = 1, count do
            local disasmLine = disassemble(current_addr)
            if disasmLine then
                local d_addr, d_bytes, d_op, d_comment = splitDisassembledString(disasmLine)
                d_bytes = string.gsub(d_bytes or "", '"', '\\"')
                d_op = string.gsub(d_op or "", '"', '\\"')
                if d_comment and d_comment ~= "" then
                    d_op = d_op .. "  ; " .. string.gsub(d_comment, '"', '\\"')
                end
                table.insert(asm_list, string.format(
                    '{"addr":"0x%X","bytes":"%s","asm":"%s"}',
                    current_addr, d_bytes, d_op
                ))
                current_addr = current_addr + getInstructionSize(current_addr)
            else
                break
            end
        end
        return {status = "success", action = "disasm", data = "[" .. table.concat(asm_list, ",") .. "]"}

    -- Get Modules
    elseif action == "get_modules" or action == "modules" then
        local modules = enumModules()
        if not modules then
            return {status = "error", message = "Failed to retrieve module list."}
        end

        local mod_list = {}
        for _, mod in ipairs(modules) do
            local name = string.gsub(mod.Name or "", '"', '\\"')
            local size = getModuleSize(mod.Name) or 0
            table.insert(mod_list, string.format(
                '{"name":"%s","base":"0x%X","size":%d}',
                name, mod.Address, size
            ))
        end
        return {status = "success", action = "modules", data = "[" .. table.concat(mod_list, ",") .. "]"}

    -- AOB Scan
    elseif action == "aob_scan" or action == "search" then
        if not params.aob or params.aob == "" then
            return {status = "error", message = "Missing AOB signature pattern."}
        end

        local scan_results = AOBScan(params.aob, "")
        if not scan_results then
            return {status = "success", action = "aob_scan", data = "[]"}
        end

        local addr_strings = {}
        local count = scan_results.Count
        local max_results = math.min(count - 1, 19)
        for i = 0, max_results do
            local found_addr = scan_results[i]
            table.insert(addr_strings, string.format('"0x%X"', tonumber(found_addr, 16)))
        end
        scan_results.destroy()
        return {status = "success", action = "aob_scan", data = "[" .. table.concat(addr_strings, ",") .. "]"}

    -- Get Address
    elseif action == "get_address" or action == "parse" then
        local resolved_addr = safe_get_address(params.expr)
        if not resolved_addr then
            return {status = "error", message = "Failed safely resolving expression: " .. tostring(params.expr)}
        else
            return {
                status = "success",
                action = "get_address",
                expression = params.expr,
                address = string.format("0x%X", resolved_addr)
            }
        end

    -- Hex Calculator
    elseif action == "calc" or action == "hex_calc" then
        local expr = params.expr
        if not expr or expr == "" then
            return {status = "error", message = "Missing expression."}
        end

        local func, err = load("return " .. expr, "=hex_calc")
        if not func then
            return {status = "error", message = "Invalid expression: " .. tostring(err)}
        end

        local ok, result = pcall(func)
        if not ok then
            return {status = "error", message = "Calculation error: " .. tostring(result)}
        end

        if type(result) == "number" then
            local hex_result = string.format("0x%X", math.floor(result))
            local dec_result = math.floor(result)
            return {
                status = "success",
                action = "calc",
                expression = expr,
                result_dec = dec_result,
                result_hex = hex_result
            }
        else
            return {
                status = "success",
                action = "calc",
                expression = expr,
                result = tostring(result)
            }
        end
    elseif action == "auto_assemble" or action == "inject" then
        if not params.script or params.script == "" then
            return {status = "error", message = "Missing assembly script."}
        end

        local script_body = string.gsub(params.script, "_LF_", "\n")
        local success, recID = autoAssemble(script_body)
        if success then
            -- Also create a memory record in the address list so the user can view/edit/use it
            local memrec = getAddressList().createMemoryRecord()
            memrec.Type = vtAutoAssembler
            memrec.Script = script_body
            -- Derive a description from the first line of the script
            local first_line = string.match(script_body, "^[^%[\n]+") or "AutoAssemble Script"
            memrec.Description = string.format("MCP: %s", string.gsub(first_line, "^%s+", ""))
            memrec.ID = recID or memrec.ID

            return {
                status = "success",
                action = "auto_assemble",
                message = "Assembly script injected and added to address list.",
                record_id = memrec.ID,
                description = memrec.Description
            }
        else
            return {status = "error", message = "Auto assemble code injection failed. Syntax error in script?"}
        end
    end

    return {status = "error", message = "Unknown command: " .. tostring(action)}
end

-- ============================================
-- Request Parsing
-- ============================================

local function adaptive_parse(lines)
    local action = nil
    local params = {}
    local first_line = ""

    if type(lines) == "table" then
        first_line = lines[1] or ""
    else
        first_line = tostring(lines)
    end

    if string.find(first_line, "GET%s+") then
        -- HTTP GET request parsing
        local url_path = string.match(first_line, "GET%s+(.-)%s+HTTP") or ""
        action = string.match(url_path, "^/([^?]+)")
        local query = string.match(url_path, "%?(.*)")
        if query then
            for pair in string.gmatch(query, "([^&]+)") do
                local k, v = string.match(pair, "([^=]+)=([^=]+)")
                if k and v then params[k] = v end
            end
        end
    else
        -- Key=Value pair format
        if type(lines) == "table" then
            action = lines[1]
            for i = 2, #lines do
                local k, v = string.match(lines[i], "([^=]+)=(.*)")
                if k and v then params[k] = v end
            end
        end
    end

    return action, params
end

-- ============================================
-- Server Start / Stop
-- ============================================

local function start_server()
    if mcpRunning then return end

    -- Clean up stale pipe files
    os.remove(pipe_request)
    os.remove(pipe_response)

    mcpTimer = createTimer(nil)
    mcpTimer.Interval = 20
    mcpRunning = true

    mcpTimer.OnTimer = function()
        local req_file = io.open(pipe_request, "r")
        if req_file then
            local lines = {}
            for line in req_file:lines() do
                table.insert(lines, line)
            end
            req_file:close()
            os.remove(pipe_request)

            if #lines > 0 then
                local action, params = adaptive_parse(lines)

                -- Debug logging
                if DEBUG then
                    if action == "auto_assemble" or action == "inject" then
                        local script_len = params.script and string.len(string.gsub(params.script, "_LF_", "\n")) or 0
                        print(string.format(
                            "[CE MCP Event] Action: %s | Script Length: %d chars",
                            tostring(action), script_len
                        ))
                    elseif action == "get_address" or action == "parse" or action == "calc" then
                        print(string.format(
                            "[CE MCP Event] Action: %s | Expression Input: '%s'",
                            tostring(action), tostring(params.expr)
                        ))
                    elseif action == "read_memory" or action == "read" or action == "write_memory" or action == "write" then
                        print(string.format(
                            "[CE MCP Event] Action: %s | Address: %s | Type: %s | Hex: %s",
                            tostring(action), tostring(params.addr), tostring(params.type), tostring(params.hex)
                        ))
                    else
                        local log_meta = params.addr or params.aob or "N/A"
                        print(string.format(
                            "[CE MCP Event] Action: %s | Meta: %s",
                            tostring(action), tostring(log_meta)
                        ))
                    end
                end

                local result_obj = process_command(action, params)

                -- Debug result logging
                if DEBUG then
                    if result_obj.action == "get_address" and result_obj.status == "success" then
                        print(string.format("[CE MCP Result] Resolved Base Address -> %s", tostring(result_obj.address)))
                    elseif result_obj.action == "calc" and result_obj.status == "success" then
                        print(string.format("[CE MCP Result] Calc Expression: '%s' = %s (%d)", result_obj.expression, result_obj.result_hex, result_obj.result_dec))
                    elseif (result_obj.action == "read" or result_obj.action == "read_block") and result_obj.status == "success" then
                        print(string.format("[CE MCP Result] Read Address: %s | Value: %s | Hex Mode: %s", result_obj.address, tostring(result_obj.value), tostring(result_obj.is_hex)))
                    elseif result_obj.action == "write" and result_obj.status == "success" then
                        print(string.format("[CE MCP Result] Write Address: %s | Value: %s | Hex Mode: %s", result_obj.address, tostring(result_obj.value), tostring(result_obj.is_hex)))
                    end
                end

                -- JSON response serialization
                local json_res = ""
                if result_obj.status == "error" then
                    json_res = string.format('{"status":"error","message":"%s"}', result_obj.message)
                else
                    if result_obj.action == "disasm" or result_obj.action == "modules" or result_obj.action == "aob_scan" then
                        json_res = string.format(
                            '{"status":"success","action":"%s","lines":%s}',
                            result_obj.action, result_obj.data
                        )
                    elseif result_obj.action == "get_address" then
                        json_res = string.format(
                            '{"status":"success","action":"get_address","expression":"%s","address":"%s"}',
                            result_obj.expression, result_obj.address
                        )
                    elseif result_obj.action == "auto_assemble" then
                        json_res = string.format(
                            '{"status":"success","action":"auto_assemble","message":"%s","record_id":%s,"description":"%s"}',
                            result_obj.message,
                            tostring(result_obj.record_id),
                            result_obj.description
                        )
                    elseif result_obj.action == "read_block" then
                        json_res = string.format(
                            '{"status":"success","action":"read_block","address":"%s","size":%d,"hex":"%s","value":"%s","is_hex":%s}',
                            result_obj.address, result_obj.size, result_obj.hex,
                            result_obj.value, tostring(result_obj.is_hex)
                        )
                    elseif result_obj.action == "calc" then
                        json_res = string.format(
                            '{"status":"success","action":"calc","expression":"%s","result_dec":%d,"result_hex":"%s"}',
                            result_obj.expression, result_obj.result_dec, result_obj.result_hex
                        )
                    else
                        local val_str = type(result_obj.value) == "string"
                            and string.format('"%s"', result_obj.value)
                            or tostring(result_obj.value)
                        json_res = string.format(
                            '{"status":"success","action":"%s","address":"%s","value":%s}',
                            result_obj.action, result_obj.address, val_str
                        )
                    end
                end

                -- Write response
                local res_file = io.open(pipe_response, "w")
                if res_file then
                    res_file:write(json_res)
                    res_file:close()
                end
            end
        end
    end

    debug_print("Server started.")
end

local function stop_server()
    if not mcpRunning then return end

    mcpTimer.destroy()
    mcpTimer = nil
    mcpRunning = false

    debug_print("Server stopped.")
end

-- ============================================
-- Build Menu
-- ============================================

local miMCPServer = createMenuItem(MainForm)
miMCPServer.Caption = "MCP Server"

-- Insert after "Help" menu (index4) or at end
local menuItems = MainForm.Menu.Items
local insertIdx = menuItems.Count
for i = 0, menuItems.Count - 1 do
    if menuItems[i].Caption == "Help" then
        insertIdx = i
        break
    end
end
menuItems.insert(insertIdx, miMCPServer)

-- Divider
local miDivider1 = createMenuItem(miMCPServer)
miDivider1.Caption = "-"
miMCPServer.add(miDivider1)

-- Debug toggle
local miDebug = createMenuItem(miMCPServer)
miDebug.Caption = "Debug"
miDebug.AutoCheck = true
miDebug.Checked = DEBUG
miDebug.OnClick = function(s)
    DEBUG = s.Checked
    if DEBUG then
        debug_print("Debug mode ON")
    end
end
miMCPServer.add(miDebug)

-- Divider
local miDivider2 = createMenuItem(miMCPServer)
miDivider2.Caption = "-"
miMCPServer.add(miDivider2)

-- Start / Stop
local miStartStop = createMenuItem(miMCPServer)
miStartStop.Caption = "Start"
miStartStop.OnClick = function(s)
    if not mcpRunning then
        start_server()
        s.Caption = "Stop"
    else
        stop_server()
        s.Caption = "Start"
    end
end
miMCPServer.add(miStartStop)

debug_print("Menu ready. Use: MCP Server -> Start to begin.")
--==== DSH patch: expose + auto start ====
_G.CEMCP_start = start_server
_G.CEMCP_stop = stop_server
pcall(function() start_server() end)
