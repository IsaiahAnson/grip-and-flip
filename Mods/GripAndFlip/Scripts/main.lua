-- GripAndFlip v12 - stable core + toggle-glide continuous rotation
--
-- Architecture (final, everything here is crash-proven in v10/v11 sessions):
--  * Native tick writes the phys-handle target yaw-only every frame (auto-upright).
--  * We keep a pitch/roll OFFSET, re-composed onto the handle target every frame
--    from the ABP_HeldenPlayer:BlueprintUpdateAnimation hook (runs after the
--    character tick, before physics - the game's own driver moves the object).
--  * Key-state polling (IsInputKeyDown) fatally crashes this UE4SS/5.7 combo
--    (null KeyDetails deref) - confirmed twice. So continuous rotation is a
--    TOGGLE: tap starts a smooth glide, tap again stops it. No polling anywhere.
--
-- Controls while holding an object:
--   Arrow tap         = 10-degree nudge + starts smooth glide (~100 deg/s)
--   Same arrow again  = stop glide
--   Other arrow       = nudge + redirect glide
--   Numpad 8/2/4/6    = precise 15-degree steps (no glide)
--   Numpad 5          = stop glide + clear tilt (vanilla upright)
--   Q/E               = native yaw, unchanged
--   F7                = debug dump

local UEHelpers = require("UEHelpers")

local TAP_STEP = 3.0    -- degrees per arrow tap (Q/E-like nudge)
local NUM_STEP = 15.0   -- degrees per numpad tap
local ROT_RATE = 100.0  -- degrees/second while an arrow is HELD (matches Q/E)

-- real held-key state, supplied by keypoll.ps1 (GetAsyncKeyState -> temp file);
-- read with plain Lua io - zero engine input calls, so nothing here can crash
local KEYFILE = os.getenv("TEMP") .. "\\GripAndFlip_keys.txt"
-- locate keypoll.ps1 relative to the game process working directory, so the
-- mod works from any install location (tries both common UE4SS layouts)
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

local function ReadKeyMask()
    local f = io.open(KEYFILE, "r")
    if not f then return 0 end
    local s = f:read("*a")
    f:close()
    return tonumber(s) or 0
end

local S = {
    engaged = false,
    offset = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 },
    animAddr = nil,
    errCount = 0,
    glideMode = nil, -- "pitch" | "roll" | nil
    glideDir = 0,
    rotMode = false, -- true while R is held (mouse rotates object, look frozen)
    mouseDbg = false,
}

local MOUSE_SENS = 0.8 -- degrees of object rotation per mouse unit

local Hooked = false
local EnsureHook -- defined below, used by keybinds above its definition

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

local function IsIdentity()
    local o = S.offset
    return math.abs(o.Pitch) < 0.01 and math.abs(o.Yaw) < 0.01 and math.abs(o.Roll) < 0.01
end

local function StopGlide()
    S.glideMode = nil
    S.glideDir = 0
end

local function Disengage(reason, pc)
    StopGlide()
    if S.rotMode then
        S.rotMode = false
        if pc and pc:IsValid() then pcall(function() pc:ResetIgnoreLookInput() end) end
    end
    if S.engaged then
        S.engaged = false
        S.offset = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
        S.animAddr = nil
        Log("tilt cleared (" .. reason .. ")")
    end
end

local function CamAxis(pc, axisMode)
    if axisMode == "yaw" then
        return { X = 0, Y = 0, Z = 1 }
    end
    local camRot = pc.PlayerCameraManager:GetCameraRotation()
    local cyaw = math.rad(camRot.Yaw)
    if axisMode == "pitch" then
        return { X = -math.sin(cyaw), Y = math.cos(cyaw), Z = 0 }
    else
        return { X = math.cos(cyaw), Y = math.sin(cyaw), Z = 0 }
    end
end

