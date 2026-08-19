-- Grip & Flip v17 (client-side prediction) - 3-axis rotation for held objects
--
-- v17: clients now apply their rotation offset to their OWN local phys handle
-- every frame, mirroring what the host applies. Previously the client's local
-- grab sim kept forcing the item upright (the game's yaw-only auto-upright)
-- while host corrections replicated back tilted - the two fought every net
-- update, which is the jitter remote players saw on their own held items.
-- With matching local prediction the corrections are near-zero.
--
-- HOST/singleplayer: applies per-player rotation offsets to held objects each
-- frame (ABP update hook - after character tick, before physics) and decodes
-- client commands arriving via the game's own yaw RPC.
-- CLIENT: encodes rotation input into PhysGrabRotate_Server magic values,
-- batched to ~20Hz to avoid flooding the connection. Sees results on drop/place.
--
-- v16.1 fixes severe frame lag from v16: the per-frame hook now uses cached
-- player/controller references and address-only identity checks, so the idle
-- path makes ZERO engine calls per frame per character. v16 did full object
-- array scans per character per frame (cost scaled with visible characters -
-- hence "less lag in tight corners").
--
-- Controls while holding: Left Alt + mouse = rotate (camera frozen), arrows =
-- hold/tap, Numpad 8/2/4/6 = 15-degree steps, Numpad 5 = reset, F7 = debug.

local UEHelpers = require("UEHelpers")

local TAP_STEP = 3.0
local NUM_STEP = 15.0
local ROT_RATE = 100.0
local MOUSE_SENS = 0.8
local MAGIC_MIN = 5e5
local SEND_INTERVAL = 0.05 -- client -> host batch window (seconds)
local SMOOTH_SPEED = 25.0 -- host-side interp speed for client-driven rotation (light smoothing only)

local KEYFILE = os.getenv("TEMP") .. "\\GripAndFlip_keys.txt"

local S = {
    rotMode = false,
    errCount = 0,
    modeLogged = false,
    setParamWarned = false,
}
local P = {} -- host: pawnAddress -> { off = {Pitch,Yaw,Roll}, held = targetAddress }
local B = { pitch = 0, roll = 0, yaw = 0, last = 0, reset = false } -- client send buffer

-- cached references: refreshed on spawn / when invalid, never per-frame
local C = { pc = nil, pawn = nil, animAddr = nil, isAuth = true, lastTry = 0, ml = nil }

local Hooked = false
local EnsureHook

local function Log(msg)
    print("[GripAndFlip] " .. msg .. "\n")
end

local function GetML()
    if C.ml and C.ml:IsValid() then return C.ml end
    local ml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    if ml and ml:IsValid() then C.ml = ml return ml end
    return nil
end

local function GetHeld(pawn)
    local grab = pawn.PhysGrabData
    local target = grab.Target
    if target and target:IsValid() then return target end
    return nil
end

local function ReadRole(pawn)
    local role = 3
    pcall(function()
        local r = pawn.Role
        if type(r) == "number" then role = r
        elseif type(r) == "userdata" then
            local okR, n = pcall(function() return r:get() end)
            if okR and type(n) == "number" then role = n end
        end
    end)
    return role
end

local function RefreshCache()
    C.pc, C.pawn, C.animAddr = nil, nil, nil
    local ok = pcall(function()
        local pc = UEHelpers.GetPlayerController()
        if not pc or not pc:IsValid() then return end
        local pawn = pc.Pawn
        if not pawn or not pawn:IsValid() then return end
        C.pc = pc
        C.pawn = pawn
        C.animAddr = pawn.Mesh.AnimScriptInstance:GetAddress()
        C.isAuth = (ReadRole(pawn) == 3)
    end)
    if C.animAddr then
        Log("player cache ready (authority=" .. tostring(C.isAuth) .. ")")
    end
    return C.animAddr ~= nil
end

local function CacheValid()
    return C.animAddr and C.pc and C.pc:IsValid() and C.pawn and C.pawn:IsValid()
end

local function ReadKeyMask()
    local f = io.open(KEYFILE, "r")
    if not f then return 0 end
    local s = f:read("*a")
    f:close()
    return tonumber(s) or 0
end

local function IsIdentity(o)
    return math.abs(o.Pitch) < 0.01 and math.abs(o.Yaw) < 0.01 and math.abs(o.Roll) < 0.01
end

local function AxisFor(axisMode, yawDeg)
    if axisMode == "yaw" then return { X = 0, Y = 0, Z = 1 } end
    local cyaw = math.rad(yawDeg)
    if axisMode == "pitch" then
        return { X = -math.sin(cyaw), Y = math.cos(cyaw), Z = 0 }
    else
        return { X = math.cos(cyaw), Y = math.sin(cyaw), Z = 0 }
    end
end

local function ComposeInto(entry, field, ml, yawDeg, axisMode, deltaDeg)
    local delta = ml:RotatorFromAxisAndAngle(AxisFor(axisMode, yawDeg), deltaDeg)
    local o = entry[field]
    local n = ml:ComposeRotators(
        { Pitch = o.Pitch, Yaw = o.Yaw, Roll = o.Roll },
        { Pitch = delta.Pitch, Yaw = delta.Yaw, Roll = delta.Roll })
    entry[field] = { Pitch = n.Pitch, Yaw = n.Yaw, Roll = n.Roll }
end

local AXIS_CODE = { pitch = 1, roll = 2, yaw = 3 }

local function EnsureEntry(pawn, target)
    local addr = pawn:GetAddress()
    local taddr = target:GetAddress()
    local e = P[addr]
    if not e or e.held ~= taddr then
        e = {
            off = { Pitch = 0, Yaw = 0, Roll = 0 },
            tgt = { Pitch = 0, Yaw = 0, Roll = 0 },
            held = taddr,
        }
        P[addr] = e
    end
    return e
end

-- shared per-frame apply: (optionally) smooth off toward tgt, then re-compose
-- the phys handle target rotation with the offset. Safe on both host and
-- client - the handle validity guard covers pawns with no local handle.
local function ApplyEntryToHandle(pawn, e, dt, smooth)
    if IsIdentity(e.off) and IsIdentity(e.tgt) then return end
    local ml = GetML()
    if not ml then return end
    if smooth then
        local sm = ml:RInterpTo(
            { Pitch = e.off.Pitch, Yaw = e.off.Yaw, Roll = e.off.Roll },
            { Pitch = e.tgt.Pitch, Yaw = e.tgt.Yaw, Roll = e.tgt.Roll },
            dt, SMOOTH_SPEED)
        e.off = { Pitch = sm.Pitch, Yaw = sm.Yaw, Roll = sm.Roll }
    end
    local handle = pawn.GrabPhysHandle
    if not handle or not handle:IsValid() then return end
    local outLoc, outRot = {}, {}
    handle:GetTargetLocationAndRotation(outLoc, outRot)
    local o = e.off
    local final = ml:ComposeRotators(
        { Pitch = outRot.Pitch, Yaw = outRot.Yaw, Roll = outRot.Roll },
        { Pitch = o.Pitch, Yaw = o.Yaw, Roll = o.Roll })
    handle:SetTargetLocationAndRotation(
        { X = outLoc.X, Y = outLoc.Y, Z = outLoc.Z },
        { Pitch = final.Pitch, Yaw = final.Yaw, Roll = final.Roll })
end

-- local input funnel: host composes immediately, client buffers for batch send
local function ApplyInput(pc, pawn, axisMode, deltaDeg)
    local target = GetHeld(pawn)
    if not target then return end
    if C.isAuth then
        local ml = GetML()
        if not ml then return end
        local camRot = pc.PlayerCameraManager:GetCameraRotation()
        local e = EnsureEntry(pawn, target)
        -- own input: apply directly (off) and keep tgt in lockstep so the
        -- smoothing path never fights it
        ComposeInto(e, "off", ml, camRot.Yaw, axisMode, deltaDeg)
        e.tgt = { Pitch = e.off.Pitch, Yaw = e.off.Yaw, Roll = e.off.Roll }
    else
        if not S.modeLogged then
            S.modeLogged = true
            Log("client mode: batching rotation to host (host must run Grip & Flip v16+)")
        end
        B[axisMode] = math.max(-90, math.min(90, B[axisMode] + deltaDeg))
        -- local prediction: mirror the offset on our own phys handle so the
        -- local sim agrees with what the host replicates back (kills jitter)
        local ml = GetML()
        if ml then
            local camRot = pc.PlayerCameraManager:GetCameraRotation()
            local e = EnsureEntry(pawn, target)
            ComposeInto(e, "off", ml, camRot.Yaw, axisMode, deltaDeg)
            e.tgt = { Pitch = e.off.Pitch, Yaw = e.off.Yaw, Roll = e.off.Roll }
        end
    end
end

local function FlushSendBuffer(pawn)
    local now = os.clock()
    if now - B.last < SEND_INTERVAL then return end
    B.last = now
    if B.reset then
        B.reset = false
        B.pitch, B.roll, B.yaw = 0, 0, 0
        pcall(function() pawn:PhysGrabRotate_Server(4 * 1e6) end)
        return
    end
    for axis, code in pairs(AXIS_CODE) do
        local d = B[axis]
        if math.abs(d) > 0.01 then
            B[axis] = 0
            pcall(function() pawn:PhysGrabRotate_Server(code * 1e6 + d * 10) end)
        end
    end
end

local function ResetTilt()
    if S.rotMode then
        S.rotMode = false
        if C.pc and C.pc:IsValid() then pcall(function() C.pc:ResetIgnoreLookInput() end) end
    end
    if not CacheValid() then return end
    P[C.pawn:GetAddress()] = nil -- clear local entry on both host and client
    if not C.isAuth then
        B.reset = true
    end
end

local function Tap(axisMode, dir, step)
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if not CacheValid() and not RefreshCache() then return end
            if not GetHeld(C.pawn) then Log("skip: not holding") return end
            if not EnsureHook() then return end
            ApplyInput(C.pc, C.pawn, axisMode, step * dir)
        end)
        if not ok then Log("ERROR: " .. tostring(err)) end
    end)
