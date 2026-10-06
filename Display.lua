-- Plainstride display: Blizzard's own interface art, put together the way Blizzard builds it.
-- Two layouts (db.layout): "two" (the stack bar with the cast bar under it, the default) or "one"
-- (the countdown runs inside the stack bar).
--
--   the bar    the profession skill bar (Professions-skillbar-bg/-frame) with the animated
--              Herbalism fill flipbook and its flare. Blizzard_ProfessionsTemplates is load on
--              demand, so the template itself is never used (loading a Blizzard addon taints it);
--              the same pieces are rebuilt here from its XML.
--   tick bar   (two bars) a real CastingBarFrameTemplate with its events and scripts switched off:
--              the client's own cast bar art, spark and finish / interrupt effects, driven by our
--              clocks. A plain look-alike stands in if the template cannot be made.
--   the tick   (one bar) lives in the stack bar: while you run the next segment fills toward your next stack
--              (a green glow over it, the cast bar's spark at its edge); when you stop your top
--              segment turns red (the cast bar's interrupted fill) and drains toward the loss.
--   streaks    wind lines racing through the filled part of the bar while you run, more of them
--              and faster the more stacks you have (the cast bar's channel wisp glow, stretched thin).
local ADDON, ns = ...

local D = {}
ns.Display = D

local MAX = ns.MAX_STACKS or 30
local BAR_W, BAR_H = 453, 29          -- ProfessionsRankBarTemplate
local FILL_W, FILL_H = 441, 18        -- its Fill
local FILL_X, FILL_Y = 5, -3
local TICK_H = 11                     -- the cast bar's natural height
local TOTAL_W = BAR_W
local TWO_BAR_H = 48                  -- the stack bar, a gap, and the cast bar under it

local STREAKS = 9

-- The profession bars' animated fills (Skillbar_Fill_Flipbook_<kit> plus its flare). Each flipbook
-- is two columns of 34 px frames; the row count comes from the atlas height when the client says,
-- else from this table (atlas sizes in build 1.60.1.70235). tint colours the wind streaks.
local FILLS = {
    { key = "herbalism", name = "Herbalism", rows = 30, tint = { 0.85, 1, 0.75 } },
    { key = "skinning", name = "Skinning", rows = 30, tint = { 0.75, 1, 0.95 } },
    { key = "leatherworking", name = "Leatherworking", rows = 30, tint = { 1, 0.85, 0.6 } },
    { key = "mining", name = "Mining", rows = 30, tint = { 0.9, 0.9, 1 } },
    { key = "blacksmithing", name = "Blacksmithing", rows = 30, tint = { 1, 0.75, 0.5 } },
    { key = "engineering", name = "Engineering", rows = 30, tint = { 1, 0.9, 0.6 } },
    { key = "alchemy", name = "Alchemy", rows = 30, tint = { 0.8, 1, 0.8 } },
    { key = "enchanting", name = "Enchanting", rows = 37, tint = { 0.9, 0.8, 1 } },
    { key = "tailoring", name = "Tailoring", rows = 30, tint = { 1, 0.85, 0.95 } },
    { key = "inscription", name = "Inscription", rows = 30, tint = { 0.85, 0.9, 1 } },
    { key = "jewelcrafting", name = "Jewelcrafting", rows = 22, tint = { 0.8, 0.95, 1 } },
    { key = "cooking", name = "Cooking", rows = 30, tint = { 1, 0.9, 0.7 } },
    { key = "fishing", name = "Fishing", rows = 30, tint = { 0.75, 0.9, 1 } },
}
D.FILLS = FILLS

local frame, stack, tick
local view = {
    shown = 0, tweenFrom = 0, tweenTo = 0, tweenStart = 0, tweenDur = 0,
    ghost = nil,
    barFrac = 0,
    mode = nil,
    segArt = nil,
    tickArt = nil,
    flowing = nil,
}
ns.view = view
D.view = view

local function db() return ns.db end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function easeOut(t) t = clamp(t, 0, 1) return 1 - (1 - t) * (1 - t) * (1 - t) end

-- The first font object this client has, so SetText never meets a font string without a font.
local function newFont(parent, layer, ...)
    local fs = parent:CreateFontString(nil, layer)
    for i = 1, select("#", ...) do
        local obj = _G[select(i, ...)]
        if obj and pcall(fs.SetFontObject, fs, obj) then return fs end
    end
    pcall(fs.SetFontObject, fs, GameFontHighlight)
    return fs
end

local function setAtlas(tex, atlas, useSize)
    if tex and tex.SetAtlas then
        local ok, res = pcall(tex.SetAtlas, tex, atlas, useSize)
        return ok and res ~= false
    end
    return false
end

------------------------------------------------------------------------
-- Animation helpers (the same building blocks Blizzard's XML uses)
------------------------------------------------------------------------
local function group(region, looping)
    local g = region:CreateAnimationGroup()
    if looping then g:SetLooping(looping) end
    if g.SetToFinalAlpha then g:SetToFinalAlpha(true) end
    return g
end

local function alpha(g, from, to, duration, order, delay, smoothing)
    local a = g:CreateAnimation("Alpha")
    a:SetFromAlpha(from)
    a:SetToAlpha(to)
    a:SetDuration(duration)
    a:SetOrder(order or 1)
    if delay then a:SetStartDelay(delay) end
    if smoothing then a:SetSmoothing(smoothing) end
    return a
end

local function translation(g, x, y, duration, order, delay, smoothing)
    local a = g:CreateAnimation("Translation")
    a:SetOffset(x, y)
    a:SetDuration(duration)
    a:SetOrder(order or 1)
    if delay then a:SetStartDelay(delay) end
    if smoothing then a:SetSmoothing(smoothing) end
    return a
end

local function scale(g, from, to, duration, order, delay)
    local a = g:CreateAnimation("Scale")
    if a.SetScaleFrom then
        a:SetScaleFrom(from, from)
        a:SetScaleTo(to, to)
    else
        a:SetFromScale(from, from)
        a:SetToScale(to, to)
    end
    a:SetDuration(duration)
    a:SetOrder(order or 1)
    if delay then a:SetStartDelay(delay) end
    return a
end

local function play(g)
    if g then
        g:Stop()
        g:Play()
    end
end

------------------------------------------------------------------------
-- The bar: Blizzard's profession skill bar with the Herbalism fill
------------------------------------------------------------------------
local function buildStackBar(parent)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(BAR_W, BAR_H)

    s.Background = s:CreateTexture(nil, "ARTWORK", nil, 1)
    setAtlas(s.Background, "Professions-skillbar-bg", true)
    s.Background:SetPoint("TOPLEFT")

    -- Where the fill sits. The fill itself always keeps its full size so the flipbook never
    -- stretches; a clipping frame as wide as the stacks shows only that much of it. (Blizzard uses
    -- a mask with CLAMPTOBLACKADDITIVE wrapping, which Lua cannot set reliably: without it the mask
    -- let the whole bar through.)
    s.FillArea = CreateFrame("Frame", nil, s)
    s.FillArea:SetSize(FILL_W, FILL_H)
    s.FillArea:SetPoint("TOPLEFT", FILL_X, FILL_Y)

    s.Clip = CreateFrame("Frame", nil, s)
    s.Clip:SetPoint("TOPLEFT", s.FillArea, "TOPLEFT", 0, 0)
    s.Clip:SetPoint("BOTTOMLEFT", s.FillArea, "BOTTOMLEFT", 0, 0)
    s.Clip:SetWidth(0.01)
    s.Clip:SetClipsChildren(true)
    s.Clip:SetFrameLevel(s:GetFrameLevel() + 1)

    s.Fill = s.Clip:CreateTexture(nil, "ARTWORK", nil, 2)
    s.Fill:SetSize(FILL_W, FILL_H)
    s.Fill:SetPoint("TOPLEFT", s.FillArea, "TOPLEFT", 0, 0)
    if not setAtlas(s.Fill, "skillbar_fill_flipbook_herbalism", false) then
        setAtlas(s.Fill, "Skillbar_Fill_Flipbook_DefaultBlue", false)
    end

    s.Streaks = {}
    for i = 1, STREAKS do
        local t = s.Clip:CreateTexture(nil, "ARTWORK", nil, 3)
        t:SetBlendMode("ADD")
        if not setAtlas(t, "Cast_Channel_WispGlow", false) then t:SetColorTexture(1, 1, 1, 0.5) end
        t:SetVertexColor(0.85, 1, 0.75)
        t:SetAlpha(0)
        t.lane = (i - 0.5) / STREAKS          -- spread over the height of the fill
        t.x = FILL_W * ((i * 0.618) % 1)      -- and along it, so they do not arrive together
        t.len = 40 + 50 * ((i * 0.37) % 1)
        t.pace = 0.75 + 0.5 * ((i * 0.53) % 1)
        s.Streaks[i] = t
    end

    s.Flare = s.Clip:CreateTexture(nil, "ARTWORK", nil, 3)
    s.Flare:SetSize(53, 16)
    s.Flare:SetBlendMode("ADD")
    setAtlas(s.Flare, "skillbar_flare_herbalism", false)
    s.Flare:SetPoint("RIGHT", s.Clip, "RIGHT", 0, 0)
    s.Flare:SetAlpha(0)

    -- above the fill: the tick segment, the lost chunk, the stack marks and the frame art
    s.Over = CreateFrame("Frame", nil, s)
    s.Over:SetAllPoints(s)
    s.Over:SetFrameLevel(s:GetFrameLevel() + 2)

    -- the segment being earned (green glow) or about to go (red), and the spark at its edge
    s.Seg = s.Over:CreateTexture(nil, "ARTWORK", nil, 2)
    s.Seg:SetHeight(FILL_H - 2)
    s.Seg:Hide()
    s.Spark = s.Over:CreateTexture(nil, "ARTWORK", nil, 7)
    setAtlas(s.Spark, "ui-castingbar-pip", false)
    s.Spark:SetSize(6, FILL_H + 6)
    s.Spark:Hide()
    s.SegFlash = s.Over:CreateTexture(nil, "ARTWORK", nil, 4)
    s.SegFlash:SetBlendMode("ADD")
    setAtlas(s.SegFlash, "ui-castingbar-full-glow-channel", false)
    s.SegFlash:SetHeight(FILL_H + 4)
    s.SegFlash:SetAlpha(0)

    -- what was just lost, lingering on top of the empty part of the bar
    s.Ghost = s.Over:CreateTexture(nil, "ARTWORK", nil, 3)
    s.Ghost:SetHeight(FILL_H - 2)
    s.Ghost:Hide()
    s.GhostFlash = s.Over:CreateTexture(nil, "ARTWORK", nil, 4)
    s.GhostFlash:SetBlendMode("ADD")
    setAtlas(s.GhostFlash, "ui-castingbar-full-glow-standard", false)
    s.GhostFlash:SetPoint("TOPLEFT", s.Ghost, "TOPLEFT", -2, 2)
    s.GhostFlash:SetPoint("BOTTOMRIGHT", s.Ghost, "BOTTOMRIGHT", 2, -2)
    s.GhostFlash:SetAlpha(0)

    -- one mark per stack, a pip on every fifth (the experience bar's own divider and pip)
    s.Dividers = {}
    for i = 1, MAX - 1 do
        local major = i % 5 == 0
        local t = s.Over:CreateTexture(nil, "ARTWORK", nil, 5)
        if major then
            setAtlas(t, "UI-HUD-ExperienceBar-Frame-Pip", false)
            t:SetSize(6, FILL_H + 4)
        else
            setAtlas(t, "UI-HUD-ExperienceBar-Divider", false)
            t:SetSize(2, FILL_H - 6)
            t:SetAlpha(0.7)
        end
        t:SetPoint("CENTER", s.FillArea, "LEFT", FILL_W * i / MAX, 0)
        s.Dividers[i] = t
    end

    -- where one hit would leave you: players report a hit halves your stacks
    s.HitMark = s.Over:CreateTexture(nil, "ARTWORK", nil, 7)
    if not setAtlas(s.HitMark, "ui-castingbar-pip-1x_red", false) then setAtlas(s.HitMark, "ui-castingbar-pip", false) end
    s.HitMark:SetSize(6, FILL_H + 8)
    s.HitMark:SetAlpha(0.85)
    s.HitMark:Hide()

    s.Border = s.Over:CreateTexture(nil, "ARTWORK", nil, 6)
    setAtlas(s.Border, "Professions-skillbar-frame", true)
    s.Border:SetPoint("TOPLEFT")

    -- hit: the cast bar's interrupt glow, stretched around this bar
    s.HitGlow = s:CreateTexture(nil, "BACKGROUND")
    s.HitGlow:SetBlendMode("ADD")
    setAtlas(s.HitGlow, "cast_interrupt_outerglow", false)
    s.HitGlow:SetPoint("TOPLEFT", s.FillArea, "TOPLEFT", -22, 18)
    s.HitGlow:SetPoint("BOTTOMRIGHT", s.FillArea, "BOTTOMRIGHT", 22, -18)
    s.HitGlow:SetAlpha(0)

    -- full: the bonus objective bar's starburst and sheen
    s.Starburst = s.Over:CreateTexture(nil, "OVERLAY", nil, 1)
    s.Starburst:SetBlendMode("ADD")
    setAtlas(s.Starburst, "bonusobjectives-bar-starburst", false)
    s.Starburst:SetSize(54, 54)
    s.Starburst:SetPoint("CENTER", s.FillArea, "RIGHT", 0, 0)
    s.Starburst:SetAlpha(0)
    s.Sheen = s.Over:CreateTexture(nil, "OVERLAY")
    s.Sheen:SetBlendMode("ADD")
    setAtlas(s.Sheen, "bonusobjectives-bar-sheen", false)
    s.Sheen:SetSize(97, FILL_H + 4)
    s.Sheen:SetPoint("LEFT", s.FillArea, "LEFT", -60, 0)
    s.Sheen:SetAlpha(0)

    local textHolder = CreateFrame("Frame", nil, s)
    textHolder:SetAllPoints(s.FillArea)
    textHolder:SetFrameLevel(s:GetFrameLevel() + 5)
    s.Text = newFont(textHolder, "OVERLAY", "Number12FontOutline", "GameFontHighlightOutline", "GameFontHighlight")
    s.Text:SetPoint("CENTER", s.FillArea, "CENTER", 0, 0)
    s.Text:SetJustifyH("CENTER")
    s.Timer = newFont(textHolder, "OVERLAY", "Number12FontOutline", "GameFontHighlightSmall", "GameFontHighlight")
    s.Timer:SetPoint("RIGHT", s.FillArea, "RIGHT", -6, 0)
    s.Timer:SetJustifyH("RIGHT")

    -- animations
    s.FillAnim = group(s.Fill, "REPEAT")
    do
        local fb = s.FillAnim:CreateAnimation("FlipBook")
        fb:SetDuration(2.0)
        fb:SetFlipBookRows(30)
        fb:SetFlipBookColumns(2)
        fb:SetFlipBookFrames(60)
        fb:SetFlipBookFrameWidth(0)
        fb:SetFlipBookFrameHeight(0)
        s.FlipBook = fb
    end
    s.FlareFadeOut = group(s.Flare)
    alpha(s.FlareFadeOut, 1, 0, 1.0, 1, nil, "OUT")
    s.GhostFlashAnim = group(s.GhostFlash)
    alpha(s.GhostFlashAnim, 0, 1, 0.05, 1)
    alpha(s.GhostFlashAnim, 1, 0, 0.45, 2, nil, "OUT")
    s.HitGlowAnim = group(s.HitGlow)
    alpha(s.HitGlowAnim, 0, 1, 0.0, 1)
    alpha(s.HitGlowAnim, 1, 0, 1.0, 2)
    s.SegFlashAnim = group(s.SegFlash)
    alpha(s.SegFlashAnim, 0, 1, 0.05, 1)
    alpha(s.SegFlashAnim, 1, 0, 0.5, 2, nil, "OUT")
    s.MaxAnim = group(s.Starburst)
    scale(s.MaxAnim, 1, 0.5, 0.1, 1)
    scale(s.MaxAnim, 1, 2, 0.5, 1, 0.34)
    alpha(s.MaxAnim, 0, 1, 0.1, 1, 0.34)
    alpha(s.MaxAnim, 1, 0, 0.9, 1, 0.44)
    do
        local r = s.MaxAnim:CreateAnimation("Rotation")
        r:SetDegrees(-76)
        r:SetDuration(1.41)
        r:SetOrder(1)
    end
    s.SheenAnim = group(s.Sheen)
    translation(s.SheenAnim, FILL_W + 60, 0, 0.6, 1, 0, "IN_OUT")
    alpha(s.SheenAnim, 0, 1, 0.1, 1)
    alpha(s.SheenAnim, 1, 0, 0.2, 1, 0.45)
    return s
end

------------------------------------------------------------------------
-- The tick bar (two-bar layout): the client's cast bar
------------------------------------------------------------------------
local function buildFallbackTick(parent)
    local b = CreateFrame("StatusBar", nil, parent)
    b:SetStatusBarTexture("ui-castingbar-filling-standard")
    b.Background = b:CreateTexture(nil, "BACKGROUND", nil, 2)
    setAtlas(b.Background, "ui-castingbar-background", false)
    b.Background:SetPoint("TOPLEFT", -1, 1)
    b.Background:SetPoint("BOTTOMRIGHT", 1, -1)
    b.Border = b:CreateTexture(nil, "ARTWORK", nil, 4)
    setAtlas(b.Border, "ui-castingbar-frame", false)
    b.Border:SetPoint("TOPLEFT", -2, 2)
    b.Border:SetPoint("BOTTOMRIGHT", 2, -2)
    b.Flash = b:CreateTexture(nil, "OVERLAY", nil, 1)
    b.Flash:SetBlendMode("ADD")
    setAtlas(b.Flash, "ui-castingbar-full-glow-standard", false)
    b.Flash:SetPoint("TOPLEFT", -1, 1)
    b.Flash:SetPoint("BOTTOMRIGHT", 1, -1)
    b.Spark = b:CreateTexture(nil, "OVERLAY", nil, 2)
    setAtlas(b.Spark, "ui-castingbar-pip", false)
    b.Spark:SetSize(8, 20)
    b.Text = newFont(b, "OVERLAY", "GameFontHighlightSmall", "GameFontHighlight")
    b.fallback = true
    return b
end

-- A real CastingBarFrameTemplate (Blizzard_UIPanels_Game, loaded at startup) with its events and
-- scripts switched off; a plain look-alike if the template cannot be made.
local function buildTickBar(parent)
    local ok, b = pcall(CreateFrame, "StatusBar", nil, parent, "CastingBarFrameTemplate")
    if not ok or not b then
        b = buildFallbackTick(parent)
    else
        -- ours now: no unit, no events, no Blizzard update loop
        if b.SetUnit then pcall(b.SetUnit, b, nil) end
        b:UnregisterAllEvents()
        b:SetScript("OnEvent", nil)
        b:SetScript("OnUpdate", nil)
        b:SetScript("OnShow", nil)
        b.playCastFX = true
        for _, key in ipairs({ "TextBorder", "Icon", "BorderShield", "DropShadow", "CastTimeText" }) do
            if b[key] then b[key]:Hide() end
        end
        if b.BorderMask then b.BorderMask:SetSize(FILL_W + 16, 13) end
        if b.EnergyMask then pcall(b.EnergyMask.SetWidth, b.EnergyMask, FILL_W) end
        b.templated = true
    end
    b:SetMinMaxValues(0, 1)
    b:SetValue(0)
    b:SetSize(FILL_W, TICK_H)
    if b.Flash then
        b.Flash:SetAlpha(0)
        b.Flash:Show()
    end
    b.FlashFade = group(b.Flash)
    alpha(b.FlashFade, 0, 1, 0.05, 1)
    alpha(b.FlashFade, 1, 0, 0.5, 2, nil, "OUT")
    if b.Text then
        b.Text:ClearAllPoints()
        b.Text:SetPoint("CENTER", b, "CENTER", 0, 0)
        b.Text:SetSize(FILL_W, 16)
        b.Text:SetJustifyH("CENTER")
        b.Text:Show()
    end
    return b
end

local TICK_ART = {
    gain = { fill = "ui-castingbar-filling-channel", glow = "ui-castingbar-full-glow-channel", sparkFx = "ChannelShadow" },
    decay = { fill = "ui-castingbar-filling-standard", glow = "ui-castingbar-full-glow-standard", sparkFx = "StandardGlow" },
    urgent = { fill = "ui-castingbar-interrupted", glow = "ui-castingbar-full-glow-standard", sparkFx = "StandardGlow" },
    max = { fill = "ui-castingbar-full-channel", glow = "ui-castingbar-full-glow-channel" },
    idle = { fill = "ui-castingbar-filling-standard", glow = "ui-castingbar-full-glow-standard" },
}

local function setTickArt(key)
    if view.tickArt == key then return end
    view.tickArt = key
    local art = TICK_ART[key]
    tick:SetStatusBarTexture(art.fill)
    if tick.Flash then setAtlas(tick.Flash, art.glow, false) end
    for _, fx in ipairs({ "StandardGlow", "ChannelShadow", "CraftGlow" }) do
        if tick[fx] then tick[fx]:SetShown(fx == art.sparkFx) end
    end
end

local function oneBar()
    return db().layout == "one"
end

-- The tick segment's look: a green glow while earning, the cast bar's red fill while losing.
local function setSegArt(kind)
    if view.segArt == kind then return end
    view.segArt = kind
    local seg = stack.Seg
    if kind == "decay" then
        setAtlas(seg, "ui-castingbar-interrupted", false)
        seg:SetBlendMode("BLEND")
        seg:SetVertexColor(1, 1, 1)
    else
        setAtlas(seg, "Cast_Channel_WispGlow", false)
        seg:SetBlendMode("ADD")
        seg:SetVertexColor(0.8, 1, 0.7)
    end
end

------------------------------------------------------------------------
-- The fill texture
------------------------------------------------------------------------
function D.FillInfo(key)
    for _, f in ipairs(FILLS) do
        if f.key == key then return f end
    end
    return FILLS[1]
end

-- The empty part of the bars: the profession bar's background, and the cast bar's under it.
function D.ApplyBackground()
    if not stack then return end
    local a = clamp(db().bgAlpha or 1, 0, 1)
    stack.Background:SetAlpha(a)
    if tick and tick.Background then tick.Background:SetAlpha(a) end
end

function D.ApplyFill()
    if not stack then return end
    local info = D.FillInfo(db().fill)
    local atlas = "skillbar_fill_flipbook_" .. info.key
    if not setAtlas(stack.Fill, atlas, false) then
        info = FILLS[1]
        atlas = "skillbar_fill_flipbook_" .. info.key
        setAtlas(stack.Fill, atlas, false)
    end
    setAtlas(stack.Flare, "skillbar_flare_" .. info.key, false)
    local rows = info.rows
    if C_Texture and C_Texture.GetAtlasInfo then
        local ok, a = pcall(C_Texture.GetAtlasInfo, atlas)
        if ok and type(a) == "table" and type(a.height) == "number" and a.height >= 34 then
            rows = math.floor(a.height / 34 + 0.5)
        end
    end
    stack.FillAnim:Stop()
    stack.FlipBook:SetFlipBookRows(rows)
    stack.FlipBook:SetFlipBookFrames(rows * 2)
    view.flowing = nil -- Render starts the flipbook again if you are running
    for _, t in ipairs(stack.Streaks) do t:SetVertexColor(info.tint[1], info.tint[2], info.tint[3]) end
end

------------------------------------------------------------------------
-- Hover tooltip
------------------------------------------------------------------------
local function fillTooltip()
    local st = ns.state
    local stacks = st.stacks or 0
    local mode, _, left = ns.clocks(GetTime(), st.stacks)
    if ns.inCombat() then mode = "combat" end
    GameTooltip:ClearLines()
    GameTooltip:AddDoubleLine("Plainsrunning", string.format("%d / %d stacks (+%d%% speed)", stacks, MAX, stacks), 1, 0.82, 0, 1, 1, 1)
    if mode == "gain" and left then
        GameTooltip:AddLine(string.format("Next stack in %.1f s", left), 0.56, 0.94, 0.48)
    elseif mode == "decay" and left then
        GameTooltip:AddLine(string.format("Losing a stack in %.1f s", left), 1, 0.35, 0.23)
    elseif mode == "max" then
        GameTooltip:AddLine("Full speed", 1, 0.82, 0)
    elseif mode == "combat" then
        GameTooltip:AddLine("In combat: the count is from before the fight", 0.7, 0.7, 0.7, true)
    end
    if stacks >= 2 then
        GameTooltip:AddLine(string.format("A hit would leave you about %d", math.floor(stacks / 2)), 1, 0.35, 0.23)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("+1% speed for every 5 seconds of moving, up to +30%.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("Standing still: about a second's grace, then 1 stack a second.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("A hit halves your stacks (as players report it). Stacks still build in combat if nothing hits you.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end

local function onEnter(self)
    if db().tooltip == false then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    view.tipShown = true
    view.tipAt = 0
    fillTooltip()
end

local function onLeave()
    if view.tipShown then GameTooltip:Hide() end
    view.tipShown = false
end

------------------------------------------------------------------------
-- Building, layout, lock
------------------------------------------------------------------------
local function savePosition()
    local p, _, rp, x, y = frame:GetPoint(1)
    if p then db().point = { p, "UIParent", rp, x, y } end
end

local function docked()
    return db().dock and PlayerFrame ~= nil
end

-- Locked (or docked): clicks go through the bar; with the tooltip on, the mouse still hovers it.
function D.ApplyLock()
    if not frame then return end
    local movable = not db().locked and not docked()
    frame:EnableMouse(movable)
    if not movable and db().tooltip ~= false then
        if frame.SetMouseMotionEnabled then pcall(frame.SetMouseMotionEnabled, frame, true) end
        if frame.SetMouseClickEnabled then pcall(frame.SetMouseClickEnabled, frame, false) end
    end
    frame.Unlocked:SetShown(movable)
end

-- Docked: under the player frame, as wide as it; otherwise where you dragged it.
function D.ApplyPosition()
    if not frame then return end
    frame:ClearAllPoints()
    if docked() then
        local pw = PlayerFrame:GetWidth() or 0
        local ps = PlayerFrame:GetEffectiveScale() or 1
        local us = UIParent:GetEffectiveScale() or 1
        local scale = 0.75
        if pw > 0 and us > 0 then scale = clamp(pw * ps * 0.92 / (TOTAL_W * us), 0.3, 2) end
        frame:SetScale(scale)
        frame:SetPoint("TOP", PlayerFrame, "BOTTOM", 0, 2)
    else
        frame:SetScale(clamp(db().scale or 0.75, 0.4, 2))
        local p = db().point or ns.defaults.point
        frame:SetPoint(p[1], UIParent, p[3], p[4], p[5])
    end
end

function D.Layout()
    if not frame then return end
    D.ApplyPosition()
    D.ApplyLock()
    local one = oneBar()
    frame:SetSize(TOTAL_W, one and BAR_H or TWO_BAR_H)
    tick:SetShown(not one)
    if one then
        if tick.Flash then tick.Flash:SetAlpha(0) end
    else
        stack.Seg:Hide()
        stack.Spark:Hide()
        stack.Timer:SetText("")
    end
end

function D.Build()
    local p = db().point or ns.defaults.point
    frame = CreateFrame("Frame", "PlainstrideFrame", UIParent)
    D.frame = frame
    frame:SetSize(TOTAL_W, TWO_BAR_H)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) if not db().locked and not docked() then self:StartMoving() end end)
    frame:SetScript("OnEnter", onEnter)
    frame:SetScript("OnLeave", onLeave)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() savePosition() end)
    frame:SetPoint(p[1], UIParent, p[3], p[4], p[5])

    -- the Edit Mode selection look while unlocked
    frame.Unlocked = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    if not setAtlas(frame.Unlocked, "editmode-actionbar-highlight-nineslice-center", false) then
        frame.Unlocked:SetColorTexture(0.2, 0.5, 1, 0.25)
    end
    frame.Unlocked:SetPoint("TOPLEFT", -6, 6)
    frame.Unlocked:SetPoint("BOTTOMRIGHT", 6, -6)

    -- everything that shakes lives on `content`; `frame` stays where you put it
    local content = CreateFrame("Frame", nil, frame)
    content:SetAllPoints(frame)
    D.content = content
    D.Shake = group(content)
    D.ShakeSteps = {}
    for i = 1, 6 do
        D.ShakeSteps[i] = translation(D.Shake, 0, 0, 0.0, i + 1, 0.05)
    end
    translation(D.Shake, 0, 0, 0.1, 1)

    stack = buildStackBar(content)
    stack:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    D.stack = stack
    setSegArt("gain")
    D.ApplyFill()

    tick = buildTickBar(content)
    tick:SetPoint("TOPLEFT", stack, "TOPLEFT", FILL_X, -33)
    D.tick = tick

    -- floating loss on a hit, Blizzard combat text style
    local floatHolder = CreateFrame("Frame", nil, content)
    floatHolder:SetAllPoints(content)
    floatHolder:SetFrameLevel(content:GetFrameLevel() + 10)
    D.Float = newFont(floatHolder, "OVERLAY", "CombatTextFont", "GameFontNormalHuge", "GameFontNormalLarge")
    D.Float:SetTextColor(1, 0.12, 0.08)
    D.Float:SetPoint("BOTTOM", stack.FillArea, "TOP", 0, 2)
    D.Float:SetAlpha(0)
    D.FloatAnim = group(D.Float)
    alpha(D.FloatAnim, 0, 1, 0.08, 1)
    scale(D.FloatAnim, 1.6, 1, 0.2, 1)
    translation(D.FloatAnim, 0, 26, 1.0, 1, 0, "OUT")
    alpha(D.FloatAnim, 1, 0, 0.5, 1, 0.5)

    D.Layout()
    D.ApplyLock()
    D.ApplyBackground()
    D.Snap(0)
end

------------------------------------------------------------------------
-- Changes
------------------------------------------------------------------------
function D.Snap(n)
    view.shown, view.tweenFrom, view.tweenTo, view.tweenDur = n or 0, n or 0, n or 0, 0
    view.ghost = nil
end

local function shake(amp)
    if not D.Shake then return end
    local steps = { { -1, 1 }, { 1, -2 }, { 1, 2 }, { -1, -1 }, { 1, 1 }, { -1, -1 } }
    for i, step in ipairs(steps) do
        D.ShakeSteps[i]:SetOffset(step[1] * amp, step[2] * amp)
    end
    play(D.Shake)
end

function D.Animate(from, to, kind, now)
    if not frame then return end
    if to > from then
        if to - from == 1 and oneBar() then
            -- the segment had already filled up as the tick ran: it simply becomes a stack
            D.Snap(to)
        else
            view.tweenFrom, view.tweenTo, view.tweenStart = view.shown, to, now
            view.tweenDur = 0.5 -- Blizzard's rank bar interpolates over half a second, easing out
        end
        -- the new stack's segment flashes with the cast bar's channel glow
        stack.SegFlash:ClearAllPoints()
        stack.SegFlash:SetPoint("LEFT", stack.FillArea, "LEFT", FILL_W * (to - 1) / MAX - 2, 0)
        stack.SegFlash:SetWidth(FILL_W / MAX + 4)
        play(stack.SegFlashAnim)
        if to >= MAX then
            stack.Flare:SetAlpha(0)
            play(stack.MaxAnim)
            play(stack.SheenAnim)
        else
            stack.FlareFadeOut:Stop()
            stack.Flare:SetAlpha(1)
            play(stack.FlareFadeOut)
        end
        if not oneBar() then
            play(tick.FlashFade)
            if tick.ChannelFinish and to < MAX then play(tick.ChannelFinish) end
        end
        return
    end
    -- losses: the fill drops at once and what was lost lingers as a ghost, then drains away
    local top = math.max(view.shown, from)
    if view.ghost and view.ghost.from > top then top = view.ghost.from end
    D.Snap(to)
    if kind == "hit" then
        local lost = from - to
        view.ghost = { from = top, to = to, start = now, hold = 0.45, dur = 0.55, atlas = "ui-castingbar-interrupted" }
        play(stack.GhostFlashAnim)
        play(stack.HitGlowAnim)
        if not oneBar() and tick.InterruptGlowAnim then play(tick.InterruptGlowAnim) end
        shake(1 + math.min(lost, 10) * 0.25)
        D.Float:SetText("-" .. lost)
        play(D.FloatAnim)
    elseif oneBar() then
        -- the red segment has already drained: a short ember where it was
        view.ghost = { from = top, to = to, start = now, hold = 0, dur = 0.3, atlas = "ui-castingbar-interrupted" }
    else
        view.ghost = { from = top, to = to, start = now, hold = 0.1, dur = 0.4, atlas = "ui-castingbar-filling-standard" }
        play(tick.FlashFade)
    end
    setAtlas(stack.Ghost, view.ghost.atlas, false)
end

------------------------------------------------------------------------
-- Every frame
------------------------------------------------------------------------
function D.Render(now)
    if not frame then return end
    local state = ns.state
    local cfg = db()

    -- the stack value
    if view.tweenDur > 0 then
        local t = (now - view.tweenStart) / view.tweenDur
        view.shown = view.tweenFrom + (view.tweenTo - view.tweenFrom) * easeOut(t)
        if t >= 1 then view.tweenDur, view.shown = 0, view.tweenTo end
    end
    local shown = clamp(view.shown, 0, MAX)

    -- the tick, in the bar itself
    local stacks = state.stacks
    local mode, frac, left = ns.clocks(now, stacks)
    if ns.inCombat() and not state.demo then
        mode, frac, left = "combat", 0, nil -- the count is frozen: no countdown to show
    end
    view.mode = mode
    if math.abs(frac - view.barFrac) > 0.5 then view.barFrac = frac
    else view.barFrac = view.barFrac + (frac - view.barFrac) * 0.5 end
    local bf = clamp(view.barFrac, 0, 1)
    local one = oneBar()
    local segLo, segHi, fillTo = nil, nil, shown
    if not one then
        -- two bars: the stack bar shows whole stacks, the cast bar below shows the tick
    elseif mode == "gain" and shown < MAX and view.tweenDur == 0 then
        segLo, segHi = shown, math.min(MAX, shown + bf)
        fillTo = segHi
    elseif mode == "decay" and shown >= 1 then
        segLo, segHi = shown - 1, shown - 1 + bf
        fillTo = segHi
    end
    view.fillTo = fillTo
    if segLo and segHi - segLo > 0.01 then
        setSegArt(mode)
        if mode == "decay" then
            stack.Seg:SetAlpha(0.85)
        else
            local pulse = math.sin(now * 6)
            stack.Seg:SetAlpha(0.35 + 0.25 * pulse * pulse)
        end
        stack.Seg:ClearAllPoints()
        stack.Seg:SetPoint("LEFT", stack.FillArea, "LEFT", FILL_W * segLo / MAX, 0)
        stack.Seg:SetWidth(math.max(0.5, FILL_W * (segHi - segLo) / MAX))
        stack.Seg:Show()
        stack.Spark:ClearAllPoints()
        stack.Spark:SetPoint("CENTER", stack.FillArea, "LEFT", FILL_W * segHi / MAX, 0)
        stack.Spark:Show()
    else
        stack.Seg:Hide()
        stack.Spark:Hide()
    end

    local p = fillTo / MAX
    if p > 0 then
        stack.Fill:Show()
        stack.Clip:SetWidth(math.max(0.01, FILL_W * p))
    else
        stack.Fill:Hide()
        stack.Clip:SetWidth(0.01)
        stack.Flare:SetAlpha(0)
    end

    -- the ghost of what was lost
    local g = view.ghost
    if g then
        local t = now - g.start
        if t >= g.hold + g.dur then
            view.ghost = nil
            stack.Ghost:Hide()
        else
            local drain = t <= g.hold and 0 or easeOut((t - g.hold) / g.dur)
            local top = g.from + (g.to - g.from) * drain
            local w = FILL_W * (top - shown) / MAX
            if w > 0.5 then
                stack.Ghost:ClearAllPoints()
                stack.Ghost:SetPoint("LEFT", stack.FillArea, "LEFT", FILL_W * shown / MAX, 0)
                stack.Ghost:SetWidth(w)
                stack.Ghost:SetAlpha(1 - 0.5 * drain)
                stack.Ghost:Show()
            else
                stack.Ghost:Hide()
            end
        end
    end

    -- wind streaks: only while running, more and faster with more stacks
    local dt = math.min(0.1, now - (view.lastFrame or now))
    view.lastFrame = now
    local power = (state.moving and (stacks or 0) > 0) and ((stacks or 0) / MAX) or 0
    view.wind = (view.wind or 0) + (power - (view.wind or 0)) * math.min(1, dt * 3)
    if cfg.streaks == false then view.wind = 0 end -- switched off: gone at once
    local wind = view.wind
    local edge = FILL_W * fillTo / MAX
    -- right (default): the bar surging toward the next stack; left: wind rushing past you
    local rightward = cfg.streakDir ~= "left"
    for i, t in ipairs(stack.Streaks) do
        local active = wind > 0.02 and i <= math.ceil(STREAKS * (0.3 + 0.7 * wind))
        if active and edge > 8 then
            local step = dt * (120 + 520 * wind) * t.pace
            if rightward then
                t.x = t.x + step
                if t.x > edge then
                    t.x = -t.len - 10 * ((i * 0.29) % 1) -- back in from the left end
                end
            else
                t.x = t.x - step
                if t.x + t.len < 0 then
                    t.x = edge + 10 * ((i * 0.29) % 1)
                end
                if t.x > edge then t.x = edge end
            end
            t:ClearAllPoints()
            t:SetPoint("LEFT", stack.FillArea, "BOTTOMLEFT", t.x, 3 + (FILL_H - 6) * t.lane)
            t:SetSize(t.len * (0.6 + 0.6 * wind), 2 + wind)
            t:SetAlpha(0.15 + 0.6 * wind)
        else
            t:SetAlpha(0)
        end
    end

    -- the fill flows while you run and rests while you stand
    local flowing = state.moving and (stacks or 0) > 0
    if flowing ~= view.flowing then
        view.flowing = flowing
        if flowing then stack.FillAnim:Play() else stack.FillAnim:Stop() end
    end

    -- where one hit would leave you
    if cfg.hitMarker ~= false and (stacks or 0) >= 2 then
        stack.HitMark:ClearAllPoints()
        stack.HitMark:SetPoint("CENTER", stack.FillArea, "LEFT", FILL_W * math.floor(stacks / 2) / MAX, 0)
        stack.HitMark:Show()
    else
        stack.HitMark:Hide()
    end

    if view.tipShown and now - (view.tipAt or 0) > 0.25 then
        view.tipAt = now
        fillTooltip()
    end

    -- texts: the count in the middle, the countdown at the right end
    if cfg.showCount == false then
        stack.Text:SetText("")
    elseif stacks then
        stack.Text:SetText(string.format("Plainsrunning  %d / %d", stacks, MAX))
    else
        stack.Text:SetText("Plainsrunning")
    end
    local text = ""
    if one and cfg.showTimer then
        if mode == "combat" then
            text = "|cffaaaaaaIn combat|r"
        elseif mode == "max" then
            text = "|cffffd100MAX|r"
        elseif mode == "gain" then
            text = (left and left > 0) and string.format("|cff8ff07a+1|r %.1f", left) or "|cff8ff07a+1|r"
        elseif mode == "decay" then
            text = (left and left > 0) and string.format("|cffff5a3a-1|r %.1f", left) or "|cffff5a3a-1|r"
        end
    end
    stack.Timer:SetText(text)

    -- the cast bar (two bars)
    if not one then
        local art = mode
        if mode == "decay" and left and left < 0.35 then art = "urgent" end
        if mode == "hold" then art = "gain" end
        setTickArt(TICK_ART[art] and art or "idle")
        tick:SetValue(bf)
        local sparkOn = (mode == "gain" or mode == "decay") and bf > 0.01 and bf < 0.99
        if tick.Spark then
            tick.Spark:ClearAllPoints()
            tick.Spark:SetPoint("CENTER", tick, "LEFT", FILL_W * bf, 0)
            tick.Spark:SetShown(sparkOn)
        end
        if tick.Text then
            local t = ""
            if cfg.showTimer then
                if mode == "combat" then
                    t = "In combat"
                elseif mode == "max" then
                    t = "Full speed"
                elseif mode == "gain" then
                    t = (left and left > 0) and string.format("Next stack  %.1f", left) or "Next stack"
                elseif mode == "decay" then
                    t = (left and left > 0) and string.format("Losing a stack  %.1f", left) or "Losing a stack"
                elseif state.source == "demo" then
                    t = "Demo"
                end
            end
            tick.Text:SetText(t)
        end
    end

    -- quiet when there is nothing to show: dimmed, or (fadeEmpty) faded right out. Setting off
    -- brings it back at once, since the first stack's countdown starts then. While unlocked it
    -- never fades below half, so it can still be found and dragged.
    local idle = (stacks or 0) <= 0 and not state.moving and not ns.inCombat() and not state.demo
    local target = 1
    if idle then target = cfg.fadeEmpty and 0 or (cfg.idleAlpha or 0.45) end
    if not cfg.locked then target = math.max(target, 0.5) end
    local a = view.alpha or target
    if target < a then
        a = math.max(target, a - dt / 0.8)  -- fade out over most of a second
    else
        a = math.min(target, a + dt / 0.15) -- and back in quickly
    end
    view.alpha = a
    frame:SetAlpha(a)
end
