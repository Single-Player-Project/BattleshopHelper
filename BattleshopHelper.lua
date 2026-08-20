-- Battleshop Helper: battle shop replacement for 7.3.5 (build 26972).
-- Talks to the server over the PRVFIT addon channel (see
-- src/server/scripts/BattlePay/battlepay_fitting_room.cpp). The server pushes the
-- full shop catalog; this addon renders it as a replica of the battle shop with
-- a live try-on pane (your real character model), stat tooltips, and purchases
-- through a server-validated confirmation. When the server allows it, the shop
-- button opens this window instead of the Blizzard store; without the addon or
-- the bridge, the real store opens untouched.

local ADDON_VERSION = "2.2"
-- wire identifiers predate the rename and stay as they are: changing them
-- would make an addon talking to an older server go silent instead of
-- reporting a version mismatch
local PREFIX = "PRVFIT"
local MARKER = "FITROOM:"

local BSH = {
    groups = {},        -- { {id=, icon=, name=}, ... } in arrival order
    byGroup = {},       -- groupId -> { productId, ... }
    products = {},      -- productId -> { id, group, price, kind ("I"/"M"/"G"), items = {}, display, icon, name }
    desc = {},          -- productId -> description text (lazy-loaded)
    descAsked = {},
    balance = nil,
    duration = 60,
    catalogReady = false,
    helloSent = false,
    selectedGroup = nil,
    selectedProduct = nil,
    pendingToken = nil,
    mountMode = false,
    pendingTryOn = {},  -- itemId -> true, re-tried once the item cache answers
    page = 1,
    intercept = false,
    intercepted = false,
    origToggleStore = nil,
    hoverCard = nil,
}

local CARDS_PER_PAGE = 8
local FEATURED_PER_PAGE = 3   -- one hero plus two secondary cards
local GROUP_BUTTONS = 24
local DISPLAY_SPLASH = 1      -- battlepay_product_group.DisplayType: the featured layout
local DISPLAY_DOUBLEWIDE = 2  -- ... and the four-plate layout
local DOUBLEWIDE_PER_PAGE = 4
local PANEL_MIN_HEIGHT = 505
local RAIL_TOP = 46
local RAIL_STEP = 31
local RAIL_BOTTOM_PAD = 74    -- balance, footnote and the Standard Shop button
local MOUNT_FALLBACK_SCENE = 290 -- generic mount UiModelScene, used when the journal has no specific one
local PET_FALLBACK_SCENE = 297   -- generic battle pet UiModelScene (mount scenes frame pets far too wide)

local eventFrame = CreateFrame("Frame")
local panel, launcher, cards, plateCards, heroCard, featCards, model, mountModel, mountScene
local buyButton, worldButton, balanceText, pageText, prevButton, nextButton, blizzButton
local groupButtons

local function Send(msg)
    SendAddonMessage(PREFIX, MARKER .. msg, "WHISPER", UnitName("player"))
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff7fc9ffShop:|r " .. msg)
end

-- ---------------------------------------------------------------------------
-- product helpers
-- ---------------------------------------------------------------------------