end

RegisterKeyBind(Key.UP_ARROW, function() Tap("pitch", 1, TAP_STEP) end)
RegisterKeyBind(Key.DOWN_ARROW, function() Tap("pitch", -1, TAP_STEP) end)
RegisterKeyBind(Key.LEFT_ARROW, function() Tap("roll", 1, TAP_STEP) end)
RegisterKeyBind(Key.RIGHT_ARROW, function() Tap("roll", -1, TAP_STEP) end)
RegisterKeyBind(Key.NUM_EIGHT, function() Tap("pitch", 1, NUM_STEP) end)
RegisterKeyBind(Key.NUM_TWO, function() Tap("pitch", -1, NUM_STEP) end)
RegisterKeyBind(Key.NUM_FOUR, function() Tap("roll", 1, NUM_STEP) end)
RegisterKeyBind(Key.NUM_SIX, function() Tap("roll", -1, NUM_STEP) end)
RegisterKeyBind(Key.NUM_FIVE, function()
    ExecuteInGameThread(function()
        pcall(function()
            ResetTilt()
            S.errCount = 0
        end)
    end)
end)

-- tenkeyless alternatives (player feedback: no numpad on TKL keyboards):
-- Shift+Arrows = big 15-degree steps, Shift+Backspace = reset
pcall(function()
    RegisterKeyBind(Key.UP_ARROW, { ModifierKey.SHIFT }, function() Tap("pitch", 1, NUM_STEP) end)
    RegisterKeyBind(Key.DOWN_ARROW, { ModifierKey.SHIFT }, function() Tap("pitch", -1, NUM_STEP) end)
    RegisterKeyBind(Key.LEFT_ARROW, { ModifierKey.SHIFT }, function() Tap("roll", 1, NUM_STEP) end)
    RegisterKeyBind(Key.RIGHT_ARROW, { ModifierKey.SHIFT }, function() Tap("roll", -1, NUM_STEP) end)
    RegisterKeyBind(Key.BACKSPACE, { ModifierKey.SHIFT }, function()
        ExecuteInGameThread(function()
            pcall(function()
                ResetTilt()
                S.errCount = 0
            end)
        end)
    end)
end)

