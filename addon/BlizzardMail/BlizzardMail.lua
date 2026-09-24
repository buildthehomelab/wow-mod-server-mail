-- Blizzard Mail
--
-- A GM window for mailing items and gold to players from "Blizzard Services". The addon doesn't
-- send the mail itself (a client can only send mail as the character that's logged in); it drives
-- the mod-server-mail server commands over AzerothCore's addon command channel:
--
--   client -> server   SendAddonMessage("AzerothCore", "i" .. echo .. command, "WHISPER", <self>)
--   server -> client   "a" .. echo            command received
--                      "m" .. echo .. text    a line of command output
--                      "o" .. echo            command succeeded
--                      "f" .. echo            command failed
--
-- Nothing goes through public chat, so a player without GM rights who installs this only gets
-- an error back from the server.
--
-- A whole addon message is capped at 255 bytes, so the subject and letter are staged with their
-- own commands first and `.blizzmail send` only carries the recipient, items and gold.

local PREFIX = "AzerothCore"
local MAX_SLOTS = 12          -- the client's attachment limit
local MAX_COMMAND = 230       -- 255 minus "AzerothCore\t" and the opcode/echo
local BODY_PIECE = 90         -- raw bytes per `.blizzmail body`; escaping can double it
local MAX_BODY = 1000
local REPLY_TIMEOUT = 8
local MAX_COPPER = 2147483646 -- the core's MAX_MONEY_AMOUNT

local attachments = {}        -- { id = itemID, count = n }, in slot order

local frame, toBox, subjectBox, bodyBox, addBox, goldBox, silverBox, copperBox
local sendButton, statusText, slotsLabel
local slots = {}

------------------------------------------------------------------------------------------------
-- Talking to the server

local counter = 0
local run                     -- the command sequence in flight, if any

local timeoutFrame = CreateFrame("Frame")
timeoutFrame:Hide()

local function IssueCurrent()
    counter = counter % 9999 + 1
    run.echo = string.format("%04d", counter)
    run.elapsed = 0
    SendAddonMessage(PREFIX, "i" .. run.echo .. run.commands[run.index], "WHISPER", UnitName("player"))
end

local function FinishRun(ok)
    local finished = run
    run = nil
    timeoutFrame:Hide()
    finished.callback(ok, finished.lines, finished.index)
end

-- Runs the commands one after another, stopping at the first failure.
-- callback(ok, outputLines, indexReached)
local function RunCommands(commands, callback)
    if run then
        return false
    end
    run = { commands = commands, index = 1, lines = {}, callback = callback }
    timeoutFrame:Show()
    IssueCurrent()
    return true
end

timeoutFrame:SetScript("OnUpdate", function(self, elapsed)
    if not run then
        self:Hide()
        return
    end
    run.elapsed = run.elapsed + elapsed
    if run.elapsed > REPLY_TIMEOUT then
        table.insert(run.lines, "No reply from the server.")
        FinishRun(false)
    end
end)

local function OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= PREFIX or not run or sender ~= UnitName("player") then
        return
    end

    local op, echo, text = message:sub(1, 1), message:sub(2, 5), message:sub(6)
    if echo ~= run.echo then
        return
    end

    if op == "a" then
        run.elapsed = 0
    elseif op == "m" then
        table.insert(run.lines, text)
    elseif op == "o" then
        if run.index < #run.commands then
            run.index = run.index + 1
            IssueCurrent()
        else
            FinishRun(true)
        end
    elseif op == "f" then
        FinishRun(false)
    end
end

-- Wraps text in quotes for the server's parser: \ " and line breaks are escaped.
local function Quote(text)
    text = text:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n")
    return "\"" .. text .. "\""
end

-- Splits text into pieces of at most `size` bytes without cutting a UTF-8 character in half.
local function SplitText(text, size)
    local pieces, pos = {}, 1
    while pos <= #text do
        local last = math.min(pos + size - 1, #text)
        while last < #text and last > pos do
            local nextByte = text:byte(last + 1)
            if nextByte < 0x80 or nextByte >= 0xC0 then
                break
            end
            last = last - 1
        end
        table.insert(pieces, text:sub(pos, last))
        pos = last + 1
    end
    return pieces
end

------------------------------------------------------------------------------------------------
-- Status line

local function SetStatus(text, isError)
    if isError then
        statusText:SetTextColor(1, 0.3, 0.3)
    else
        statusText:SetTextColor(0.3, 1, 0.3)
    end
    statusText:SetText(text)
end

local function Print(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00b4ffBlizzard Mail:|r " .. text)
end

------------------------------------------------------------------------------------------------
-- Attachments

local scanTip = CreateFrame("GameTooltip", "BlizzardMailScanTooltip", UIParent, "GameTooltipTemplate")

-- The client only knows items it has seen. Showing one in a tooltip makes it ask the server.
local function RequestItem(id)
    if not GetItemInfo(id) then
        scanTip:SetOwner(UIParent, "ANCHOR_NONE")
        scanTip:SetHyperlink("item:" .. id)
        scanTip:Hide()
    end
end

local function ItemLabel(id)
    local name, link = GetItemInfo(id)
    return link or name or ("item " .. id)
end

-- Returns true once every attached item's icon is known.
local function RefreshSlots()
    local allKnown = true
    for i, button in ipairs(slots) do
        local a = attachments[i]
        if a then
            local texture = select(10, GetItemInfo(a.id))
            if not texture then
                allKnown = false
                texture = "Interface\\Icons\\INV_Misc_QuestionMark"
            end
            SetItemButtonTexture(button, texture)
            SetItemButtonCount(button, a.count)
        else
            SetItemButtonTexture(button, nil)
            SetItemButtonCount(button, 0)
        end
    end
    slotsLabel:SetText(string.format("Attachments (%d/%d)", #attachments, MAX_SLOTS))
    return allKnown
end

-- Retries icons for a few seconds while the server answers item queries.
local poller = CreateFrame("Frame")
poller:Hide()
poller:SetScript("OnUpdate", function(self, elapsed)
    self.wait = self.wait + elapsed
    if self.wait < 0.5 then
        return
    end
    self.wait = 0
    self.tries = self.tries + 1
    if RefreshSlots() or self.tries >= 20 then
        self:Hide()
    end
end)

local function UpdateSlots()
    if not RefreshSlots() then
        poller.wait, poller.tries = 0, 0
        poller:Show()
    end
end

local function AddItem(id, count)
    id, count = tonumber(id), tonumber(count) or 1
    if not id or id <= 0 or count <= 0 then
        SetStatus("That isn't an item id.", true)
        return
    end

    for _, a in ipairs(attachments) do
        if a.id == id then
            a.count = a.count + count
            UpdateSlots()
            return
        end
    end

    if #attachments >= MAX_SLOTS then
        SetStatus("All " .. MAX_SLOTS .. " attachment slots are full.", true)
        return
    end

    table.insert(attachments, { id = id, count = count })
    RequestItem(id)
    UpdateSlots()
end

-- "49284", "33447:20", "33447x20", or a shift-clicked item link (optionally followed by :20)
local function AddFromText(text)
    text = strtrim(text or "")
    if text == "" then
        return
    end

    local id, count = text:match("|Hitem:(%d+)")
    if id then
        count = text:match("|h[:x](%d+)%s*$") or text:match("|r[:x](%d+)%s*$")
    else
        id, count = text:match("^(%d+)[:x]?(%d*)$")
    end

    if not id then
        SetStatus("Type an item id (49284), id:count (33447:20), or shift-click an item.", true)
        return
    end

    AddItem(id, tonumber(count) or 1)
    addBox:SetText("")
end

local function SetCount(index, text)
    local count = tonumber(text)
    if attachments[index] and count and count > 0 then
        attachments[index].count = math.floor(count)
        UpdateSlots()
    end
end

local countIndex -- the slot the count popup is editing

StaticPopupDialogs["BLIZZARDMAIL_COUNT"] = {
    text = "How many?",
    button1 = OKAY,
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = 5,
    OnShow = function(self)
        local editBox = _G[self:GetName() .. "EditBox"]
        local a = attachments[countIndex]
        editBox:SetText(a and a.count or 1)
        editBox:SetFocus()
        editBox:HighlightText()
    end,
    OnAccept = function(self)
        SetCount(countIndex, _G[self:GetName() .. "EditBox"]:GetText())
    end,
    EditBoxOnEnterPressed = function(self)
        SetCount(countIndex, self:GetText())
        self:GetParent():Hide()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

local function Slot_TakeCursorItem()
    local kind, id = GetCursorInfo()
    if kind == "item" then
        ClearCursor() -- the GM's own copy stays in their bags; only the id is used
        AddItem(id, 1)
        return true
    end
end

local function Slot_OnClick(self, button)
    if Slot_TakeCursorItem() then
        return
    end

    local index = self:GetID()
    if not attachments[index] then
        return
    end

    if button == "RightButton" then
        table.remove(attachments, index)
        GameTooltip:Hide()
        UpdateSlots()
    else
        countIndex = index
        StaticPopup_Show("BLIZZARDMAIL_COUNT")
    end
end

local function Slot_OnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local a = attachments[self:GetID()]
    if a then
        GameTooltip:SetHyperlink("item:" .. a.id)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Item " .. a.id .. " x" .. a.count, 0.6, 0.6, 0.6)
        GameTooltip:AddLine("Left-click: change count   Right-click: remove", 0.6, 0.6, 0.6)
    else
        GameTooltip:SetText("Drop an item from your bags here")
        GameTooltip:AddLine("or use Add item / Mounts & Pets below.", 0.6, 0.6, 0.6, true)
        GameTooltip:AddLine("Your own copy isn't used up.", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

------------------------------------------------------------------------------------------------
-- Sending

local function GetCopper()
    return (tonumber(goldBox:GetText()) or 0) * 10000
        + (tonumber(silverBox:GetText()) or 0) * 100
        + (tonumber(copperBox:GetText()) or 0)
end

local function CoinText(copper)
    local text = {}
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    if g > 0 then table.insert(text, g .. "g") end
    if s > 0 then table.insert(text, s .. "s") end
    if c > 0 then table.insert(text, c .. "c") end
    return table.concat(text, " ")
end

local pendingCommands

local function DoSend()
    if not pendingCommands then
        return
    end

    local commands = pendingCommands
    pendingCommands = nil
    sendButton:Disable()
    SetStatus("Sending...", false)

    RunCommands(commands, function(ok, lines, index)
        sendButton:Enable()
        local output = table.concat(lines, " ")

        if ok then
            SetStatus(output ~= "" and output or "Sent.", false)
            Print(output ~= "" and output or "Sent.")
            wipe(attachments)
            goldBox:SetText("")
            silverBox:SetText("")
            copperBox:SetText("")
            UpdateSlots()
        else
            if output == "" then
                output = "The server refused the mail."
            end
            if index == 1 then
                output = output .. " (Blizzard Mail needs a GM account and the mod-server-mail server module.)"
            end
            SetStatus(output, true)
            Print("|cffff5050" .. output .. "|r")
        end
    end)
end

StaticPopupDialogs["BLIZZARDMAIL_CONFIRM"] = {
    text = "Send this to |cffffffff%s|r from Blizzard Services?\n\n%s",
    button1 = SEND_LABEL or "Send",
    button2 = CANCEL,
    OnAccept = DoSend,
    OnCancel = function() pendingCommands = nil end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

local function PrepareSend()
    if run then
        SetStatus("Still waiting for the server...", true)
        return
    end

    local name = strtrim(toBox:GetText())
    if name == "" or name:find("[%s\"]") then
        SetStatus("Who is it for? Type a character name.", true)
        return
    end

    local subject = strtrim(subjectBox:GetText())
    local body = bodyBox:GetText()
    local copper = GetCopper()

    if copper > MAX_COPPER then
        SetStatus("That's more gold than a character can hold (214,748g).", true)
        return
    end

    if #attachments == 0 and copper == 0 and subject == "" and strtrim(body) == "" then
        SetStatus("Nothing to send yet: add an item, some gold, or a letter.", true)
        return
    end

    local commands = { "blizzmail clear" }
    if subject ~= "" then
        table.insert(commands, "blizzmail subject " .. Quote(subject))
    end
    if strtrim(body) ~= "" then
        for _, piece in ipairs(SplitText(body, BODY_PIECE)) do
            table.insert(commands, "blizzmail body " .. Quote(piece))
        end
    end

    local send = "blizzmail send " .. name
    for _, a in ipairs(attachments) do
        send = send .. " " .. a.id .. ":" .. a.count
    end
    if copper > 0 then
        send = send .. " " .. copper .. "c"
    end
    table.insert(commands, send)

    for _, command in ipairs(commands) do
        if #command > MAX_COMMAND then
            SetStatus("That's too much to send in one go. Try fewer items.", true)
            return
        end
    end

    -- Summary for the confirmation dialog
    local lines = {}
    for _, a in ipairs(attachments) do
        table.insert(lines, ItemLabel(a.id) .. (a.count > 1 and (" x" .. a.count) or ""))
    end
    if copper > 0 then
        table.insert(lines, CoinText(copper))
    end
    if #lines == 0 then
        table.insert(lines, "(letter only)")
    end
    table.insert(lines, 1, "|cffffd100" .. (subject ~= "" and subject or "(default subject)") .. "|r")

    pendingCommands = commands
    StaticPopup_Show("BLIZZARDMAIL_CONFIRM", name, table.concat(lines, "\n"))
end

local function ClearForm()
    toBox:SetText("")
    subjectBox:SetText("")
    bodyBox:SetText("")
    addBox:SetText("")
    goldBox:SetText("")
    silverBox:SetText("")
    copperBox:SetText("")
    wipe(attachments)
    UpdateSlots()
    statusText:SetText("")
end

------------------------------------------------------------------------------------------------
-- Window

local function Label(text, x, y, template)
    local label = frame:CreateFontString(nil, "ARTWORK", template or "GameFontNormal")
    label:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
    label:SetText(text)
    return label
end

local function InputBox(name, width, x, y, maxLetters, numeric)
    local box = CreateFrame("EditBox", name, frame, "InputBoxTemplate")
    box:SetWidth(width)
    box:SetHeight(20)
    box:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
    box:SetAutoFocus(false)
    box:SetMaxLetters(maxLetters)
    if numeric then
        box:SetNumeric(true)
    end
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnEnterPressed", box.ClearFocus)
    return box
end

-- Grey placeholder text shown while a box is empty and unfocused.
local function Placeholder(box, text, anchor)
    local hint = box:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    hint:SetPoint("TOPLEFT", anchor or box, "TOPLEFT", anchor and 0 or 2, anchor and 0 or -4)
    hint:SetText(text)
    local function update()
        if box:GetText() == "" and not box:HasFocus() then
            hint:Show()
        else
            hint:Hide()
        end
    end
    box:HookScript("OnTextChanged", update)
    box:HookScript("OnEditFocusGained", update)
    box:HookScript("OnEditFocusLost", update)
    update()
end

local function Button(text, width, ...)
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetWidth(width)
    button:SetHeight(22)
    button:SetPoint(...)
    button:SetText(text)
    return button
end

local function Coin(box, texture)
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(texture)
    icon:SetWidth(13)
    icon:SetHeight(13)
    icon:SetPoint("LEFT", box, "RIGHT", 2, 0)
end

local function BuildWindow()
    frame = CreateFrame("Frame", "BlizzardMailFrame", UIParent)
    frame:SetWidth(400)
    frame:SetHeight(500)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:Hide()
    tinsert(UISpecialFrames, "BlizzardMailFrame") -- Escape closes it

    local header = frame:CreateTexture(nil, "ARTWORK")
    header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    header:SetWidth(300)
    header:SetHeight(64)
    header:SetPoint("TOP", 0, 12)
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", header, "TOP", 0, -14)
    title:SetText("Blizzard Mail")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    -- To
    Label("To:", 24, -38)
    toBox = InputBox("BlizzardMailTo", 150, 100, -34, 12)
    local targetButton = Button("Target", 70, "LEFT", toBox, "RIGHT", 8, 0)
    targetButton:SetScript("OnClick", function()
        local name = UnitIsPlayer("target") and UnitName("target") or UnitName("player")
        toBox:SetText(name)
    end)
    targetButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Use your target's name")
        GameTooltip:AddLine("With no player targeted, fills in your own name (handy for a test).", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    targetButton:SetScript("OnLeave", GameTooltip_Hide)

    -- Subject
    Label("Subject:", 24, -68)
    subjectBox = InputBox("BlizzardMailSubject", 270, 100, -64, 64)
    Placeholder(subjectBox, "server's default subject")

    -- Letter
    Label("Letter:", 24, -96)
    local letter = CreateFrame("Frame", nil, frame)
    letter:SetPoint("TOPLEFT", 20, -114)
    letter:SetWidth(360)
    letter:SetHeight(110)
    letter:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    letter:SetBackdropColor(0, 0, 0, 0.6)

    local scroll = CreateFrame("ScrollFrame", "BlizzardMailLetterScroll", letter, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -28, 8)

    bodyBox = CreateFrame("EditBox", "BlizzardMailLetter", scroll)
    bodyBox:SetMultiLine(true)
    bodyBox:SetAutoFocus(false)
    bodyBox:SetFontObject(ChatFontNormal)
    bodyBox:SetWidth(320)
    bodyBox:SetHeight(94)
    bodyBox:SetMaxLetters(MAX_BODY)
    bodyBox:SetScript("OnTextChanged", function(self) ScrollingEdit_OnTextChanged(self, scroll) end)
    bodyBox:SetScript("OnCursorChanged", ScrollingEdit_OnCursorChanged)
    bodyBox:SetScript("OnUpdate", function(self, elapsed) ScrollingEdit_OnUpdate(self, elapsed, scroll) end)
    bodyBox:SetScript("OnEscapePressed", bodyBox.ClearFocus)
    scroll:SetScrollChild(bodyBox)
    Placeholder(bodyBox, "Leave empty for the server's default letter.", bodyBox)

    letter:EnableMouse(true)
    letter:SetScript("OnMouseDown", function() bodyBox:SetFocus() end)

    -- Attachment slots, two rows of six
    slotsLabel = Label("", 24, -236)
    for i = 1, MAX_SLOTS do
        local button = CreateFrame("Button", "BlizzardMailSlot" .. i, frame, "ItemButtonTemplate")
        local row, col = math.floor((i - 1) / 6), (i - 1) % 6
        button:SetPoint("TOPLEFT", frame, "TOPLEFT", 42 + col * 56, -256 - row * 44)
        button:SetID(i)
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        button:SetScript("OnClick", Slot_OnClick)
        button:SetScript("OnReceiveDrag", Slot_TakeCursorItem)
        button:SetScript("OnEnter", Slot_OnEnter)
        button:SetScript("OnLeave", GameTooltip_Hide)

        local empty = button:CreateTexture(nil, "BACKGROUND")
        empty:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
        empty:SetAllPoints()

        slots[i] = button
    end

    -- Add item by id or link
    Label("Add item:", 24, -354)
    addBox = InputBox("BlizzardMailAdd", 130, 100, -350, 255)
    Placeholder(addBox, "id, id:count or link")
    addBox:SetScript("OnEnterPressed", function(self) AddFromText(self:GetText()) end)
    local addButton = Button("Add", 50, "LEFT", addBox, "RIGHT", 6, 0)
    addButton:SetScript("OnClick", function() AddFromText(addBox:GetText()) end)

    -- Shift-clicking an item while the Add box has focus puts its link there.
    hooksecurefunc("ChatEdit_InsertLink", function(link)
        if link and addBox:HasFocus() and link:find("|Hitem:") then
            addBox:SetText(link)
        end
    end)

    local presetMenu = CreateFrame("Frame", "BlizzardMailPresetMenu", frame, "UIDropDownMenuTemplate")
    UIDropDownMenu_Initialize(presetMenu, function(self, level)
        if level == 1 then
            for index, category in ipairs(BlizzardMailPresets) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = category.name
                info.value = index
                info.hasArrow = true
                info.notCheckable = true
                UIDropDownMenu_AddButton(info, level)
            end
        elseif level == 2 then
            local category = BlizzardMailPresets[UIDROPDOWNMENU_MENU_VALUE]
            for _, entry in ipairs(category and category.items or {}) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = entry[2]
                info.notCheckable = true
                info.func = function()
                    AddItem(entry[1], 1)
                    CloseDropDownMenus()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
    end, "MENU")
    local presetButton = Button("Mounts & Pets", 100, "LEFT", addButton, "RIGHT", 6, 0)
    presetButton:SetScript("OnClick", function(self)
        ToggleDropDownMenu(1, nil, presetMenu, self, 0, 0)
    end)

    -- Gold
    Label("Gold:", 24, -386)
    goldBox = InputBox("BlizzardMailGold", 60, 100, -382, 6, true)
    Coin(goldBox, "Interface\\MoneyFrame\\UI-GoldIcon")
    silverBox = InputBox("BlizzardMailSilver", 30, 186, -382, 2, true)
    Coin(silverBox, "Interface\\MoneyFrame\\UI-SilverIcon")
    copperBox = InputBox("BlizzardMailCopper", 30, 242, -382, 2, true)
    Coin(copperBox, "Interface\\MoneyFrame\\UI-CopperIcon")

    -- Status and buttons
    statusText = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", 24, -414)
    statusText:SetWidth(352)
    statusText:SetHeight(40)
    statusText:SetJustifyH("LEFT")
    statusText:SetJustifyV("TOP")

    local clearButton = Button("Clear", 90, "BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 18)
    clearButton:SetScript("OnClick", ClearForm)
    sendButton = Button("Send", 90, "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 18)
    sendButton:SetScript("OnClick", PrepareSend)

    -- Tab moves through the fields
    local order = { toBox, subjectBox, bodyBox, addBox, goldBox, silverBox, copperBox }
    for i, box in ipairs(order) do
        local nextBox = order[i % #order + 1]
        box:SetScript("OnTabPressed", function() nextBox:SetFocus() end)
    end
    toBox:SetScript("OnEnterPressed", function() subjectBox:SetFocus() end)
    subjectBox:SetScript("OnEnterPressed", function() bodyBox:SetFocus() end)

    UpdateSlots()
end

------------------------------------------------------------------------------------------------
-- Startup and slash command

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("CHAT_MSG_ADDON")
events:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    elseif event == "PLAYER_LOGIN" then
        BuildWindow()
    end
end)

SLASH_BLIZZARDMAIL1 = "/bmail"
SLASH_BLIZZARDMAIL2 = "/blizzmail"
SlashCmdList["BLIZZARDMAIL"] = function(msg)
    msg = strtrim(msg or "")
    if msg ~= "" then
        toBox:SetText(msg)
        frame:Show()
    elseif frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end