local function AddOffset(ml, pc, axisMode, deg)
    local delta = ml:RotatorFromAxisAndAngle(CamAxis(pc, axisMode), deg)
    local o = S.offset
    local n = ml:ComposeRotators(
        { Pitch = o.Pitch, Yaw = o.Yaw, Roll = o.Roll },
        { Pitch = delta.Pitch, Yaw = delta.Yaw, Roll = delta.Roll })
    S.offset = { Pitch = n.Pitch, Yaw = n.Yaw, Roll = n.Roll }
end

local function Engage(pawn)
    if S.engaged then return true end
    -- multiplayer: the HOST's machine owns held-object physics. As a joining
    -- client our local rotation just fights the server's yaw-only corrections
    -- (rigid/glitchy snap-back), so bow out cleanly instead.
    -- Role: 3 = Authority (host or singleplayer), 2 = AutonomousProxy (client)
    local role = 3
    pcall(function()
        local r = pawn.Role
        if type(r) == "number" then role = r
        elseif type(r) == "userdata" then
            local okR, n = pcall(function() return r:get() end)
            if okR and type(n) == "number" then role = n end
        end
    end)
    if role ~= 3 then
        if not S.mpWarned then
            S.mpWarned = true
            Log("Multiplayer client detected - Grip & Flip only works when you are the HOST (or in singleplayer). Rotation disabled for this session.")
        end
        return false
    end
    local ok = pcall(function()
        S.animAddr = pawn.Mesh.AnimScriptInstance:GetAddress()
    end)
    if not ok or not S.animAddr then Log("could not resolve anim instance") return false end
    S.engaged = true
    Log("tilt control engaged")
    return true
end

-- arrow tap: nudge + glide toggle. numpad: pure step (glide=false).
local function Tap(axisMode, dir, step, glide)
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pc, pawn = GetPlayerAndPawn()
            if not pawn then return end
            if not GetHeld(pawn) then Log("skip: not holding") return end
            if not EnsureHook() then return end
            if not Engage(pawn) then return end
            local ml = GetMathLib()
            if not ml then return end

            AddOffset(ml, pc, axisMode, step * dir)
        end)
        if not ok then Log("ERROR: " .. tostring(err)) end
    end)
end

RegisterKeyBind(Key.UP_ARROW, function() Tap("pitch", 1, TAP_STEP, true) end)
RegisterKeyBind(Key.DOWN_ARROW, function() Tap("pitch", -1, TAP_STEP, true) end)
RegisterKeyBind(Key.LEFT_ARROW, function() Tap("roll", 1, TAP_STEP, true) end)
RegisterKeyBind(Key.RIGHT_ARROW, function() Tap("roll", -1, TAP_STEP, true) end)
RegisterKeyBind(Key.NUM_EIGHT, function() Tap("pitch", 1, NUM_STEP, false) end)
RegisterKeyBind(Key.NUM_TWO, function() Tap("pitch", -1, NUM_STEP, false) end)
RegisterKeyBind(Key.NUM_FOUR, function() Tap("roll", 1, NUM_STEP, false) end)
RegisterKeyBind(Key.NUM_SIX, function() Tap("roll", -1, NUM_STEP, false) end)
RegisterKeyBind(Key.NUM_FIVE, function()
    ExecuteInGameThread(function()
        pcall(function()
            local pc = UEHelpers.GetPlayerController()
            Disengage("manual reset", pc)
            S.errCount = 0
        end)
    end)
end)

