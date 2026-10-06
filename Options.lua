-- Plainstride options: a page in the game's Options > AddOns list, a standalone window when that
-- page cannot be opened (in combat, or if the client refuses), and a minimap button.
--
-- The page is a canvas page only. Proxy settings (Settings.RegisterProxySetting) tainted Blizzard's
-- nameplates on WoW Forever, so every control here is our own and writes our own saved table.
local ADDON, ns = ...

local O = {}
ns.Options = O

local TITLE = "Plainstride"
local ICON = 236717 -- Plainsrunning's own icon (SpellMisc.SpellIconFileDataID)
local W, H = 600, 420

local content, window, settingsPage, settingsCategory
local nativeOpenFailed = false
local refreshers = {}

local function db() return ns.db end
local function print(msg) ns.print(msg) end

local function TryCreate(kind, name, parent, templates)
    for _, template in ipairs(templates) do
        local ok, made = pcall(CreateFrame, kind, name, parent, template)
        if ok and made then return made, template end
    end
    return CreateFrame(kind, name, parent), "bare"
end

local function Refresh()
    for _, refresh in ipairs(refreshers) do refresh() end
end
O.Refresh = Refresh

------------------------------------------------------------------------
-- Controls
------------------------------------------------------------------------
local function Check(parent, label, x, y, get, set, tip)
    local cb = TryCreate("CheckButton", nil, parent, { "UICheckButtonTemplate", "ChatConfigCheckButtonTemplate" })
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", x, y)
    cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    cb.label:SetText(label)
    if tip then
        cb.tip = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        cb.tip:SetPoint("TOPLEFT", cb.label, "BOTTOMLEFT", 0, -2)
        cb.tip:SetWidth(250)
        cb.tip:SetJustifyH("LEFT")
        cb.tip:SetText(tip)
    end
    cb:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        Refresh()
    end)
    refreshers[#refreshers + 1] = function() cb:SetChecked(get() and true or false) end
    return cb
end

local sliderCount = 0
local function Slider(parent, label, x, y, width, minV, maxV, step, get, set, fmt)
    sliderCount = sliderCount + 1
    local name = "PlainstrideOptionsSlider" .. sliderCount
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetPoint("TOPLEFT", x, y)
    holder:SetSize(width, 42)
    local caption = holder:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    caption:SetPoint("TOPLEFT", 0, 0)
    caption:SetText(label)
    local value = holder:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    value:SetPoint("TOPRIGHT", 0, 0)

    local slider = TryCreate("Slider", name, holder, { "MinimalSliderTemplate", "UISliderTemplate", "OptionsSliderTemplate" })
    for _, suffix in ipairs({ "Low", "High", "Text" }) do
        local extra = _G[name .. suffix]
        if extra then extra:SetText("") extra:Hide() end
    end
    if slider.SetOrientation then slider:SetOrientation("HORIZONTAL") end
    slider:SetPoint("TOPLEFT", 2, -18)
    slider:SetSize(width - 4, 18)
    slider:SetMinMaxValues(minV, maxV)
    if slider.SetValueStep then slider:SetValueStep(step) end
    if slider.SetObeyStepOnDrag then pcall(slider.SetObeyStepOnDrag, slider, true) end
    slider:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v / step + 0.5) * step
        value:SetText(string.format(fmt, v))
        if self.syncing then return end
        set(v)
    end)
    refreshers[#refreshers + 1] = function()
        local v = get()
        slider.syncing = true
        slider:SetValue(v)
        slider.syncing = false
        value:SetText(string.format(fmt, v))
    end
    return slider
end

local function Button(parent, label, x, y, width, onClick)
    local b = TryCreate("Button", nil, parent, { "UIPanelButtonTemplate" })
    b:SetSize(width, 24)
    b:SetPoint("TOPLEFT", x, y)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local function Heading(parent, text, x, y)
    local h = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h:SetPoint("TOPLEFT", x, y)
    h:SetText(text)
    return h
end

------------------------------------------------------------------------
-- The page's contents (shown on the game's page or in our window)
------------------------------------------------------------------------
local function BuildContent()
    local c = CreateFrame("Frame")
    c:SetSize(W, H)
    c:Hide()
    local D = ns.Display
    local L, R = 8, 310

    local intro = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    intro:SetPoint("TOPLEFT", L, 0)
    intro:SetWidth(W - 20)
    intro:SetJustifyH("LEFT")
    intro:SetText("Tracks the tauren Plainsrunning racial: +1% speed for every 5 seconds of moving, up to 30 stacks. Standing still and taking hits cost stacks. The bar hides in combat (the game does not show the buff to addons there) and comes back with your stacks when the fight ends.")

    Heading(c, "Bar", L, -44)
    Check(c, "Lock the bar", L, -66,
        function() return db().locked end,
        function(v) db().locked = v D.ApplyLock() end,
        "Untick to drag the bar anywhere.")
    Slider(c, "Size", L + 4, -112, 260, 40, 200, 5,
        function() return math.floor((db().scale or 0.75) * 100 + 0.5) end,
        function(v) db().scale = v / 100 D.Layout() end, "%d%%")
    Slider(c, "Opacity at 0 stacks (out of combat)", L + 4, -164, 260, 0, 100, 5,
        function() return math.floor((db().idleAlpha or 0.45) * 100 + 0.5) end,
        function(v) db().idleAlpha = v / 100 end, "%d%%")
    Check(c, "Countdown text", L, -216,
        function() return db().showTimer end,
        function(v) db().showTimer = v end)
    Check(c, "One bar", L, -244,
        function() return db().layout == "one" end,
        function(v) db().layout = v and "one" or "two" D.Layout() end,
        "The countdown runs inside the stack bar: the next segment fills while you run, your top one drains red when you stop. Off: a cast bar under the stack bar.")

    Heading(c, "Other", R, -44)
    Check(c, "Minimap button", R, -66,
        function() return db().minimap end,
        function(v) db().minimap = v O.UpdateMinimapButton() end,
        "Left-click: options. Right-click: lock or unlock the bar. Drag: move it round the minimap.")

    Button(c, "Play the demo", R + 4, -126, 150, function() SlashCmdList.PLAINSTRIDE("demo") end)
    local demoTip = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    demoTip:SetPoint("TOPLEFT", R + 6, -154)
    demoTip:SetWidth(260)
    demoTip:SetJustifyH("LEFT")
    demoTip:SetText("About 40 seconds of gains, losses, hits and a full bar, on any character.")
    Button(c, "Reset position and size", R + 4, -186, 190, function()
        SlashCmdList.PLAINSTRIDE("reset")
        Refresh()
    end)

    local status = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    status:SetPoint("TOPLEFT", R + 6, -226)
    status:SetWidth(260)
    status:SetJustifyH("LEFT")
    refreshers[#refreshers + 1] = function()
        local st = ns.state
        local where = ({ aura = "read from the buff", demo = "the demo" })[st.source] or "not seen yet"
        status:SetText(string.format("Now: %s stacks, %s.\n/plainstride debug prints the details.",
            st.stacks and tostring(st.stacks) or "no", where))
    end

    local version = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    version:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -8, 4)
    version:SetText("Plainstride " .. (ns.VERSION or ""))

    c:SetScript("OnShow", Refresh)
    return c
