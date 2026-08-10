-- Grip & Flip v16 (STAGE 1 multiplayer) - 3-axis rotation for held objects
--
-- Roles (auto-detected, same file on every machine):
--  * HOST / singleplayer: applies rotation offsets per-player to held objects,
--    every frame, composed onto the game's yaw-only phys-handle target from a
--    hook on ABP_HeldenPlayer:BlueprintUpdateAnimation (after character tick,
--    before physics). Also decodes rotation commands arriving from clients.
--  * CLIENT (joined someone's lobby): does not rotate anything locally. Instead
--    encodes rotation input as out-of-range values in the game's own yaw RPC
--    (PhysGrabRotate_Server) - the host's hook decodes them, zeroes the fake
--    yaw, and applies the rotation authoritatively. Stage 1 = "blind" rotation:
--    the client sees the result on drop/place (the game replicates held items
--    yaw-only); the host sees it live.
--
-- Encoding: v = axisCode*1e6 + deltaDegrees*10   (axis 1=pitch 2=roll 3=yaw,
-- 4=reset). Native yaw values are ~|1-3|, so |v| > 5e5 marks a command.
--
-- Controls while holding: Left Alt + mouse = rotate (camera frozen), arrows =
-- hold/tap, Numpad 8/2/4/6 = 15-degree steps, Numpad 5 = reset, F7 = debug.

local UEHelpers = require("UEHelpers")

local TAP_STEP = 3.0
local NUM_STEP = 15.0
local ROT_RATE = 100.0
local MOUSE_SENS = 0.8
local MAGIC_MIN = 5e5

local KEYFILE = os.getenv("TEMP") .. "\\GripAndFlip_keys.txt"

local S = {
    rotMode = false,   -- Left Alt held (local player, while holding an item)
    errCount = 0,
    modeLogged = false,
    setParamWarned = false,
}
local P = {} -- host only: pawnAddress -> { off = {Pitch,Yaw,Roll}, held = fullname }

local Hooked = false
local EnsureHook

local function Log(msg)
    print("[GripAndFlip] " .. msg .. "\n")
end

local function GetMathLib()
    local ml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    if ml and ml:IsValid() then return ml end
    return nil
end

local function GetPlayerAndPawn()
    local pc = UEHelpers.GetPlayerController()
    if not pc or not pc:IsValid() then return nil, nil end
    local pawn = pc.Pawn
    if not pawn or not pawn:IsValid() then return nil, nil end
    return pc, pawn
end

local function GetHeld(pawn)
    local grab = pawn.PhysGrabData
    local target = grab.Target
    if target and target:IsValid() then return target end
    return nil
end

local function IsAuthority(pawn)
    local role = 3
    pcall(function()
        local r = pawn.Role
        if type(r) == "number" then role = r
        elseif type(r) == "userdata" then
            local okR, n = pcall(function() return r:get() end)
            if okR and type(n) == "number" then role = n end
        end
    end)
    return role == 3
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

-- world axis for a rotation mode, relative to a view yaw (degrees)
local function AxisFor(axisMode, yawDeg)
    if axisMode == "yaw" then return { X = 0, Y = 0, Z = 1 } end
    local cyaw = math.rad(yawDeg)
    if axisMode == "pitch" then
        return { X = -math.sin(cyaw), Y = math.cos(cyaw), Z = 0 }
    else
        return { X = math.cos(cyaw), Y = math.sin(cyaw), Z = 0 }
    end
end

local function ComposeInto(entry, ml, yawDeg, axisMode, deltaDeg)
    local delta = ml:RotatorFromAxisAndAngle(AxisFor(axisMode, yawDeg), deltaDeg)
    local o = entry.off
    local n = ml:ComposeRotators(
        { Pitch = o.Pitch, Yaw = o.Yaw, Roll = o.Roll },
        { Pitch = delta.Pitch, Yaw = delta.Yaw, Roll = delta.Roll })
    entry.off = { Pitch = n.Pitch, Yaw = n.Yaw, Roll = n.Roll }
end

local AXIS_CODE = { pitch = 1, roll = 2, yaw = 3 }

local function EnsureEntry(pawn, target)
    local addr = pawn:GetAddress()
    local tname = target:GetFullName()
    local e = P[addr]
    if not e or e.held ~= tname then
        e = { off = { Pitch = 0, Yaw = 0, Roll = 0 }, held = tname }
        P[addr] = e
    end
    return e
end

-- local input funnel: host applies, client transmits
local function ApplyInput(pc, pawn, axisMode, deltaDeg)
    local target = GetHeld(pawn)
    if not target then return end
    if IsAuthority(pawn) then
        local ml = GetMathLib()
        if not ml then return end
        local camRot = pc.PlayerCameraManager:GetCameraRotation()
        ComposeInto(EnsureEntry(pawn, target), ml, camRot.Yaw, axisMode, deltaDeg)
    else
        if not S.modeLogged then
            S.modeLogged = true
            Log("client mode: sending rotation to host (host must run Grip & Flip v16+). You'll see results when you drop/place the item.")
        end
        local d = math.max(-90, math.min(90, deltaDeg))
        pawn:PhysGrabRotate_Server(AXIS_CODE[axisMode] * 1e6 + d * 10)
    end
end

local function ResetTilt(pc, pawn)
    if S.rotMode then
        S.rotMode = false
        if pc and pc:IsValid() then pcall(function() pc:ResetIgnoreLookInput() end) end
    end
    if not pawn then return end
    if IsAuthority(pawn) then
        P[pawn:GetAddress()] = nil
    else
        pcall(function() pawn:PhysGrabRotate_Server(4 * 1e6) end)
    end
end

-- keybind taps
local function Tap(axisMode, dir, step)
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pc, pawn = GetPlayerAndPawn()
            if not pawn then return end
            if not GetHeld(pawn) then Log("skip: not holding") return end
            if not EnsureHook() then return end
            ApplyInput(pc, pawn, axisMode, step * dir)
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
            local pc, pawn = GetPlayerAndPawn()
            ResetTilt(pc, pawn)
            S.errCount = 0
        end)
    end)