-- per-frame: integrate glide and re-compose the offset onto the game's fresh
-- yaw-only handle target (after character tick, before physics)
local function TryRegisterHook()
    RegisterHook("/Game/Animation/ABP_HeldenPlayer.ABP_HeldenPlayer_C:BlueprintUpdateAnimation",
        function(self, DeltaTimeX)
            if S.errCount >= 5 then return end
            local ok, err = pcall(function()
                if S.animAddr and self:get():GetAddress() ~= S.animAddr then return end

                -- physical key state from the poller file (pure Lua io)
                local mask = ReadKeyMask()
                -- engage lazily: either already engaged, or R is held (REPO mode)
                if not S.engaged and (mask & 16) == 0 then return end

                local pc, pawn = GetPlayerAndPawn()
                if not pawn then Disengage("no pawn") return end
                local target = GetHeld(pawn)
                if not target then Disengage("released", pc) return end
                if not S.engaged and not Engage(pawn) then return end
                local ml = GetMathLib()
                if not ml then return end

                -- true hold-to-rotate for the arrow keys
                if mask ~= 0 then
                    local dt = DeltaTimeX:get()
                    local step = ROT_RATE * dt
                    if (mask & 1) ~= 0 then AddOffset(ml, pc, "pitch", step) end
                    if (mask & 2) ~= 0 then AddOffset(ml, pc, "pitch", -step) end
                    if (mask & 4) ~= 0 then AddOffset(ml, pc, "roll", step) end
                    if (mask & 8) ~= 0 then AddOffset(ml, pc, "roll", -step) end
                end

                -- REPO-style rotate mode: hold Left Alt -> mouse rotates the
                -- object, camera look is frozen until Alt is released
                local rHeld = (mask & 16) ~= 0
                if rHeld ~= S.rotMode then
                    S.rotMode = rHeld
                    if rHeld then
                        pc:SetIgnoreLookInput(true)
                    else
                        pc:ResetIgnoreLookInput() -- hard reset: look-ignore is a counter
                    end
                end
                if rHeld then
                    -- UE4SS requires tables for out-params; value lands in the table
                    -- UE4SS fills both out-params into the first table, keyed by
                    -- parameter name (DeltaX / DeltaY) - discovered via debug log
                    local t1, t2 = {}, {}
                    pc:GetInputMouseDelta(t1, t2)
                    local dx = t1.DeltaX or t2.DeltaX
                    local dy = t1.DeltaY or t2.DeltaY
                    if type(dx) == "number" and type(dy) == "number" then
                        if dx ~= 0 then AddOffset(ml, pc, "yaw", -dx * MOUSE_SENS) end
                        if dy ~= 0 then AddOffset(ml, pc, "pitch", dy * MOUSE_SENS) end
                    end
                end

                if IsIdentity() then return end

                local handle = pawn.GrabPhysHandle
                if not handle or not handle:IsValid() then return end
                local outLoc, outRot = {}, {}
                handle:GetTargetLocationAndRotation(outLoc, outRot)
                local o = S.offset
                local final = ml:ComposeRotators(
                    { Pitch = outRot.Pitch, Yaw = outRot.Yaw, Roll = outRot.Roll },
                    { Pitch = o.Pitch, Yaw = o.Yaw, Roll = o.Roll })
                handle:SetTargetLocationAndRotation(
                    { X = outLoc.X, Y = outLoc.Y, Z = outLoc.Z },
                    { Pitch = final.Pitch, Yaw = final.Yaw, Roll = final.Roll })
            end)
            if not ok then
                S.errCount = S.errCount + 1
                Log("frame ERROR (" .. S.errCount .. "/5): " .. tostring(err))
                if S.errCount >= 5 then
                    -- never leave the camera frozen when bailing out
                    pcall(function()
                        local pc = UEHelpers.GetPlayerController()
                        if pc and pc:IsValid() then pc:ResetIgnoreLookInput() end
                    end)
                    S.rotMode = false
                    Log("too many errors - tilt disabled, Ctrl+R to retry")
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
        Log("hook registration failed (will retry on next press): " .. tostring(err))
    end
    return Hooked
end

EnsureHook() -- works immediately when (re)loading while already in-game

-- launch the key poller (singleton; exits itself when the game closes)
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
            Log(string.format("Engaged: %s offset P%.1f Y%.1f R%.1f glide %s errs %d",
                tostring(S.engaged), S.offset.Pitch, S.offset.Yaw, S.offset.Roll,
                tostring(S.glideMode), S.errCount))
        end)
        if not ok then Log("F7 ERROR: " .. tostring(err)) end
    end)
end)

Log("v15 loaded. Hold Left Alt + mouse = rotate held object (REPO-style). Arrows also work. Num5 = reset, F7 = debug.")