end

local function EnsureContent()
    if content then return content end
    local ok, made = pcall(BuildContent)
    if not ok then
        print("the options could not be built: " .. tostring(made))
        return nil
    end
    content = made
    return content
end

local function Host(parent, x, y, scale)
    content:SetParent(parent)
    content:ClearAllPoints()
    content:SetScale(scale or 1)
    content:SetPoint("TOPLEFT", parent, "TOPLEFT", x / (scale or 1), y / (scale or 1))
    content:Show()
    Refresh()
end

------------------------------------------------------------------------
-- The standalone window
------------------------------------------------------------------------
local function BuildWindow()
    local f, template = TryCreate("Frame", "PlainstrideOptions", UIParent, { "ButtonFrameTemplate", "BasicFrameTemplateWithInset" })
    local top = template == "ButtonFrameTemplate" and -66 or -32
    f:SetSize(W + 24, H - top + 10)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:Hide()
    if UISpecialFrames then table.insert(UISpecialFrames, "PlainstrideOptions") end
    if template == "ButtonFrameTemplate" and ButtonFrameTemplate_HideButtonBar then
        pcall(ButtonFrameTemplate_HideButtonBar, f)
    end
    if template == "bare" then
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.05, 0.05, 0.07, 0.95)
    end
    if f.SetTitle then f:SetTitle(TITLE)
    elseif f.TitleText then f.TitleText:SetText(TITLE)
    elseif f.TitleContainer and f.TitleContainer.TitleText then f.TitleContainer.TitleText:SetText(TITLE)
    else
        local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t:SetPoint("TOP", 0, -8)
        t:SetText(TITLE)
    end
    if f.SetPortraitToAsset then pcall(f.SetPortraitToAsset, f, ICON)
    elseif f.PortraitContainer and f.PortraitContainer.portrait then f.PortraitContainer.portrait:SetTexture(ICON) end
    if not (f.CloseButton or _G["PlainstrideOptionsCloseButton"]) then
        local close = TryCreate("Button", nil, f, { "UIPanelCloseButton" })
        close:SetPoint("TOPRIGHT", 2, 2)
        close:SetScript("OnClick", function() f:Hide() end)
    end
    f:SetScript("OnShow", function(self) Host(self, 14, top, 1) end)
    return f
end