local function ProductLabel(product)
    local firstItem = product.items[1]
    local name, quality = product.name, nil
    if firstItem and firstItem > 0 then
        local itemName, _, itemQuality = GetItemInfo(firstItem)
        quality = itemQuality
        if not name or name == "" then
            name = itemName
        end
    end
    -- server-sent quality covers custom items the client cache cannot resolve
    if not quality and product.quality and product.quality > 0 then
        quality = product.quality
    end
    if not name or name == "" then
        name = "Item #" .. (firstItem or product.id)
    end
    if product.kind == "I" and #product.items > 1 then
        name = name .. " +" .. (#product.items - 1)
    end
    if quality then
        local color = ITEM_QUALITY_COLORS[quality]
        if color then
            return color.hex .. name .. "|r"
        end
    end
    return name
end

local function IsOnSale(product)
    return product.normal and product.normal > product.price
end

local function DiscountPercent(product)
    if not IsOnSale(product) then return 0 end
    return math.floor((product.normal - product.price) / product.normal * 100 + 0.5)
end

-- sale prices read like the shop's: the old one greyed out, the new one green
local function PriceText(product)
    if IsOnSale(product) then
        return "|cff9d9d9d" .. product.normal .. "|r |cff00ff00" .. product.price .. "|r *"
    end
    return product.price .. " *"
end

local function ProductIcon(product)
    local firstItem = product.items[1]
    if firstItem and firstItem > 0 then
        local texture = select(10, GetItemInfo(firstItem))
        if texture then
            return texture
        end
    end
    if product.icon and product.icon > 0 then
        return product.icon
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- On 7.x, TryOn with a bare number means an appearance id - items must go
-- through the "item:" link form. Uncached items are queued and retried when
-- the item cache answers.
local function TryOnItem(itemId)
    if not GetItemInfo(itemId) then
        BSH.pendingTryOn[itemId] = true
    end
    model:TryOn("item:" .. itemId)
end

-- swap back to the character model without touching the tried-on outfit
local function ShowCharacterModel()
    BSH.mountMode = false
    if mountScene then mountScene:Hide() end
    if mountModel then mountModel:Hide() end
    if model then model:Show() end
end

local function ResetModel()
    ShowCharacterModel()
    if not model then return end
    model.zoom = 1
    pcall(model.SetCamDistanceScale, model, 1)
    model:SetUnit("player")
    model:Dress()
end

-- the client's own mount journal data beats whatever the shop DB carries,
-- and supplies the UiModelScene the Mount Journal would use for the camera
local function ResolveMount(product)
    local itemId = product.items and product.items[1]
    if itemId and C_MountJournal and C_MountJournal.GetMountFromItem then
        local mountID = C_MountJournal.GetMountFromItem(itemId)
        if mountID then
            local creatureDisplayID, _, _, _, _, modelSceneID = C_MountJournal.GetMountInfoExtraByID(mountID)
            if creatureDisplayID and creatureDisplayID > 0 then
                return creatureDisplayID, modelSceneID
            end
        end
    end
    return product.display, nil
end

-- Render mounts the way the Mount Journal does: a ModelScene brings its own
-- camera setup, which raw SetDisplayInfo on a model frame lacks (the model
-- loads but is never framed, so the pane looks empty).
local function ShowMount(display, sceneId, isPet)
    if not display or display == 0 then return end
    if sceneId == 0 then sceneId = nil end

    BSH.mountMode = true
    model:Hide()

    if mountScene then
        if mountModel then mountModel:Hide() end
        mountScene:Show()

        -- the model's own scene first, then the generic one for its kind, then
        -- the mount scene as a last resort; actor tags differ between scenes
        local scenes = {}
        if sceneId then tinsert(scenes, sceneId) end
        if isPet then tinsert(scenes, PET_FALLBACK_SCENE) end
        tinsert(scenes, MOUNT_FALLBACK_SCENE)

        for _, candidate in ipairs(scenes) do
            local ok = pcall(function()
                mountScene:TransitionToModelSceneID(candidate,
                    CAMERA_TRANSITION_TYPE_IMMEDIATE or 1, CAMERA_MODIFICATION_TYPE_MAINTAIN or 1, true)
                local actor = mountScene:GetActorByTag("unwrapped") or mountScene:GetActorByTag("pet")
                    or mountScene:GetActorByTag("mount") or mountScene:GetActorAtIndex(1)
                actor:SetModelByCreatureDisplayID(display)
            end)
            if ok then
                return
            end
        end
        mountScene:Hide()
    end

    -- fallback for clients without usable ModelScene support
    if mountModel and mountModel.SetDisplayInfo then
        mountModel:Show()
        mountModel:ClearModel()
        pcall(mountModel.SetDisplayInfo, mountModel, display)
        C_Timer.After(0.1, function()
            if BSH.mountMode and mountModel:IsShown() then
                pcall(mountModel.SetDisplayInfo, mountModel, display)
            end
        end)
        return
    end

    Print("This client cannot render mounts here - use |cffffd83dIn World|r to see it.")
end

local function TryOnProduct(product)
    if not model then return end
    if product.kind == "M" then
        ShowMount(ResolveMount(product))
        return
    end
    if product.kind == "P" then
        -- pets render like mounts, but with their own card scene
        ShowMount(product.display, product.scene, true)
        return
    end
    if product.kind ~= "I" then
        return -- services, currencies and such have nothing to dress
    end
    if BSH.mountMode then
        ShowCharacterModel()
    end
    for _, itemId in ipairs(product.items) do
        TryOnItem(itemId)
    end
end

-- ---------------------------------------------------------------------------
-- tooltips
-- ---------------------------------------------------------------------------

local function ShowProductTooltip(owner, product)
    BSH.hoverCard = owner
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local itemBased = product.items[1] and product.items[1] > 0 and (product.kind ~= "I" or #product.items == 1)
    if itemBased then
        GameTooltip:SetItemByID(product.items[1])
    else
        GameTooltip:SetText(ProductLabel(product), 1, 1, 1)
        if product.kind == "I" then
            for _, itemId in ipairs(product.items) do
                local name, _, quality = GetItemInfo(itemId)
                local color = ITEM_QUALITY_COLORS[quality or 1]
                GameTooltip:AddLine((color and color.hex or "") .. (name or ("Item #" .. itemId)) .. "|r")
            end
        end
    end
    if not BSH.desc[product.id] and not BSH.descAsked[product.id] then
        BSH.descAsked[product.id] = true
        Send("DESC|" .. product.id)
    end
    if BSH.desc[product.id] and BSH.desc[product.id] ~= "" then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(BSH.desc[product.id], 0.85, 0.78, 0.6, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffffd83dPrice: " .. product.price .. " Battle Coins|r")
    if product.kind ~= "G" then
        GameTooltip:AddLine("|cff9aa7bdClick to try it on|r")
    end
    GameTooltip:Show()
end

-- ---------------------------------------------------------------------------
-- card grid
-- ---------------------------------------------------------------------------

local function VisibleProducts()
    return BSH.byGroup[BSH.selectedGroup] or {}
end

-- a category's DisplayType picks its whole layout, exactly as in the store:
-- splash is the featured page, doublewide is four large plates, default is the
-- 4x2 grid
local function GroupDisplayType(groupId)
    for _, group in ipairs(BSH.groups) do
        if group.id == groupId then
            return group.displayType or 0
        end
    end
    return 0
end

local function IsSplashGroup(groupId)
    return GroupDisplayType(groupId) == DISPLAY_SPLASH
end

local function IsDoubleWideGroup(groupId)
    return GroupDisplayType(groupId) == DISPLAY_DOUBLEWIDE
end

local function PageSize()
    local displayType = GroupDisplayType(BSH.selectedGroup)
    if displayType == DISPLAY_SPLASH then return FEATURED_PER_PAGE end
    if displayType == DISPLAY_DOUBLEWIDE then return DOUBLEWIDE_PER_PAGE end
    return CARDS_PER_PAGE
end

-- the featured page lays out like the shop's: one hero above two smaller
-- cards, all showing the sale price against the original
local function RenderFeatured()
    for i = 1, CARDS_PER_PAGE do
        cards[i].product = nil
        cards[i]:Hide()
    end
    for i = 1, DOUBLEWIDE_PER_PAGE do
        plateCards[i].product = nil
        plateCards[i]:Hide()
    end

    local ids = VisibleProducts()
    local slots = { heroCard, featCards[1], featCards[2] }
    local pages = math.max(1, math.ceil(#ids / FEATURED_PER_PAGE))
    if BSH.page > pages then BSH.page = pages end
    if BSH.page < 1 then BSH.page = 1 end
    local offset = (BSH.page - 1) * FEATURED_PER_PAGE

    for i, slot in ipairs(slots) do
        local product = BSH.products[ids[i + offset] or -1]
        if product then
            slot.product = product
            slot.icon:SetTexture(ProductIcon(product))
            slot.name:SetText(ProductLabel(product))
            local onSale = IsOnSale(product)
            slot.oldPrice:SetText(onSale and (product.normal .. " Battle Coins") or "")
            slot.price:SetText(product.price .. " Battle Coins")

            -- the strike has to match the rendered width, so size it after SetText
            if onSale then
                slot.strike:SetWidth(math.max(1, slot.oldPrice:GetStringWidth()))
                slot.strike:Show()
            else
                slot.strike:Hide()
            end

            local percent = DiscountPercent(product)
            if percent > 0 then
                slot.badge:SetText("-" .. percent .. "%")
                slot.badge:Show()
                slot.badgeBg:Show()
                slot.badgeRim:Show()
            else
                slot.badge:Hide()
                slot.badgeBg:Hide()
                slot.badgeRim:Hide()
            end

            if BSH.selectedProduct == product.id then
                slot:SetBackdropBorderColor(0.55, 0.78, 1)
            else
                slot:SetBackdropBorderColor(1, 0.86, 0.45)
            end
            slot:Show()
        else
            slot.product = nil
            slot:Hide()
        end
    end

    return pages
end

-- the doublewide page: four large plates, two by two, each centred on its
-- icon with the savings called out in the corner
local function RenderPlates()
    heroCard:Hide()
    featCards[1]:Hide()
    featCards[2]:Hide()
    for i = 1, CARDS_PER_PAGE do
        cards[i].product = nil
        cards[i]:Hide()
    end

    local ids = VisibleProducts()
    local pages = math.max(1, math.ceil(#ids / DOUBLEWIDE_PER_PAGE))
    if BSH.page > pages then BSH.page = pages end
    if BSH.page < 1 then BSH.page = 1 end
    local offset = (BSH.page - 1) * DOUBLEWIDE_PER_PAGE

    for i = 1, DOUBLEWIDE_PER_PAGE do
        local card = plateCards[i]
        local product = BSH.products[ids[i + offset] or -1]
        if product then
            card.product = product
            card.icon:SetTexture(ProductIcon(product))
            card.name:SetText(ProductLabel(product))

            local onSale = IsOnSale(product)
            card.oldPrice:SetText(onSale and (product.normal .. " *") or "")
            card.price:SetText(product.price .. " *")

            -- the strike has to match the rendered width, so size it after SetText
            if onSale then
                card.strike:SetWidth(math.max(1, card.oldPrice:GetStringWidth()))
                card.strike:Show()
            else
                card.strike:Hide()
            end

            local percent = DiscountPercent(product)
            if percent > 0 then
                card.badge:SetText("You save " .. percent .. "%")
                local width = math.max(60, card.badge:GetStringWidth() + 20)
                card.badgeBg:SetWidth(width)
                card.badgeRim:SetWidth(width + 4)
                card.badge:Show()
                card.badgeBg:Show()
                card.badgeRim:Show()
            else
                card.badge:Hide()
                card.badgeBg:Hide()
                card.badgeRim:Hide()
            end

            if BSH.selectedProduct == product.id then
                card:SetBackdropBorderColor(0.55, 0.78, 1)
            else
                card:SetBackdropBorderColor(1, 0.86, 0.45)
            end
            card:Show()
        else
            card.product = nil
            card:Hide()
        end
    end

    return pages
end

local function RenderCards()
    heroCard:Hide()
    featCards[1]:Hide()
    featCards[2]:Hide()
    for i = 1, DOUBLEWIDE_PER_PAGE do
        plateCards[i].product = nil
        plateCards[i]:Hide()
    end

    local ids = VisibleProducts()
    local pages = math.max(1, math.ceil(#ids / CARDS_PER_PAGE))
    if BSH.page > pages then BSH.page = pages end
    if BSH.page < 1 then BSH.page = 1 end
    local offset = (BSH.page - 1) * CARDS_PER_PAGE

    for i = 1, CARDS_PER_PAGE do
        local card = cards[i]
        local productId = ids[i + offset]
        if productId then
            local product = BSH.products[productId]
            card.product = product
            card.icon:SetTexture(ProductIcon(product))
            card.name:SetText(ProductLabel(product))
            card.price:SetText(PriceText(product))
            if BSH.selectedProduct == productId then
                card:SetBackdropBorderColor(0.45, 0.65, 1)
            else
                card:SetBackdropBorderColor(0.62, 0.48, 0.2)
            end
            card:Show()
        else
            card.product = nil
            card:Hide()
        end
    end

    return pages
end

local function RefreshGrid()
    if not panel or not panel:IsShown() then return end

    local render = RenderCards
    if IsSplashGroup(BSH.selectedGroup) then
        render = RenderFeatured
    elseif IsDoubleWideGroup(BSH.selectedGroup) then
        render = RenderPlates
    end
    local pages = render()

    pageText:SetText("Page " .. BSH.page .. "/" .. pages)
    if BSH.page > 1 then prevButton:Enable() else prevButton:Disable() end
    if BSH.page < pages then nextButton:Enable() else nextButton:Disable() end

    local product = BSH.selectedProduct and BSH.products[BSH.selectedProduct]
    if product then
        buyButton:SetText("Buy Now - " .. product.price)
        buyButton:Enable()
        if product.kind ~= "G" then worldButton:Enable() else worldButton:Disable() end
    else
        buyButton:SetText("Buy Now")
        buyButton:Disable()
        worldButton:Disable()
    end

    balanceText:SetText(BSH.balance and ("Balance: |cffffd83d" .. BSH.balance .. "|r Battle Coins") or "")

    -- the balance line grows with the digit count, so keep Standard Shop clear
    -- of it rather than trusting a fixed offset
    if blizzButton then
        blizzButton:ClearAllPoints()
        blizzButton:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT",
            math.max(320, 40 + balanceText:GetStringWidth()), 15)
    end
end

local function RefreshGroups()
    if not groupButtons then return end

    local entries = BSH.groups
    -- the rail grows with the category list, so the window has to grow with it
    -- or the buttons run over the balance and the footnote
    panel:SetHeight(math.max(PANEL_MIN_HEIGHT, RAIL_TOP + #entries * RAIL_STEP + RAIL_BOTTOM_PAD))

    for i, button in ipairs(groupButtons) do
        local group = entries[i]
        if group then
            button:SetText(group.name)
            if group.icon and group.icon > 0 then
                button.icon:SetTexture(group.icon)
                button.icon:Show()
            else
                button.icon:Hide()
            end
            if BSH.selectedGroup == group.id then
                button:LockHighlight()
            else
                button:UnlockHighlight()
            end
            button.groupId = group.id
            button:Show()
        else
            button:Hide()
        end
    end
end

-- one page step, clamped; used by the arrows and the mouse wheel alike
local function ChangePage(step)
    local pages = math.max(1, math.ceil(#VisibleProducts() / PageSize()))
    local target = BSH.page + step
    if target < 1 or target > pages then
        return
    end

    BSH.page = target
    BSH.selectedProduct = nil
    RefreshGrid()

    -- the card under the cursor changed without the mouse moving, so its
    -- OnEnter will not fire again - refresh the tooltip by hand
    if BSH.hoverCard then
        if BSH.hoverCard.product then
            ShowProductTooltip(BSH.hoverCard, BSH.hoverCard.product)
        else
            GameTooltip:Hide()
        end
    end
end

-- ---------------------------------------------------------------------------
-- frame construction (replica of the battle shop, dark ground and gold trim)
-- ---------------------------------------------------------------------------

local PANEL_BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 11, top = 11, bottom = 11 },
}

local INSET_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local function CreateCard(parent)
    local card = CreateFrame("Button", nil, parent)
    card:SetSize(130, 162)
    card:SetBackdrop(INSET_BACKDROP)
    card:SetBackdropColor(0.2, 0.14, 0.07, 0.95)
    card:SetBackdropBorderColor(0.62, 0.48, 0.2)
    card:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    card.icon = card:CreateTexture(nil, "ARTWORK")
    card.icon:SetSize(44, 44)
    card.icon:SetPoint("TOP", 0, -18)
    card.icon:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")

    card.ring = card:CreateTexture(nil, "OVERLAY")
    card.ring:SetSize(111, 111)
    card.ring:SetPoint("TOPLEFT", card.icon, "TOPLEFT", -17, 15)
    card.ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    card.name = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    card.name:SetPoint("TOPLEFT", card, "TOPLEFT", 6, -70)
    card.name:SetPoint("TOPRIGHT", card, "TOPRIGHT", -6, -70)
    card.name:SetHeight(58)
    card.name:SetJustifyH("CENTER")
    card.name:SetJustifyV("TOP")
    card.name:SetWordWrap(true)

    card.price = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    card.price:SetPoint("BOTTOM", card, "BOTTOM", 0, 10)
    card.price:SetTextColor(1, 0.85, 0.24)

    card:SetScript("OnClick", function(self)
        if not self.product then return end
        BSH.selectedProduct = self.product.id
        TryOnProduct(self.product)
        RefreshGrid()
    end)
    card:SetScript("OnEnter", function(self)
        if self.product then
            ShowProductTooltip(self, self.product)
        end
    end)
    card:SetScript("OnLeave", function()
        BSH.hoverCard = nil
        GameTooltip_Hide()
    end)
    card:Hide()
    return card
end

-- Featured cards, styled after the store's own: gold-framed warm parchment,
-- a ribbon over the hero, Morpheus serif type, a struck original price and a
-- green discount badge. Font objects are applied defensively so a locale
-- without Morpheus simply keeps the template font.
local FEATURED_BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    tile = false, edgeSize = 24,
    insets = { left = 7, right = 7, top = 7, bottom = 7 },
}

local function UseFont(fontString, fontObject)
    if fontObject then
        fontString:SetFontObject(fontObject)
    end
end

local function CreateFeaturedCard(parent, isHero)
    local card = CreateFrame("Button", nil, parent)
    card:SetBackdrop(FEATURED_BACKDROP)
    card:SetBackdropColor(0, 0, 0, 0)
    card:SetBackdropBorderColor(1, 0.86, 0.45)

    -- warm gradient ground, lighter at the top like the store's card art
    card.bg = card:CreateTexture(nil, "BACKGROUND")
    card.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    card.bg:SetPoint("TOPLEFT", 7, -7)
    card.bg:SetPoint("BOTTOMRIGHT", -7, 7)
    card.bg:SetGradientAlpha("VERTICAL", 0.20, 0.10, 0.05, 1, 0.46, 0.28, 0.15, 1)

    card:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    -- starburst behind the icon, gently pulsing to draw the eye
    card.glow = card:CreateTexture(nil, "ARTWORK")
    card.glow:SetTexture("Interface\\Cooldown\\star4")
    card.glow:SetBlendMode("ADD")
    card.glow:SetVertexColor(1, 0.85, 0.45, 0.85)
    card.glow:SetSize(isHero and 150 or 96, isHero and 150 or 96)

    card.icon = card:CreateTexture(nil, "OVERLAY")
    card.icon:SetSize(isHero and 62 or 42, isHero and 62 or 42)
    card.icon:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")

    if isHero then
        card.icon:SetPoint("LEFT", card, "LEFT", 78, -14)
    else
        card.icon:SetPoint("LEFT", card, "LEFT", 26, 0)
    end
    card.glow:SetPoint("CENTER", card.icon, "CENTER", 0, 0)

    -- an OnUpdate pulse rather than an AnimationGroup: animating a texture
    -- directly is not dependable on this client, and OnUpdate only runs while
    -- the card is shown anyway
    card:SetScript("OnUpdate", function(self, elapsed)
        self.pulseTime = (self.pulseTime or 0) + elapsed
        self.glow:SetAlpha(0.40 + 0.35 * math.abs(math.sin(self.pulseTime * 1.1)))
    end)

    if isHero then
        -- parchment ribbon across the top, the way the store banners its hero
        card.ribbon = card:CreateTexture(nil, "ARTWORK")
        card.ribbon:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal")
        card.ribbon:SetSize(330, 46)
        card.ribbon:SetPoint("TOP", card, "TOP", 0, -2)
        card.ribbon:SetVertexColor(1, 0.97, 0.86)

        card.ribbonEdgeTop = card:CreateTexture(nil, "OVERLAY")
        card.ribbonEdgeTop:SetTexture("Interface\\Buttons\\WHITE8X8")
        card.ribbonEdgeTop:SetVertexColor(0.78, 0.62, 0.28)
        card.ribbonEdgeTop:SetSize(330, 2)
        card.ribbonEdgeTop:SetPoint("TOP", card.ribbon, "TOP", 0, 0)

        card.ribbonEdgeBottom = card:CreateTexture(nil, "OVERLAY")
        card.ribbonEdgeBottom:SetTexture("Interface\\Buttons\\WHITE8X8")
        card.ribbonEdgeBottom:SetVertexColor(0.78, 0.62, 0.28)
        card.ribbonEdgeBottom:SetSize(330, 2)
        card.ribbonEdgeBottom:SetPoint("BOTTOM", card.ribbon, "BOTTOM", 0, 0)

        card.banner = card:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        UseFont(card.banner, QuestFont_Super_Huge)
        card.banner:SetPoint("CENTER", card.ribbon, "CENTER", 0, 0)
        card.banner:SetText("FEATURED!")
        card.banner:SetTextColor(0.11, 0.24, 0.55)
    end

    card.name = card:CreateFontString(nil, "OVERLAY", isHero and "GameFontNormalLarge" or "GameFontNormal")
    UseFont(card.name, isHero and QuestFont_Super_Huge or QuestFont_Shadow_Huge)
    card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 16, isHero and 10 or 6)
    card.name:SetPoint("RIGHT", card, "RIGHT", -16, 0)
    card.name:SetJustifyH("LEFT")
    card.name:SetJustifyV("TOP")
    card.name:SetHeight(isHero and 46 or 40)
    card.name:SetWordWrap(true)
    card.name:SetShadowOffset(1, -1)
    card.name:SetShadowColor(0, 0, 0, 1)

    -- old price with a real strike, sized to the text in RenderFeatured
    card.oldPrice = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    UseFont(card.oldPrice, isHero and Game18Font or Game15Font)
    card.oldPrice:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, isHero and -10 or -2)
    card.oldPrice:SetTextColor(0.80, 0.72, 0.50)

    card.strike = card:CreateTexture(nil, "OVERLAY")
    card.strike:SetTexture("Interface\\Buttons\\WHITE8X8")
    card.strike:SetVertexColor(0.80, 0.72, 0.50)
    card.strike:SetHeight(2)
    card.strike:SetPoint("LEFT", card.oldPrice, "LEFT", 0, 0)
    card.strike:Hide()

    card.price = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    UseFont(card.price, isHero and Game24Font or Game18Font)
    if isHero then
        card.price:SetPoint("LEFT", card.oldPrice, "RIGHT", 16, 0)
    else
        card.price:SetPoint("TOPLEFT", card.oldPrice, "BOTTOMLEFT", 0, -2)
    end
    card.price:SetTextColor(0.18, 1, 0.18)
    card.price:SetShadowOffset(1, -1)
    card.price:SetShadowColor(0, 0, 0, 1)

    -- discount badge: bright green plate with a darker rim
    card.badgeRim = card:CreateTexture(nil, "ARTWORK")
    card.badgeRim:SetTexture("Interface\\Buttons\\WHITE8X8")
    card.badgeRim:SetVertexColor(0.03, 0.22, 0.04, 1)
    card.badgeRim:SetSize(60, 26)
    card.badgeRim:SetPoint("TOPRIGHT", card, "TOPRIGHT", -9, -9)

    card.badgeBg = card:CreateTexture(nil, "OVERLAY")
    card.badgeBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    card.badgeBg:SetSize(56, 22)
    card.badgeBg:SetPoint("CENTER", card.badgeRim, "CENTER", 0, 0)
    card.badgeBg:SetGradientAlpha("VERTICAL", 0.04, 0.34, 0.06, 1, 0.20, 0.62, 0.14, 1)

    card.badge = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    UseFont(card.badge, Game15Font)
    card.badge:SetPoint("CENTER", card.badgeBg, "CENTER", 0, 0)
    card.badge:SetTextColor(1, 1, 1)
    card.badge:SetShadowOffset(1, -1)
    card.badge:SetShadowColor(0, 0, 0, 1)

    card:SetScript("OnClick", function(self)
        if not self.product then return end
        BSH.selectedProduct = self.product.id
        TryOnProduct(self.product)
        RefreshGrid()
    end)
    card:SetScript("OnEnter", function(self)
        if self.product then
            ShowProductTooltip(self, self.product)
        end
    end)
    card:SetScript("OnLeave", function()
        BSH.hoverCard = nil
        GameTooltip_Hide()
    end)
    card:Hide()
    return card
end

-- DoubleWide plates: four large cards, two by two, composed centrally with a
-- "You save" banner. Shares the featured cards' gold-on-gradient treatment.
local function CreatePlateCard(parent)
    local card = CreateFrame("Button", nil, parent)
    card:SetBackdrop(FEATURED_BACKDROP)
    card:SetBackdropColor(0, 0, 0, 0)
    card:SetBackdropBorderColor(1, 0.86, 0.45)

    card.bg = card:CreateTexture(nil, "BACKGROUND")
    card.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    card.bg:SetPoint("TOPLEFT", 7, -7)
    card.bg:SetPoint("BOTTOMRIGHT", -7, 7)
    card.bg:SetGradientAlpha("VERTICAL", 0.20, 0.10, 0.05, 1, 0.46, 0.28, 0.15, 1)

    card:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    card.icon = card:CreateTexture(nil, "ARTWORK")
    card.icon:SetSize(58, 58)
    card.icon:SetPoint("TOP", card, "TOP", 0, -20)
    card.icon:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")

    card.ring = card:CreateTexture(nil, "OVERLAY")
    card.ring:SetSize(146, 146)
    card.ring:SetPoint("TOPLEFT", card.icon, "TOPLEFT", -22, 20)
    card.ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    card.name = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    UseFont(card.name, QuestFont_Shadow_Huge)
    card.name:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -84)
    card.name:SetPoint("TOPRIGHT", card, "TOPRIGHT", -14, -84)
    card.name:SetHeight(42)
    card.name:SetJustifyH("CENTER")
    card.name:SetJustifyV("TOP")
    card.name:SetWordWrap(true)
    card.name:SetShadowOffset(1, -1)
    card.name:SetShadowColor(0, 0, 0, 1)

    -- prices sit side by side and centred, so they are anchored to a strut
    card.priceAnchor = card:CreateTexture(nil, "BACKGROUND")
    card.priceAnchor:SetTexture("Interface\\Buttons\\WHITE8X8")
    card.priceAnchor:SetAlpha(0)
    card.priceAnchor:SetSize(1, 1)
    card.priceAnchor:SetPoint("BOTTOM", card, "BOTTOM", 0, 24)

    card.oldPrice = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    UseFont(card.oldPrice, Game18Font)
    card.oldPrice:SetPoint("RIGHT", card.priceAnchor, "LEFT", -6, 0)
    card.oldPrice:SetTextColor(0.80, 0.72, 0.50)

    card.strike = card:CreateTexture(nil, "OVERLAY")
    card.strike:SetTexture("Interface\\Buttons\\WHITE8X8")
    card.strike:SetVertexColor(0.80, 0.72, 0.50)
    card.strike:SetHeight(2)
    card.strike:SetPoint("LEFT", card.oldPrice, "LEFT", 0, 0)
    card.strike:Hide()

    card.price = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    UseFont(card.price, Game18Font)
    card.price:SetPoint("LEFT", card.priceAnchor, "RIGHT", 6, 0)
    card.price:SetTextColor(0.18, 1, 0.18)
    card.price:SetShadowOffset(1, -1)
    card.price:SetShadowColor(0, 0, 0, 1)

    card.badgeRim = card:CreateTexture(nil, "ARTWORK")
    card.badgeRim:SetTexture("Interface\\Buttons\\WHITE8X8")
    card.badgeRim:SetVertexColor(0.03, 0.22, 0.04, 1)
    card.badgeRim:SetHeight(30)
    card.badgeRim:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -8)

    card.badgeBg = card:CreateTexture(nil, "OVERLAY")
    card.badgeBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    card.badgeBg:SetHeight(26)
    card.badgeBg:SetPoint("CENTER", card.badgeRim, "CENTER", 0, 0)
    card.badgeBg:SetGradientAlpha("VERTICAL", 0.04, 0.34, 0.06, 1, 0.20, 0.62, 0.14, 1)

    card.badge = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    UseFont(card.badge, Game15Font)
    card.badge:SetPoint("CENTER", card.badgeBg, "CENTER", 0, 0)
    card.badge:SetTextColor(1, 1, 1)
    card.badge:SetShadowOffset(1, -1)
    card.badge:SetShadowColor(0, 0, 0, 1)

    card:SetScript("OnClick", function(self)
        if not self.product then return end
        BSH.selectedProduct = self.product.id
        TryOnProduct(self.product)
        RefreshGrid()
    end)
    card:SetScript("OnEnter", function(self)
        if self.product then
            ShowProductTooltip(self, self.product)
        end
    end)
    card:SetScript("OnLeave", function()
        BSH.hoverCard = nil
        GameTooltip_Hide()
    end)
    card:Hide()
    return card
end

local function BuildPanel()
    if panel then return end

    panel = CreateFrame("Frame", "BattleshopHelperFrame", UIParent)
    panel:SetSize(1010, 505)
    panel:SetBackdrop(PANEL_BACKDROP)
    local db = BattleshopHelperDB
    if db and db.point then
        panel:SetPoint(db.point, UIParent, db.point, db.x or 0, db.y or 0)
    else
        panel:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    end
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        BattleshopHelperDB = BattleshopHelperDB or {}
        BattleshopHelperDB.point, BattleshopHelperDB.x, BattleshopHelperDB.y = point, x, y
    end)
    panel:SetFrameStrata("HIGH")
    panel:SetToplevel(true)
    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta)
        ChangePage(delta > 0 and -1 or 1)
    end)
    tinsert(UISpecialFrames, "BattleshopHelperFrame")

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", panel, "TOP", 0, -17)
    title:SetText("Shop")

    local closeButton = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -6)

    -- category rail
    groupButtons = {}
    for i = 1, GROUP_BUTTONS do
        local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        button:SetSize(150, 27)
        button:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -46 - (i - 1) * 31)
        button.icon = button:CreateTexture(nil, "OVERLAY")
        button.icon:SetSize(18, 18)
        button.icon:SetPoint("LEFT", button, "LEFT", 6, 0)
        button.icon:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")
        button:SetScript("OnClick", function(self)
            BSH.selectedGroup = self.groupId
            BSH.selectedProduct = nil
            BSH.page = 1
            RefreshGroups()
            RefreshGrid()
        end)
        button:Hide()
        groupButtons[i] = button
    end

    -- card grid: 4 x 2, like the battle shop
    cards = {}
    for i = 1, CARDS_PER_PAGE do
        local card = CreateCard(panel)
        local col = (i - 1) % 4
        local row = math.floor((i - 1) / 4)
        card:SetPoint("TOPLEFT", panel, "TOPLEFT", 180 + col * 140, -46 - row * 172)
        cards[i] = card
    end

    -- doublewide page: four plates, two by two, over the same area
    plateCards = {}
    for i = 1, DOUBLEWIDE_PER_PAGE do
        local card = CreatePlateCard(panel)
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        card:SetPoint("TOPLEFT", panel, "TOPLEFT", 180 + col * 282, -46 - row * 172)
        card:SetSize(268, 162)
        plateCards[i] = card
    end

    -- featured page: hero across the grid width, two smaller cards beneath
    heroCard = CreateFeaturedCard(panel, true)
    heroCard:SetPoint("TOPLEFT", panel, "TOPLEFT", 180, -46)
    heroCard:SetSize(4 * 140 - 10, 200)

    featCards = {}
    for i = 1, 2 do
        local card = CreateFeaturedCard(panel, false)
        card:SetPoint("TOPLEFT", panel, "TOPLEFT", 180 + (i - 1) * 282, -252)
        card:SetSize(268, 118)
        featCards[i] = card
    end

    -- buy row under the grid
    buyButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    buyButton:SetSize(170, 30)
    buyButton:SetPoint("TOP", panel, "TOP", -50, -46 - 2 * 172 - 8)
    buyButton:SetText("Buy Now")
    buyButton:Disable()
    buyButton:SetScript("OnClick", function()
        if BSH.selectedProduct then
            Send("BUY|" .. BSH.selectedProduct)
        end
    end)

    nextButton = CreateFrame("Button", nil, panel)
    nextButton:SetSize(28, 28)
    nextButton:SetPoint("TOPLEFT", panel, "TOPLEFT", 180 + 4 * 140 - 40, -46 - 2 * 172 - 9)
    nextButton:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
    nextButton:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down")
    nextButton:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Disabled")
    nextButton:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    nextButton:SetScript("OnClick", function() ChangePage(1) end)

    prevButton = CreateFrame("Button", nil, panel)
    prevButton:SetSize(28, 28)
    prevButton:SetPoint("RIGHT", nextButton, "LEFT", -66, 0)
    prevButton:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up")
    prevButton:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Down")
    prevButton:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Disabled")
    prevButton:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    prevButton:SetScript("OnClick", function() ChangePage(-1) end)

    pageText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageText:SetPoint("CENTER", prevButton, "CENTER", 47, 0)
    pageText:SetTextColor(1, 0.85, 0.24)

    -- try-on pane
    local modelInset = CreateFrame("Frame", nil, panel)
    modelInset:SetBackdrop(INSET_BACKDROP)
    modelInset:SetBackdropColor(0, 0, 0, 0.85)
    modelInset:SetBackdropBorderColor(0.82, 0.66, 0.29)
    modelInset:SetPoint("TOPLEFT", panel, "TOPLEFT", 180 + 4 * 140 + 6, -46)
    modelInset:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -16, 72)

    local function AttachModelRotation(frame)
        frame:EnableMouse(true)
        -- scrolling over a model zooms, as everywhere else in the game; this
        -- also stops the wheel from paging the grid while inspecting a model
        frame:EnableMouseWheel(true)
        frame:SetScript("OnMouseWheel", function(self, delta)
            self.zoom = math.max(0.5, math.min(3, (self.zoom or 1) - delta * 0.15))
            pcall(self.SetCamDistanceScale, self, self.zoom)
        end)
        frame:SetScript("OnMouseDown", function(self, mouseButton)
            if mouseButton == "LeftButton" then
                self.rotating = true
                self.rotateX = GetCursorPosition()
            end
        end)
        frame:SetScript("OnMouseUp", function(self)
            self.rotating = nil
        end)
        frame:SetScript("OnUpdate", function(self)
            if self.rotating then
                local x = GetCursorPosition()
                self:SetFacing((self:GetFacing() or 0) + (x - (self.rotateX or x)) * 0.02)
                self.rotateX = x
            end
        end)
    end

    model = CreateFrame("DressUpModel", nil, modelInset)
    model:SetPoint("TOPLEFT", 5, -5)
    model:SetPoint("BOTTOMRIGHT", -5, 5)
    model:SetUnit("player")
    model:Dress()
    AttachModelRotation(model)

    mountModel = CreateFrame("PlayerModel", nil, modelInset)
    mountModel:SetPoint("TOPLEFT", 5, -5)
    mountModel:SetPoint("BOTTOMRIGHT", -5, 5)
    mountModel:Hide()
    AttachModelRotation(mountModel)

    local sceneOk, scene = pcall(CreateFrame, "ModelScene", nil, modelInset, "ModelSceneMixinTemplate")
    if sceneOk and scene and scene.TransitionToModelSceneID then
        mountScene = scene
        mountScene:SetPoint("TOPLEFT", 5, -5)
        mountScene:SetPoint("BOTTOMRIGHT", -5, 5)
        mountScene:Hide()
        -- zoom the scene camera rather than letting the wheel page the grid
        mountScene:EnableMouseWheel(true)
        mountScene:SetScript("OnMouseWheel", function(self, delta)
            pcall(function() self:GetActiveCamera():ZoomByPercent(-delta * 0.1) end)
        end)
    end

    -- model controls under the pane
    local undressButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    undressButton:SetSize(72, 24)
    undressButton:SetPoint("TOPLEFT", modelInset, "BOTTOMLEFT", 0, -6)
    undressButton:SetText("Undress")
    undressButton:SetScript("OnClick", function()
        if BSH.mountMode then
            ResetModel()
        end
        model:Undress()
    end)

    local resetButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetButton:SetSize(72, 24)
    resetButton:SetPoint("LEFT", undressButton, "RIGHT", 5, 0)
    resetButton:SetText("Reset")
    resetButton:SetScript("OnClick", ResetModel)

    worldButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    worldButton:SetSize(90, 24)
    worldButton:SetPoint("LEFT", resetButton, "RIGHT", 5, 0)
    worldButton:SetText("In World")
    worldButton:Disable()
    worldButton:SetScript("OnClick", function()
        if BSH.selectedProduct then
            Send("PRV|" .. BSH.selectedProduct)
        end
    end)
    worldButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Preview on a clone of your character standing in the world - mounts show you riding.", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    worldButton:SetScript("OnLeave", GameTooltip_Hide)

    -- footer
    balanceText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    balanceText:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 18, 34)
    balanceText:SetJustifyH("LEFT")

    local footnote = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    footnote:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 18, 18)
    footnote:SetTextColor(0.6, 0.65, 0.74)
    footnote:SetText("*Prices in Battle Coins   |cff5a6373v" .. ADDON_VERSION .. "|r")

    blizzButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    blizzButton:SetSize(120, 22)
    blizzButton:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 320, 15)
    blizzButton:SetText("Standard Shop")
    blizzButton:Hide()
    blizzButton:SetScript("OnClick", function()
        panel:Hide()
        if BSH.origToggleStore then
            BSH.origToggleStore()
        end
    end)