-- per-frame hook. Idle cost: one GetAddress + one or two pure-Lua checks.
local function TryRegisterHook()
    RegisterHook("/Game/Animation/ABP_HeldenPlayer.ABP_HeldenPlayer_C:BlueprintUpdateAnimation",
        function(self, DeltaTimeX)
            if S.errCount >= 8 then return end
            local ok, err = pcall(function()
                local a = self:get():GetAddress()

                if not C.animAddr then
                    -- cache not built yet; try at most once a second
                    local now = os.clock()
                    if now - C.lastTry < 1.0 then return end
                    C.lastTry = now
                    if not RefreshCache() then return end
                end

                if a == C.animAddr then
                    -- ===== local player: input capture =====
                    if not CacheValid() then
                        C.animAddr = nil -- pawn died / respawned; rebuild next second
                        return
                    end
                    local pc, pawn = C.pc, C.pawn
                    local target = GetHeld(pawn)
                    local mask = 0
                    if target or S.rotMode then mask = ReadKeyMask() end
                    local rHeld = target ~= nil and (mask & 16) ~= 0

                    if rHeld ~= S.rotMode then
                        S.rotMode = rHeld
                        if rHeld then pc:SetIgnoreLookInput(true)
                        else pc:ResetIgnoreLookInput() end
                    end

                    if target and mask ~= 0 then
                        local dt = DeltaTimeX:get()
                        local step = ROT_RATE * dt
                        if (mask & 1) ~= 0 then ApplyInput(pc, pawn, "pitch", step) end
                        if (mask & 2) ~= 0 then ApplyInput(pc, pawn, "pitch", -step) end
                        if (mask & 4) ~= 0 then ApplyInput(pc, pawn, "roll", step) end
                        if (mask & 8) ~= 0 then ApplyInput(pc, pawn, "roll", -step) end
                        if rHeld then
                            local t1, t2 = {}, {}
                            pc:GetInputMouseDelta(t1, t2)
                            local dx = t1.DeltaX or t2.DeltaX
                            local dy = t1.DeltaY or t2.DeltaY
                            if type(dx) == "number" and dx ~= 0 then ApplyInput(pc, pawn, "yaw", -dx * MOUSE_SENS) end
                            if type(dy) == "number" and dy ~= 0 then ApplyInput(pc, pawn, "pitch", dy * MOUSE_SENS) end
                        end
                    end

                    if not C.isAuth then
                        FlushSendBuffer(pawn)
                    end
                    -- host AND client: apply own entry to own (local) handle
                    local e = P[pawn:GetAddress()]
                    if not e then return end
                    if not target or target:GetAddress() ~= e.held then
                        P[pawn:GetAddress()] = nil
                        return
                    end
                    ApplyEntryToHandle(pawn, e, DeltaTimeX:get(), false)
                    return
                end

                -- ===== other characters: only matters on host with active entries =====
                if next(P) == nil then return end
                local inst = self:get()
                local pawn = inst:TryGetPawnOwner()
                if not pawn or not pawn:IsValid() then return end
                local addr = pawn:GetAddress()
                local e = P[addr]
                if not e then return end
                local target = GetHeld(pawn)
                if not target or target:GetAddress() ~= e.held then P[addr] = nil return end
                ApplyEntryToHandle(pawn, e, DeltaTimeX:get(), true)
            end)
            if not ok then
                S.errCount = S.errCount + 1
                Log("frame ERROR (" .. S.errCount .. "/8): " .. tostring(err))
                if S.errCount >= 8 then
                    pcall(function()
                        if C.pc and C.pc:IsValid() then C.pc:ResetIgnoreLookInput() end
                    end)
                    S.rotMode = false
                    Log("too many errors - Grip & Flip disabled, Ctrl+R to retry")
                end
            end
        end)