local function ShowWindow()
    if not EnsureContent() then return end
    if not window then
        local ok, made = pcall(BuildWindow)
        if not ok then
            print("the options window could not be built: " .. tostring(made))
            return
        end
        window = made
    end
    window:Show()
    if window.Raise then window:Raise() end
end

------------------------------------------------------------------------
-- Options > AddOns > Plainstride
------------------------------------------------------------------------
local function PageOpen()
    return settingsPage ~= nil and SettingsPanel ~= nil and SettingsPanel:IsShown()
        and settingsPage:GetParent() ~= nil and settingsPage:IsVisible()
end

function O.Toggle()
    if PageOpen() then
        if SettingsPanel and HideUIPanel then pcall(HideUIPanel, SettingsPanel) end
        return
    end
    if window and window:IsShown() then
        window:Hide()
        return
    end
    -- The game refuses to open its options for an addon in combat: use the window then, without
    -- giving up on the page for good.
    local fighting = InCombatLockdown and InCombatLockdown()
    if settingsCategory and Settings and Settings.OpenToCategory and not nativeOpenFailed and not fighting then
        local id = settingsCategory.GetID and settingsCategory:GetID() or settingsCategory.ID or settingsCategory
        pcall(Settings.OpenToCategory, id)
        if PageOpen() then return end -- trust what is on screen, not the call's answer
        nativeOpenFailed = true
    end
    ShowWindow()
end

function O.RegisterPage()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
    local page = CreateFrame("Frame")
    local title = page:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(TITLE)
    page:SetScript("OnShow", function(self)
        if not EnsureContent() then return end
        if window and window:IsShown() then window:Hide() end
        local w, h = self:GetWidth() or 0, self:GetHeight() or 0
        local scale = 1
        if w > 0 and h > 0 then scale = math.min(1, (w - 24) / W, (h - 56) / H) end
        Host(self, 16, -48, scale)
    end)
    local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, page, TITLE)
    if ok and category then
        pcall(Settings.RegisterAddOnCategory, category)
        settingsPage, settingsCategory = page, category
    end
end

------------------------------------------------------------------------
-- Minimap button
------------------------------------------------------------------------
local mmButton

local function PlaceMinimapButton()
    if not mmButton then return end
    local angle = math.rad(db().minimapAngle or 220)
    local radius = (Minimap:GetWidth() or 140) / 2 + 6
    mmButton:ClearAllPoints()
    mmButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

function O.UpdateMinimapButton()
    if not Minimap then return end
    if not mmButton then
        if not db().minimap then return end
        mmButton = CreateFrame("Button", "PlainstrideMinimapButton", Minimap)
        mmButton:SetSize(31, 31)
        mmButton:SetFrameStrata("MEDIUM")
        mmButton:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 8)
        mmButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        mmButton:RegisterForDrag("LeftButton")
        mmButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

        local bg = mmButton:CreateTexture(nil, "BACKGROUND")
        bg:SetSize(20, 20)
        bg:SetPoint("TOPLEFT", 7, -5)
        bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

        local icon = mmButton:CreateTexture(nil, "ARTWORK")
        icon:SetSize(18, 18)
        icon:SetPoint("TOPLEFT", 7, -6)
        icon:SetTexture(ICON)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        local border = mmButton:CreateTexture(nil, "OVERLAY")
        border:SetSize(53, 53)
        border:SetPoint("TOPLEFT")
        border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

        mmButton:SetScript("OnClick", function(_, button)
            if button == "RightButton" then
                db().locked = not db().locked
                ns.Display.ApplyLock()
                Refresh()
                print(db().locked and "bar locked." or "bar unlocked: drag it, then right-click the minimap button again.")
            else
                O.Toggle()
            end
        end)
        mmButton:SetScript("OnDragStart", function(self)
            self:SetScript("OnUpdate", function()
                local mx, my = Minimap:GetCenter()
                local scale = Minimap:GetEffectiveScale()
                local cx, cy = GetCursorPosition()
                if not (mx and my and cx and cy) then return end
                local dy, dx = cy / scale - my, cx / scale - mx
                local a = math.atan2 and math.atan2(dy, dx) or math.atan(dy, dx)
                db().minimapAngle = math.deg(a) % 360
                PlaceMinimapButton()
            end)
        end)
        mmButton:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
        mmButton:SetScript("OnEnter", function(self)
            local st = ns.state
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText(TITLE, 1, 1, 1)
            if st.stacks then
                GameTooltip:AddLine(string.format("Plainsrunning: %d / 30 stacks (+%d%% speed)", st.stacks, st.stacks), 1, 0.82, 0)
            end
            GameTooltip:AddLine("Left-click: options", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Right-click: lock / unlock the bar", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Drag: move around the minimap", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        mmButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    mmButton:SetShown(db().minimap and true or false)
    PlaceMinimapButton()
end