end

local function ShowPanel()
    BuildPanel()
    panel:Show()
    if launcher then launcher:Hide() end
    if BSH.origToggleStore then blizzButton:Show() end
    if not BSH.catalogReady then
        Send(BSH.helloSent and "CAT" or "HELLO|1")
        BSH.helloSent = true
    end
    if not BSH.selectedGroup and BSH.groups[1] then
        BSH.selectedGroup = BSH.groups[1].id
    end
    RefreshGroups()
    RefreshGrid()
end

local function TogglePanel()
    if panel and panel:IsShown() then
        panel:Hide()
    else
        ShowPanel()
    end
end

local function ShowLauncher()
    if BSH.intercepted then return end
    if panel and panel:IsShown() then return end
    if not launcher then
        launcher = CreateFrame("Button", "BattleshopHelperLauncher", UIParent, "UIPanelButtonTemplate")
        launcher:SetSize(130, 26)
        launcher:SetPoint("TOP", UIParent, "TOP", 0, -120)
        launcher:SetFrameStrata("FULLSCREEN_DIALOG")
        launcher:SetText("Battleshop Helper")
        launcher:SetScript("OnClick", function(self)
            self:Hide()
            ShowPanel()
        end)
    end
    launcher:Show()
    C_Timer.After(30, function() if launcher then launcher:Hide() end end)