end

EnsureHook = function()
    if Hooked then return true end
    local ok, err = pcall(TryRegisterHook)
    if ok then
        Hooked = true
        Log("anim-update hook registered")
    else
        Log("hook registration failed (will retry): " .. tostring(err))
    end
    return Hooked
end

EnsureHook()

pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self)
        EnsureHook()
        C.animAddr = nil -- respawn/level change: rebuild cache on next frame
        C.lastTry = 0
    end)
end)

-- host-side decoder for client rotation commands
pcall(function()
    RegisterHook("/Script/Helden.HeldenCharacter:PhysGrabRotate_Server", function(self, InRight)
        pcall(function()
            local v = InRight:get()
            if math.abs(v) < MAGIC_MIN then return end
            local pawn = self:get()
            if ReadRole(pawn) ~= 3 then return end -- client send-side: pass through
            local axisCode = math.floor(v / 1e6 + 0.5)
            local deltaDeg = (v - axisCode * 1e6) / 10

            if axisCode == 4 then
                P[pawn:GetAddress()] = nil
            else
                local axisMode = (axisCode == 1 and "pitch") or (axisCode == 2 and "roll") or "yaw"
                local target = GetHeld(pawn)
                if target then
                    local ml = GetML()
                    if ml then
                        local viewYaw = 0
                        pcall(function() viewYaw = pawn:GetControlRotation().Yaw end)
                        -- client-driven: compose into the TARGET only; the frame
                        -- hook interpolates the applied offset toward it
                        ComposeInto(EnsureEntry(pawn, target), "tgt", ml, viewYaw, axisMode, deltaDeg)
                    end
                end
            end

            local okSet = pcall(function() InRight:set(0.0) end)
            if not okSet and not S.setParamWarned then
                S.setParamWarned = true
                Log("WARNING: could not zero RPC param - client rotations will also cause yaw jumps")
            end
        end)
    end)
end)