end)

-- per-frame hook: local input capture (all machines) + application (host only)
local function TryRegisterHook()
    RegisterHook("/Game/Animation/ABP_HeldenPlayer.ABP_HeldenPlayer_C:BlueprintUpdateAnimation",
        function(self, DeltaTimeX)
            if S.errCount >= 8 then return end
            local ok, err = pcall(function()
                local inst = self:get()
                local pawn = inst:TryGetPawnOwner()
                if not pawn or not pawn:IsValid() then return end

                local pc, localPawn = GetPlayerAndPawn()
                local isLocal = localPawn and pawn:GetAddress() == localPawn:GetAddress()

                -- ===== local input capture (host and client alike) =====
                if isLocal then
                    local mask = ReadKeyMask()
                    local target = GetHeld(pawn)
                    local rHeld = target ~= nil and (mask & 16) ~= 0

                    if rHeld ~= S.rotMode then
                        S.rotMode = rHeld
                        if rHeld then pc:SetIgnoreLookInput(true)
                        else pc:ResetIgnoreLookInput() end
                    end

                    if target then
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
                end

                -- ===== application: host machine only, any player's pawn =====
                if IsAuthority(pawn) then
                    local addr = pawn:GetAddress()
                    local e = P[addr]
                    if e then
                        local target = GetHeld(pawn)
                        if not target or target:GetFullName() ~= e.held then
                            P[addr] = nil
                            return
                        end
                        if IsIdentity(e.off) then return end
                        local ml = GetMathLib()
                        if not ml then return end
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
                end
            end)
            if not ok then
                S.errCount = S.errCount + 1
                Log("frame ERROR (" .. S.errCount .. "/8): " .. tostring(err))
                if S.errCount >= 8 then
                    pcall(function()
                        local pc = UEHelpers.GetPlayerController()
                        if pc and pc:IsValid() then pc:ResetIgnoreLookInput() end
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
    end)
end)

-- host-side decoder: rotation commands from clients arrive as out-of-range
-- values in the game's own yaw RPC; decode, apply, neutralize the fake yaw
pcall(function()
    RegisterHook("/Script/Helden.HeldenCharacter:PhysGrabRotate_Server", function(self, InRight)
        pcall(function()
            local v = InRight:get()
            if math.abs(v) < MAGIC_MIN then return end -- normal Q/E traffic
            local pawn = self:get()
            if not IsAuthority(pawn) then return end   -- client send-side: pass through untouched
            local axisCode = math.floor(v / 1e6 + 0.5)
            local deltaDeg = (v - axisCode * 1e6) / 10

            if axisCode == 4 then
                P[pawn:GetAddress()] = nil
            else
                local axisMode = (axisCode == 1 and "pitch") or (axisCode == 2 and "roll") or "yaw"
                local target = GetHeld(pawn)
                if target then
                    local ml = GetMathLib()
                    if ml then
                        local viewYaw = 0
                        pcall(function() viewYaw = pawn:GetControlRotation().Yaw end)
                        ComposeInto(EnsureEntry(pawn, target), ml, viewYaw, axisMode, deltaDeg)
                    end
                end
            end

            -- neutralize the fake yaw so the native handler does nothing
            local okSet = pcall(function() InRight:set(0.0) end)
            if not okSet and not S.setParamWarned then
                S.setParamWarned = true
                Log("WARNING: could not zero RPC param - client rotations will also cause yaw jumps")
            end
        end)
    end)
end)

-- key poller (physical Alt/arrow state; engine-side key polling crashes this build)
local function FindPoller()
    local candidates = {
        "Mods\\GripAndFlip\\keypoll.ps1",
        "ue4ss\\Mods\\GripAndFlip\\keypoll.ps1",
        "..\\ue4ss\\Mods\\GripAndFlip\\keypoll.ps1",
    }
    for _, p in ipairs(candidates) do
        local f = io.open(p, "r")
        if f then f:close() return p end
    end
    return nil
end

local pollerPath = FindPoller()
if pollerPath then
    local okExec = pcall(function()
        os.execute('start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. pollerPath .. '"')
    end)
    Log(okExec and "key poller launched" or "WARNING: could not launch key poller - hold/Alt rotation unavailable")
else
    Log("WARNING: keypoll.ps1 not found - hold/Alt rotation unavailable (taps still work)")
end

RegisterKeyBind(Key.F7, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pc, pawn = GetPlayerAndPawn()
            if not pawn then Log("F7: no pawn") return end
            local target = GetHeld(pawn)
            Log("Holding: " .. (target and target:GetFullName() or "nothing"))
            Log("Authority: " .. tostring(IsAuthority(pawn)) .. " errs: " .. S.errCount)
            local n = 0
            for addr, e in pairs(P) do
                n = n + 1
                Log(string.format("  entry %d: P%.1f Y%.1f R%.1f held=%s", n, e.off.Pitch, e.off.Yaw, e.off.Roll, e.held))
            end
            if n == 0 then Log("  no active rotation entries") end
        end)
        if not ok then Log("F7 ERROR: " .. tostring(err)) end
    end)
end)

Log("v16 STAGE1 loaded. Host applies for all players; clients transmit via RPC. Alt+mouse / arrows / numpad as before.")