end

-- ---------------------------------------------------------------------------
-- shop button interception: only active once the server handshake allows it,
-- so missing addon or disabled bridge always falls back to the real store
-- ---------------------------------------------------------------------------

local function InterceptShop()
    if not BSH.intercept or BSH.intercepted then return end
    BSH.intercepted = true

    if type(ToggleStoreUI) == "function" then
        BSH.origToggleStore = ToggleStoreUI
        ToggleStoreUI = function()
            TogglePanel()
        end
    end
    if StoreMicroButton then
        StoreMicroButton:SetScript("OnClick", function()
            TogglePanel()
        end)
    end
    if GameMenuButtonStore then
        GameMenuButtonStore:SetScript("OnClick", function()
            HideUIPanel(GameMenuFrame)
            ShowPanel()
        end)
    end
end

-- ---------------------------------------------------------------------------
-- purchase confirmation
-- ---------------------------------------------------------------------------

StaticPopupDialogs["BATTLESHOP_HELPER_BUY"] = {
    text = "Buy %s for |cffffd83d%s Battle Coins|r?",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function()
        if BSH.pendingToken then
            Send("CFM|" .. BSH.pendingToken .. "|1")
            BSH.pendingToken = nil
        end
    end,
    OnCancel = function()
        if BSH.pendingToken then
            Send("CFM|" .. BSH.pendingToken .. "|0")
            BSH.pendingToken = nil
        end
    end,
    timeout = 30,
    whileDead = 1,
    hideOnEscape = 1,
    preferredIndex = 3,
}