-- key poller
local function FindPoller()
    local candidates = {
        "Mods\\GripAndFlip\\keypoll.ps1",
        "ue4ss\\Mods\\GripAndFlip\\keypoll.ps1",
        "..\\ue4ss\\Mods\\GripAndFlip\\keypoll.ps1",
    }
    -- resolve relative to this script file first: required under
    -- unreal-shimloader (Thunderstore/r2modman), where the mod folder lives
    -- in a profile directory instead of the game folder
    pcall(function()
        local src = debug.getinfo(1, "S").source
        local dir = src:match("^@(.*)[\\/]Scripts[\\/]main%.lua$")
        if dir then
            table.insert(candidates, 1, dir .. "\\keypoll.ps1")
        end
    end)
    for _, p in ipairs(candidates) do
        local f = io.open(p, "r")
        if f then f:close() return p end
    end
    return nil
end

local pollerPath = FindPoller()
if pollerPath then
    -- Under unreal-shimloader the mod folder is a VIRTUAL path that only the
    -- game process can resolve; PowerShell is a separate process and cannot
    -- open it. Copy the script to the real %TEMP% from in-process (where the
    -- virtual read works) and launch the copy. Also correct for manual installs.
    local launchPath = pollerPath
    pcall(function()
        local tmp = os.getenv("TEMP")
        if not tmp then return end
        local src = io.open(pollerPath, "r")
        if not src then return end
        local body = src:read("*a")
        src:close()
        if not body or #body == 0 then return end
        local dstPath = tmp .. "\\GrabRotate3D_keypoll.ps1"
        local dst = io.open(dstPath, "w")
        if not dst then return end
        dst:write(body)
        dst:close()
        launchPath = dstPath
    end)
    local okExec = pcall(function()
        os.execute('start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. launchPath .. '"')
    end)
    Log(okExec and ("key poller launched: " .. launchPath) or "WARNING: could not launch key poller - hold/Alt rotation unavailable")
else
    Log("WARNING: keypoll.ps1 not found - hold/Alt rotation unavailable (taps still work)")
end

RegisterKeyBind(Key.F7, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if not CacheValid() and not RefreshCache() then Log("F7: no player") return end
            local target = GetHeld(C.pawn)
            Log("Holding: " .. (target and target:GetFullName() or "nothing"))
            Log("Authority: " .. tostring(C.isAuth) .. " errs: " .. S.errCount)
            local n = 0
            for addr, e in pairs(P) do
                n = n + 1
                Log(string.format("  entry %d: P%.1f Y%.1f R%.1f", n, e.off.Pitch, e.off.Yaw, e.off.Roll))
            end
            if n == 0 then Log("  no active rotation entries") end
        end)
        if not ok then Log("F7 ERROR: " .. tostring(err)) end
    end)
end)

Log("v17 loaded (client prediction). Alt+mouse / arrows / numpad as before, Num5 = reset, F7 = debug.")