-- ---------------------------------------------------------------------------
-- server messages
-- ---------------------------------------------------------------------------

local function ParseProducts(data)
    for entry in string.gmatch(data, "[^;]+") do
        local id, group, price, normal, kind, payload, icon, quality, name = string.match(entry, "^(%d+),(%d+),(%d+),(%d+),(%a),([^,]*),(%d+),(%d+),(.*)$")
        if id then
            id, group, price, normal = tonumber(id), tonumber(group), tonumber(price), tonumber(normal)
            icon, quality = tonumber(icon), tonumber(quality)
            local product = { id = id, group = group, price = price, normal = normal, kind = kind, items = {}, icon = icon, quality = quality, name = name }
            if kind == "M" then
                local itemId, display = string.match(payload, "^(%d+):(%d+)$")
                if itemId and tonumber(itemId) > 0 then
                    product.items[1] = tonumber(itemId)
                end
                product.display = tonumber(display)
            elseif kind == "P" then
                local display, scene = string.match(payload, "^(%d+):(%d+)$")
                product.display = tonumber(display) or tonumber(payload)
                product.scene = tonumber(scene)
            else
                for itemId in string.gmatch(payload, "[^:]+") do
                    itemId = tonumber(itemId)
                    if itemId and itemId > 0 then
                        tinsert(product.items, itemId)
                    end
                end
            end
            if not BSH.products[id] then
                BSH.byGroup[group] = BSH.byGroup[group] or {}
                tinsert(BSH.byGroup[group], id)
            end
            BSH.products[id] = product
        end
    end
end

local function OnServerMessage(msg)
    local cmd, rest = string.match(msg, "^(%u+)|?(.*)$")
    if not cmd then return end

    if cmd == "VER" then
        local _, balance, duration, intercept = string.match(rest, "^(%d+)|(%d+)|(%d+)|?(%d*)$")
        BSH.balance = tonumber(balance)
        BSH.duration = tonumber(duration) or 60
        BSH.intercept = intercept == "1"
        if BSH.intercept then
            InterceptShop()
        end
        if not BSH.catalogReady then
            Send("CAT")
        end
    elseif cmd == "GRP" then
        local id, icon, displayType, name = string.match(rest, "^(%d+)|(%d+)|(%d+)|(.*)$")
        if id then
            id, icon, displayType = tonumber(id), tonumber(icon), tonumber(displayType)
            local known
            for _, group in ipairs(BSH.groups) do
                if group.id == id then
                    group.name, group.icon, group.displayType = name, icon, displayType
                    known = true
                end
            end
            if not known then
                tinsert(BSH.groups, { id = id, icon = icon, displayType = displayType, name = name })
            end
        end
    elseif cmd == "PRD" then
        ParseProducts(rest)
    elseif cmd == "END" then
        BSH.catalogReady = true

        if not BSH.selectedGroup and BSH.groups[1] then
            BSH.selectedGroup = BSH.groups[1].id
        end
        RefreshGroups()
        RefreshGrid()
    elseif cmd == "BAL" then
        BSH.balance = tonumber(rest)
        RefreshGrid()
    elseif cmd == "DSC" then
        local id, text = string.match(rest, "^(%d+)|(.*)$")
        if id then
            BSH.desc[tonumber(id)] = text
            if BSH.hoverCard and BSH.hoverCard.product and BSH.hoverCard.product.id == tonumber(id) then
                ShowProductTooltip(BSH.hoverCard, BSH.hoverCard.product)
            end
        end
    elseif cmd == "CFM" then
        local productId, price, token = string.match(rest, "^(%d+)|(%d+)|(%d+)$")
        if token then
            BSH.pendingToken = token
            local product = BSH.products[tonumber(productId)]
            StaticPopup_Show("BATTLESHOP_HELPER_BUY", product and ProductLabel(product) or ("product " .. productId), price)
        end
    elseif cmd == "RES" then
        local status, detail = string.match(rest, "^(%u+)|?(.*)$")
        if status == "OK" then
            local productId, balance = string.match(detail, "^(%d+)|(%d+)$")
            BSH.balance = tonumber(balance) or BSH.balance
            local product = productId and BSH.products[tonumber(productId)]
            Print("Purchased " .. (product and ProductLabel(product) or "your item") .. "!")
            RefreshGrid()
        else
            Print("|cffff4444" .. (detail ~= "" and detail or "Purchase failed.") .. "|r")
        end
    elseif cmd == "TRY" then
        ShowPanel()
        if BSH.mountMode then
            ShowCharacterModel()
        end
        for itemId in string.gmatch(rest, "[^:]+") do
            TryOnItem(tonumber(itemId))
        end
    elseif cmd == "TRYM" then
        ShowPanel()
        local display, scene = string.match(rest, "^(%d+):(%d+)$")
        if display then
            ShowMount(tonumber(display), tonumber(scene), true)
        else
            ShowMount(tonumber(rest))
        end
    elseif cmd == "OPN" then
        ShowLauncher()
    end
end

-- ---------------------------------------------------------------------------
-- events and slash command
-- ---------------------------------------------------------------------------

eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "PLAYER_ENTERING_WORLD" then
        RegisterAddonMessagePrefix(PREFIX)
        if not BSH.helloSent then
            BSH.helloSent = true
            Send("HELLO|1")
        end
    elseif event == "CHAT_MSG_ADDON" then
        if arg1 == PREFIX then
            OnServerMessage(arg2)
        end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        local itemId = tonumber(arg1)
        if itemId and BSH.pendingTryOn[itemId] then
            BSH.pendingTryOn[itemId] = nil
            if panel and panel:IsShown() and not BSH.mountMode then
                model:TryOn("item:" .. itemId)
            end
        end
        if panel and panel:IsShown() then
            RefreshGrid()
        end
    end
end)

SLASH_BATTLESHOPHELPER1 = "/battleshop"
SLASH_BATTLESHOPHELPER2 = "/bsh"
SLASH_BATTLESHOPHELPER3 = "/shop"
SLASH_BATTLESHOPHELPER4 = "/fitroom"
SLASH_BATTLESHOPHELPER5 = "/fittingroom"
SlashCmdList["BATTLESHOPHELPER"] = TogglePanel
