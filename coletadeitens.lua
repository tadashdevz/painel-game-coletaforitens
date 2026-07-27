-- ╔══════════════════════════════════════════════════════════════╗
-- ║   PAINEL SYSTEM FARM · UGC 83622406313819                    ║
-- ║   Tema preto/branco · Menus Farm / Player                    ║
-- ║   Auto Ataque + Skills + Auto Quest + Quest Mais Alta         ║
-- ║   + Auto Coletar Drop (filtro de raridade)                    ║
-- ║   + Agrupar Mobs + Hitbox Expander (5-25 studs)              ║
-- ║   + Farm Masmora (ataca qualquer mob presente, sem TP)        ║
-- ║   Quest Mais Alta: busca automaticamente a quest de maior    ║
-- ║   level requerido disponível para o level do jogador         ║
-- ╚══════════════════════════════════════════════════════════════╝

local Players           = game:GetService("Players")
local ReplicatedFirst    = game:GetService("ReplicatedFirst")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

-- ══════════════════════════════════════════════════
--  ACESSO AO CONTROLLER DE COMBATE DO PRÓPRIO JOGO
--  (mesmo módulo que o clique esquerdo/teclas 1-2-3
--  usam, então os hits e skills batem "de verdade")
-- ══════════════════════════════════════════════════
local Combat = nil
pcall(function()
    Combat = require(
        ReplicatedFirst:WaitForChild("Client")
            :WaitForChild("Controllers")
            :WaitForChild("Combat")
    )
end)

local function safeAttack()
    if not Combat then return end
    pcall(function() Combat:Attack() end)
end

local function safeSkill(n)
    if not Combat then return end
    pcall(function() Combat:Skill(n) end)
end

-- ══════════════════════════════════════════════════
--  TELEPORTE ENTRE MUNDOS (remote oficial do jogo)
--  Os mundos ficam MUITO distantes um do outro no
--  mapa. Um CFrame direto sem passar pelo remote
--  "TeleportZone" não atualiza o CurrentWorld no
--  servidor, então o servidor corrige/rejeita a
--  posição e te devolve pro mundo antigo. Por isso
--  usamos o mesmo remote que os portais do jogo usam.
-- ══════════════════════════════════════════════════
local Net = nil
pcall(function()
    Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Core"):WaitForChild("Net"))
end)

local TeleportZoneEvent = nil
pcall(function()
    if Net then
        TeleportZoneEvent = Net:GetEvent("TeleportZone")
    end
end)

-- ══════════════════════════════════════════════════
--  SISTEMA DE NPC QUEST (aceite real da quest no servidor)
--  O jogo usa NPCQuestDialog.mod.lua (quests "NPCQuest1"
--  a "NPCQuest48") como sistema de quest "de verdade":
--  só UMA fica ativa por vez, e as mortes só contam se
--  a quest foi ACEITA via remote Accept:FireServer(id).
--  Sem isso, teleportar até o mob e atacar não avança
--  nenhuma missão (é exatamente o bug relatado).
-- ══════════════════════════════════════════════════
local NPCQuestDialog = nil
pcall(function()
    NPCQuestDialog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("NPCQuestDialog"))
end)

local NPCQuestAcceptEvent = nil
local NPCQuestGetState     = nil
local NPCQuestStateChanged = nil
pcall(function()
    local remotesFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"):WaitForChild("NPCQuest")
    NPCQuestAcceptEvent = remotesFolder:WaitForChild("Accept")
    NPCQuestGetState     = remotesFolder:WaitForChild("GetState")
    NPCQuestStateChanged = remotesFolder:WaitForChild("StateChanged")
end)

-- Cache local do estado de cada NPCQuest (accepted, progress, activeQuestId etc.)
local npcQuestStates = {}

local function getNPCQuestState(questId)
    if not NPCQuestGetState then return nil end
    local ok, result = pcall(function()
        return NPCQuestGetState:InvokeServer(questId)
    end)
    if ok and type(result) == "table" then
        npcQuestStates[questId] = result
        return result
    end
    return npcQuestStates[questId]
end

-- Descobre qual NPCQuest está ativa no momento (se alguma)
local function getActiveNPCQuestId()
    for questId, state in pairs(npcQuestStates) do
        if type(state) == "table" and state.accepted then
            return questId
        end
    end
    return nil
end

-- Aceita uma NPCQuest no servidor. Se já houver outra ativa,
-- o remote cancela a antiga e ativa a nova (comportamento do jogo).
local function acceptNPCQuest(questId)
    if not (NPCQuestAcceptEvent and questId) then return false end
    local ok = pcall(function()
        NPCQuestAcceptEvent:FireServer(questId)
    end)
    if ok then
        -- Atualiza cache local otimisticamente; o StateChanged do servidor
        -- vai corrigir caso algo dê errado (level insuficiente, cooldown etc.)
        npcQuestStates[questId] = npcQuestStates[questId] or {}
        npcQuestStates[questId].accepted = true
    end
    return ok
end

-- Escuta atualizações de estado do servidor (aceite confirmado, progresso, etc.)
if NPCQuestStateChanged then
    pcall(function()
        NPCQuestStateChanged.OnClientEvent:Connect(function(questId, state, reason)
            if type(questId) == "string" then
                npcQuestStates[questId] = state
            end
        end)
    end)
end

-- Busca o estado inicial de todas as NPCQuests conhecidas (assíncrono,
-- não bloqueia o carregamento do resto do script)
task.spawn(function()
    if not NPCQuestDialog then return end
    for questId in pairs(NPCQuestDialog) do
        if type(questId) == "string" and questId:match("^NPCQuest%d+$") then
            task.spawn(function()
                getNPCQuestState(questId)
            end)
        end
    end
end)

-- ══════════════════════════════════════════════════
--  SISTEMA DE FORJA (Forge / ExpertForge / MagicForge)
--  Baseado nos módulos reais do jogo:
--  - Forge Normal:  nível 0 → 6   (usa Gold + Shards)
--  - Magic Forge:   nível 6 → 10  (usa Gold + Shards, tag "+6".."+10")
--  - Expert Forge:  nível 10 → 15 (usa apenas ForgeShards "st_9", tag "+10".."+15")
--  Proteção: item "st_3" (Forgeguard) impede perda de nível na falha
-- ══════════════════════════════════════════════════
local ForgeData       = nil -- ReplicatedStorage.Shared.Data.Forge
local ExpertForgeData = nil -- ReplicatedStorage.Shared.Data.ExpertForge
local MagicForgeData  = nil -- ReplicatedStorage.Shared.Data.MagicForge

pcall(function()
    ForgeData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Forge"))
end)
pcall(function()
    ExpertForgeData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("ExpertForge"))
end)
pcall(function()
    MagicForgeData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("MagicForge"))
end)

local ForgeEvent       = nil
local ExpertForgeEvent = nil
local MagicForgeEvent  = nil
pcall(function()
    if Net then
        ForgeEvent       = Net:GetEvent("Forge")
        ExpertForgeEvent = Net:GetEvent("ExpertForge")
        MagicForgeEvent  = Net:GetEvent("MagicForge")
    end
end)

-- Acesso à janela de Inventário do jogo (lista real de itens)
local function getInventoryWindow()
    local ok, result = pcall(function()
        return Combat.Controllers.UI.Windows.Inventory
    end)
    if ok then return result end
    return nil
end

-- Mapeia o prefixo da chave do item (w_, ah_, ac_, al_, ab_) pra uma
-- categoria legível. Fonte: Items.mod.lua (KeyToSlot / cada sub-módulo
-- registra seu próprio prefixo: Weapon="w", Headgear="ah",
-- Chestplate="ac", Leggings="al", Boots="ab").
local CATEGORY_BY_PREFIX = {
    w  = "Weapon",
    ah = "Headgear",
    ac = "Chestplate",
    al = "Leggings",
    ab = "Boots",
}

local function getItemCategory(itemKey)
    local prefix = itemKey:match("^(%a+)_")
    return CATEGORY_BY_PREFIX[prefix] or "Other"
end

-- Retorna lista de itens de Equipamento do jogador
-- cada item: { key = uid, name, level, rarity, equipped, category, powerScore }
local function getForgeableItems()
    local items = {}
    local inv = getInventoryWindow()
    if not inv or not inv.Items then return items end

    for key, v in pairs(inv.Items) do
        if v.type == "Equipment" and v.data and v.data.uid and (not v.info or v.info.rarity ~= 1001) then
            local level = (v.data.meta and v.data.meta.level) or 0
            -- v.id é a chave de DEFINIÇÃO do item (ex: "w_5", "ah_12"),
            -- diferente de "key" que é o uid único da instância no
            -- inventário. v.powerScore já vem calculado pelo próprio
            -- jogo (Sort:GetPowerScore) — usamos ele pra ordenar por
            -- "item mais forte" sem reinventar a fórmula de poder.
            table.insert(items, {
                key        = key,
                name       = (v.info and v.info.name) or key,
                level      = level,
                rarity     = (v.info and v.info.rarity) or 1,
                equipped   = v.equipped or false,
                category   = getItemCategory(tostring(v.id or key)),
                powerScore = tonumber(v.powerScore) or 0,
            })
        end
    end

    -- Mais forte primeiro (powerScore desc), depois nível de forja desc
    table.sort(items, function(a, b)
        if a.powerScore ~= b.powerScore then return a.powerScore > b.powerScore end
        if a.level ~= b.level then return a.level > b.level end
        return a.name < b.name
    end)
    return items
end

local function getForgeguardCount()
    local inv = getInventoryWindow()
    if not inv then return 0 end
    local ok, result = pcall(function() return inv:GetStackCount("st_3") end)
    if ok and type(result) == "number" then return result end
    return 0
end

local function getForgeShardsCount() -- st_9 usado pela Expert Forge
    local inv = getInventoryWindow()
    if not inv then return 0 end
    local ok, result = pcall(function() return inv:GetStackCount("st_9") end)
    if ok and type(result) == "number" then return result end
    return 0
end

-- Determina qual forja usar baseado no nível ATUAL do item
-- retorna: "forge" | "magic" | "expert" | nil (já no máximo pra essa faixa)
local function getForgeStageForLevel(level)
    if level < 6 then
        return "forge", ForgeEvent, ForgeData
    elseif level < 10 then
        return "magic", MagicForgeEvent, MagicForgeData
    elseif level < 15 then
        return "expert", ExpertForgeEvent, ExpertForgeData
    end
    return nil, nil, nil
end

local function getCurrentWorld()
    local ok, result = pcall(function()
        return Combat.Controllers.Replication:GetKey("Data", "CurrentWorld")
    end)
    if ok then return result end
    return nil
end

local function getPlayerLevel()
    local ok, result = pcall(function()
        return Combat.Controllers.Replication:GetKey("Data", "Level")
    end)
    if ok and type(result) == "number" then return result end
    return 1
end

local function getPlayerGold()
    local ok, result = pcall(function()
        return Combat.Controllers.Replication:GetKey("Data", "Gold")
    end)
    if ok and type(result) == "number" then return result end
    return 0
end

local function getPlayerShards()
    local ok, result = pcall(function()
        return Combat.Controllers.Replication:GetKey("Data", "Shards")
    end)
    if ok and type(result) == "number" then return result end
    return 0
end

-- Verifica se dá pra forjar o item (tem recursos suficientes)
local function canForgeItem(stage, dataModule, item)
    if stage == "expert" then
        local cost = dataModule:GetCost(item.rarity, item.level)
        return getForgeShardsCount() >= cost
    else
        local goldCost, shardCost = dataModule:GetCost(item.rarity, item.level)
        return getPlayerGold() >= goldCost and getPlayerShards() >= shardCost
    end
end

local statusLabel -- setado depois de criar a UI

-- Garante que o personagem está no mundo do mob antes de
-- tentar farmar. Retorna true se já está / conseguiu trocar.
local function ensureWorld(worldName)
    local current = getCurrentWorld()
    if current == worldName then
        return true
    end

    if statusLabel then
        statusLabel.Text = ("Indo para %s..."):format(worldName)
    end

    if TeleportZoneEvent then
        pcall(function()
            TeleportZoneEvent:FireServer(worldName, 1)
        end)
    end

    pcall(function()
        if Combat.Controllers.World then
            Combat.Controllers.World:SetLighting(worldName)
            Combat.Controllers.World:SetAfkButton(worldName)
        end
    end)

    local waited = 0
    while waited < 6 do
        task.wait(0.25)
        waited = waited + 0.25
        if getCurrentWorld() == worldName then
            task.wait(0.5) -- tempo extra pro mapa/inimigos carregarem
            return true
        end
    end

    return getCurrentWorld() == worldName
end

-- ══════════════════════════════════════════════════
--  CONFIG
-- ══════════════════════════════════════════════════
local cfg = {
    hoverHeight       = 8,     -- altura do TP acima do mob
    autoAttack        = true,  -- hits automáticos
    autoSkills        = false, -- skills automáticas (opcional)
    autoCollect       = false, -- coletar itens dropados automaticamente
    autoQuestHighest  = false, -- loop autônomo "Quest Mais Alta"
    collectRarities   = {},    -- set: [rarityId] = true
    bringMob          = false, -- traz o mob até você
    hitboxSize        = 10,    -- tamanho da hitbox dos mobs (padrão 10)
    hitboxAuto        = true,  -- hitbox automática baseada no tipo de mob
    forgeUseProtection = true, -- usa Forgeguard automaticamente quando disponível
    farmDungeon       = false, -- Farm Masmora: ataca QUALQUER mob presente (dentro da dungeon/torre)
}

-- ══════════════════════════════════════════════════
--  AUTO FORJA: estado do loop de forja automática
-- ══════════════════════════════════════════════════
local autoForgeRunning  = false
local autoForgeToken    = 0
local selectedForgeItems = {} -- set: [itemKey] = true
local forgeTargetLevel  = 10  -- nível alvo (padrão +10)
local forgeStatusLabel  = nil -- setado na criação da UI

local function setForgeStatus(text)
    if forgeStatusLabel then
        forgeStatusLabel.Text = text
    end
end

-- Forja um único item até o nível alvo (ou até não conseguir mais)
local function forgeItemToLevel(item, targetLevel, myToken)
    while autoForgeRunning and autoForgeToken == myToken do
        -- Reconsulta o nível atual do item (pode ter mudado)
        local items = getForgeableItems()
        local fresh = nil
        for _, it in ipairs(items) do
            if it.key == item.key then fresh = it break end
        end
        if not fresh then
            setForgeStatus(("%s: item não encontrado"):format(item.name))
            return
        end

        if fresh.level >= targetLevel then
            setForgeStatus(("%s: concluído (+%d)"):format(fresh.name, fresh.level))
            return
        end

        local stage, event, dataModule = getForgeStageForLevel(fresh.level)
        if not stage or not event or not dataModule then
            setForgeStatus(("%s: forja indisponível no nível +%d"):format(fresh.name, fresh.level))
            return
        end

        if not canForgeItem(stage, dataModule, fresh) then
            setForgeStatus(("%s: sem recursos suficientes (+%d)"):format(fresh.name, fresh.level))
            return
        end

        -- Decide se usa proteção (Forgeguard)
        local useProtection = false
        if cfg.forgeUseProtection and getForgeguardCount() > 0 then
            useProtection = true
        end

        setForgeStatus(("Forjando %s: +%d → +%d%s"):format(
            fresh.name, fresh.level, fresh.level + 1, useProtection and " [protegido]" or ""
        ))

        local ok = pcall(function()
            event:FireServer(fresh.key, useProtection or nil)
        end)

        if not ok then
            setForgeStatus(("%s: erro ao forjar"):format(fresh.name))
            return
        end

        -- Aguarda a animação/roll do servidor processar (respeita cooldown de 1.5s do jogo)
        task.wait(1.8)
    end
end

-- Loop principal: forja todos os itens selecionados, um por vez
local function startAutoForge()
    if autoForgeRunning then return end
    autoForgeRunning = true
    autoForgeToken = autoForgeToken + 1
    local myToken = autoForgeToken

    task.spawn(function()
        local keys = {}
        for key, sel in pairs(selectedForgeItems) do
            if sel then table.insert(keys, key) end
        end

        if #keys == 0 then
            setForgeStatus("Nenhum item selecionado")
            autoForgeRunning = false
            return
        end

        for _, key in ipairs(keys) do
            if not (autoForgeRunning and autoForgeToken == myToken) then break end

            local items = getForgeableItems()
            local item = nil
            for _, it in ipairs(items) do
                if it.key == key then item = it break end
            end

            if item then
                forgeItemToLevel(item, forgeTargetLevel, myToken)
            end
        end

        if autoForgeToken == myToken then
            setForgeStatus("Auto Forja concluída")
            autoForgeRunning = false
        end
    end)
end

local function stopAutoForge()
    autoForgeRunning = false
    autoForgeToken = autoForgeToken + 1
    setForgeStatus("Auto Forja parada")
end

-- ══════════════════════════════════════════════════
--  RARIDADES (RarityTiers.mod.lua do dump)
-- ══════════════════════════════════════════════════
local RARITY_LIST = {
    {id = 1,    name = "Common"},
    {id = 2,    name = "Uncommon"},
    {id = 3,    name = "Rare"},
    {id = 4,    name = "Epic"},
    {id = 5,    name = "Legendary"},
    {id = 6,    name = "Mythic"},
    {id = 999,  name = "Special"},
    {id = 1000, name = "Unique"},
    {id = 1001, name = "Apex"},
    {id = 1002, name = "Cosmetic"},
}

-- ══════════════════════════════════════════════════
--  LISTA DE MOBS (nome, level do mob, mundo, nível
--  mínimo pra acessar o mundo daquele mob)
--  Fonte: Enemies.mod.lua / Worlds.mod.lua do dump
--  maxHitbox: tamanho máximo recomendado da hitbox
--  (mobs normais: 25, miniboss: 35, boss: 45)
-- ══════════════════════════════════════════════════
local MOB_LIST = {
    -- World1 · Valor Village (sem requisito de nível, min = 1)
    {name = "Chicken",               lv = 1,   minLv = 1,   world = "World1", maxHitbox = 25},
    {name = "Slime",                 lv = 5,   minLv = 1,   world = "World1", maxHitbox = 25},
    {name = "Boar",                  lv = 10,  minLv = 1,   world = "World1", maxHitbox = 25},
    {name = "Bandit",                lv = 15,  minLv = 1,   world = "World1", maxHitbox = 25},
    {name = "Funglet",               lv = 20,  minLv = 1,   world = "World1", maxHitbox = 25},
    {name = "Twigling",              lv = 25,  minLv = 1,   world = "World1", maxHitbox = 25},
    {name = "Giant Snail",           lv = 30,  minLv = 1,   world = "World1", maxHitbox = 25},
    {name = "Bandit King",           lv = 30,  minLv = 1,   world = "World1", tag = "Miniboss", maxHitbox = 35},
    {name = "Mushroom Lancer",       lv = 35,  minLv = 1,   world = "World1", maxHitbox = 25},
    {name = "Brambleback",           lv = 40,  minLv = 1,   world = "World1", maxHitbox = 25},
    {name = "Eldershroom",           lv = 45,  minLv = 1,   world = "World1", maxHitbox = 25},
    {name = "Captain Shroom Lancer", lv = 50,  minLv = 1,   world = "World1", tag = "Miniboss", maxHitbox = 35},
    {name = "Lord Bramble",          lv = 60,  minLv = 1,   world = "World1", tag = "Miniboss", maxHitbox = 35},
    {name = "The Fungal Ronin",      lv = 70,  minLv = 1,   world = "World1", tag = "Boss", maxHitbox = 45},

    -- World2 · Hallow Hills (min level 80)
    {name = "Husk",        lv = 80,  minLv = 80, world = "World2", maxHitbox = 25},
    {name = "Skeleton",    lv = 90,  minLv = 80, world = "World2", maxHitbox = 25},
    {name = "Grave Dude",  lv = 100, minLv = 80, world = "World2", maxHitbox = 25},
    {name = "Druid",       lv = 140, minLv = 80, world = "World2", maxHitbox = 25},
    {name = "Bear Cub",    lv = 150, minLv = 80, world = "World2", maxHitbox = 25},
    {name = "Bear",        lv = 150, minLv = 80, world = "World2", tag = "Miniboss", maxHitbox = 35},
    {name = "Cave Golem",  lv = 260, minLv = 80, world = "World2", maxHitbox = 25},

    -- World3 · Tundra Town (min level 150)
    {name = "Dark Elf",    lv = 150, minLv = 150, world = "World3", maxHitbox = 25},
    {name = "Snow Goblin", lv = 150, minLv = 150, world = "World3", maxHitbox = 25},
    {name = "Thief",       lv = 170, minLv = 150, world = "World3", maxHitbox = 25},
    {name = "Snow Bandit", lv = 180, minLv = 150, world = "World3", maxHitbox = 25},
    {name = "Snowman",     lv = 190, minLv = 150, world = "World3", maxHitbox = 25},
    {name = "Ice Giant",   lv = 200, minLv = 150, world = "World3", maxHitbox = 25},
    {name = "White Wolf",  lv = 220, minLv = 150, world = "World3", maxHitbox = 25},
    {name = "Ice Queen",   lv = 240, minLv = 150, world = "World3", tag = "Miniboss", maxHitbox = 35},
    {name = "Yeti",        lv = 260, minLv = 150, world = "World3", tag = "Boss", maxHitbox = 45},

    -- World4 · Magma Mountain (min level 225)
    {name = "Meltrox",           lv = 280, minLv = 225, world = "World4", maxHitbox = 25},
    {name = "Fire Mage",         lv = 300, minLv = 225, world = "World4", maxHitbox = 25},
    {name = "Magma Golem",       lv = 320, minLv = 225, world = "World4", maxHitbox = 25},
    {name = "Fire Imp",          lv = 340, minLv = 225, world = "World4", maxHitbox = 25},
    {name = "Smoldering Knight", lv = 360, minLv = 225, world = "World4", maxHitbox = 25},
    {name = "Demon",             lv = 380, minLv = 225, world = "World4", maxHitbox = 25},
    {name = "Fire Spirit",       lv = 400, minLv = 225, world = "World4", maxHitbox = 25},
    {name = "Obsidian Crab",     lv = 425, minLv = 225, world = "World4", maxHitbox = 25},
    {name = "Dragon",            lv = 450, minLv = 225, world = "World4", tag = "Boss", maxHitbox = 45},

    -- World5 · Desert Dunes (min level 375)
    {name = "Pirate Skeleton", lv = 480, minLv = 375, world = "World5", maxHitbox = 25},
    {name = "Coyote",          lv = 490, minLv = 375, world = "World5", maxHitbox = 25},
    {name = "Cobra",           lv = 500, minLv = 375, world = "World5", maxHitbox = 25},
    {name = "Mummy",           lv = 510, minLv = 375, world = "World5", maxHitbox = 25},
    {name = "Royal Egyptian",  lv = 520, minLv = 375, world = "World5", maxHitbox = 25},
    {name = "Desert Bandit",   lv = 520, minLv = 375, world = "World5", maxHitbox = 25},
    {name = "Evil Pharaoh",    lv = 520, minLv = 375, world = "World5", tag = "Miniboss", maxHitbox = 35},
    {name = "King Snake",      lv = 520, minLv = 375, world = "World5", tag = "Miniboss", maxHitbox = 35},
    {name = "Anubis",          lv = 540, minLv = 375, world = "World5", tag = "Boss", maxHitbox = 45},

    -- World6 · Shattered Realms (min level 550)
    {name = "Celestial Wisp", lv = 600, minLv = 550, world = "World6", maxHitbox = 25},
    {name = "Prism Beetle",   lv = 610, minLv = 550, world = "World6", maxHitbox = 25},
    {name = "Nebula Slime",   lv = 620, minLv = 550, world = "World6", maxHitbox = 25},
    {name = "Halo Golem",     lv = 630, minLv = 550, world = "World6", maxHitbox = 25},
    {name = "Sunflare Harpy", lv = 640, minLv = 550, world = "World6", maxHitbox = 25},
    {name = "Tempest Ram",    lv = 650, minLv = 550, world = "World6", tag = "Miniboss", maxHitbox = 35},
    {name = "Astral Oracle",  lv = 660, minLv = 550, world = "World6", tag = "Miniboss", maxHitbox = 35},
    {name = "Seraphim Titan", lv = 670, minLv = 550, world = "World6", tag = "Boss", maxHitbox = 45},
}

local function findMobEntry(mobName)
    for _, m in ipairs(MOB_LIST) do
        if m.name == mobName then return m end
    end
    return nil
end

-- ══════════════════════════════════════════════════
--  MUNDOS: nível mínimo + ranking (usado pela Quest
--  Mais Alta pra saber qual mundo é "mais avançado")
--  Fonte: Worlds.mod.lua do dump
-- ══════════════════════════════════════════════════
local WORLD_MIN_LV = {
    World1 = 1,
    World2 = 80,
    World3 = 150,
    World4 = 225,
    World5 = 375,
    World6 = 550,
}
local WORLD_RANK = {
    World1 = 1,
    World2 = 2,
    World3 = 3,
    World4 = 4,
    World5 = 5,
    World6 = 6,
}

-- ══════════════════════════════════════════════════
--  LISTA DE QUESTS (sistema real de NPC Quest)
--  Fonte: NPCQuestDialog.mod.lua do dump. Cada entrada
--  usa o questId REAL ("NPCQuest1".."NPCQuest48") que
--  precisa ser aceito via remote NPCQuest.Accept antes
--  das mortes contarem. Apenas quests com 1 objetivo
--  (1 tipo de mob) entram aqui — as de múltiplos mobs
--  (ex: NPCQuest4 = Bandit + Funglet) ficam de fora do
--  farm automático de "1 mob só" mas ainda aparecem no
--  seletor manual usando o primeiro mob do objetivo.
-- ══════════════════════════════════════════════════
local QUEST_LIST = {
    {questId = "NPCQuest1",  mob = "Chicken",               title = "Lady Mary - Kill 15 Chickens",             target = 15, world = "World1", minLv = 1},
    {questId = "NPCQuest2",  mob = "Slime",                 title = "Lady Mary - Kill 15 Slimes",               target = 15, world = "World1", minLv = 3},
    {questId = "NPCQuest3",  mob = "Boar",                  title = "Lady Mary - Kill 15 Boars",                target = 15, world = "World1", minLv = 5},
    {questId = "NPCQuest4",  mob = "Bandit",                title = "Astrid Freya - Kill Bandits & Funglets",   target = 15, world = "World1", minLv = 10},
    {questId = "NPCQuest5",  mob = "Twigling",              title = "Astrid Freya - Kill Twiglings & Snails",   target = 15, world = "World1", minLv = 15},
    {questId = "NPCQuest6",  mob = "Bandit King",           title = "Astrid Freya - Kill 5 Bandit Kings",       target = 5,  world = "World1", minLv = 25},
    {questId = "NPCQuest7",  mob = "Mushroom Lancer",       title = "Achard Bane - Kill 15 Mushroom Lancers",   target = 15, world = "World1", minLv = 35},
    {questId = "NPCQuest8",  mob = "Brambleback",           title = "Achard Bane - Kill 15 Bramblebacks",       target = 15, world = "World1", minLv = 45},
    {questId = "NPCQuest9",  mob = "Eldershroom",           title = "Achard Bane - Kill 15 Eldershrooms",       target = 15, world = "World1", minLv = 50},

    {questId = "NPCQuest10", mob = "Husk",        title = "Bjorn Hildegard - Kill 15 Husks",       target = 15, world = "World2", minLv = 80},
    {questId = "NPCQuest12", mob = "Skeleton",    title = "Sir Tyaro - Kill 15 Skeletons",         target = 15, world = "World2", minLv = 90},
    {questId = "NPCQuest11", mob = "Grave Dude",  title = "Sir Tyaro - Kill 15 Grave Dudes",       target = 15, world = "World2", minLv = 100},
    {questId = "NPCQuest13", mob = "Druid",       title = "Sir Tyaro - Kill 15 Druids",            target = 15, world = "World2", minLv = 105},
    {questId = "NPCQuest15", mob = "Cave Golem",  title = "Sifrah Emory - Kill 5 Cave Golems",     target = 5,  world = "World2", minLv = 120},
    {questId = "NPCQuest14", mob = "Bear Cub",    title = "Sifrah Emory - Kill 15 Bear Cubs",      target = 15, world = "World2", minLv = 130},
    {questId = "NPCQuest16", mob = "Bear",        title = "Sifrah Emory - Kill 3 Bears",           target = 3,  world = "World2", minLv = 135},

    {questId = "NPCQuest17", mob = "Snow Goblin", title = "Brother Cedric - Kill 15 Snow Goblins", target = 15, world = "World3", minLv = 150},
    {questId = "NPCQuest18", mob = "Thief",       title = "Brother Cedric - Kill 15 Thieves",      target = 15, world = "World3", minLv = 155},
    {questId = "NPCQuest19", mob = "Snow Bandit", title = "Brother Cedric - Kill 15 Snow Bandits", target = 15, world = "World3", minLv = 165},
    {questId = "NPCQuest20", mob = "Snowman",     title = "Seraphina Vale - Kill 15 Snowmen",      target = 15, world = "World3", minLv = 175},
    {questId = "NPCQuest21", mob = "Ice Giant",   title = "Seraphina Vale - Kill 15 Ice Giants",   target = 15, world = "World3", minLv = 180},
    {questId = "NPCQuest22", mob = "White Wolf",  title = "Seraphina Vale - Kill 15 White Wolves", target = 15, world = "World3", minLv = 195},
    {questId = "NPCQuest23", mob = "Yeti",        title = "Dheiros Baldwin - Kill 3 Yetis",        target = 3,  world = "World3", minLv = 210},

    {questId = "NPCQuest24", mob = "Meltrox",           title = "Mira of Valor - Kill 15 Meltrox",            target = 15, world = "World4", minLv = 225},
    {questId = "NPCQuest25", mob = "Fire Imp",          title = "Mira of Valor - Kill 15 Fire Imps",          target = 15, world = "World4", minLv = 230},
    {questId = "NPCQuest26", mob = "Fire Mage",         title = "Mira of Valor - Kill 15 Fire Mages",         target = 15, world = "World4", minLv = 250},
    {questId = "NPCQuest27", mob = "Smoldering Knight", title = "Thane Greeves - Kill 15 Smoldering Knight",  target = 15, world = "World4", minLv = 260},
    {questId = "NPCQuest28", mob = "Demon",             title = "Thane Greeves - Kill 15 Demons",             target = 15, world = "World4", minLv = 275},
    {questId = "NPCQuest29", mob = "Magma Golem",       title = "Thane Greeves - Kill 15 Magma Golems",       target = 15, world = "World4", minLv = 295},
    {questId = "NPCQuest30", mob = "Fire Spirit",       title = "Ileana Zimuns - Kill 15 Fire Spirits",       target = 15, world = "World4", minLv = 305},
    {questId = "NPCQuest31", mob = "Obsidian Crab",     title = "Ileana Zimuns - Kill 15 Obsidian Crabs",     target = 15, world = "World4", minLv = 310},
    {questId = "NPCQuest32", mob = "Dragon",            title = "Ileana Zimuns - Kill 3 Dragons",             target = 3,  world = "World4", minLv = 335},

    {questId = "NPCQuest33", mob = "Pirate Skeleton", title = "Eliza Thorne - Kill 15 Pirate Skeletons",  target = 15, world = "World5", minLv = 375},
    {questId = "NPCQuest34", mob = "Mummy",           title = "Eliza Thorne - Kill 15 Mummies",           target = 15, world = "World5", minLv = 390},
    {questId = "NPCQuest35", mob = "Evil Pharaoh",    title = "Eliza Thorne - Kill 5 Evil Pharaohs",      target = 5,  world = "World5", minLv = 400},
    {questId = "NPCQuest36", mob = "Royal Egyptian",  title = "Yveren Rimecrest - Kill 15 Royal Egyptians", target = 15, world = "World5", minLv = 425},
    {questId = "NPCQuest37", mob = "Coyote",          title = "Yveren Rimecrest - Kill 15 Coyotes",       target = 15, world = "World5", minLv = 455},
    {questId = "NPCQuest38", mob = "Desert Bandit",   title = "Yveren Rimecrest - Kill 15 Desert Bandits", target = 15, world = "World5", minLv = 485},
    {questId = "NPCQuest39", mob = "Cobra",           title = "Alynn Greywood - Kill 15 Cobras",          target = 15, world = "World5", minLv = 515},
    {questId = "NPCQuest40", mob = "King Snake",      title = "Alynn Greywood - Kill 5 King Snakes",      target = 5,  world = "World5", minLv = 520},
    {questId = "NPCQuest41", mob = "Anubis",          title = "Alynn Greywood - Kill 3 Anubis",           target = 3,  world = "World5", minLv = 535},

    {questId = "NPCQuest42", mob = "Celestial Wisp", title = "Daver Karyb - Kill 15 Celestial Wisps",   target = 15, world = "World6", minLv = 550},
    {questId = "NPCQuest43", mob = "Prism Beetle",   title = "Daver Karyb - Kill 15 Prism Beetles",     target = 15, world = "World6", minLv = 560},
    {questId = "NPCQuest44", mob = "Tempest Ram",    title = "Daver Karyb - Kill 5 Tempest Rams",       target = 5,  world = "World6", minLv = 590},
    {questId = "NPCQuest45", mob = "Nebula Slime",   title = "Sir Frederic - Kill 15 Nebula Slimes",    target = 15, world = "World6", minLv = 630},
    {questId = "NPCQuest46", mob = "Astral Oracle",  title = "Sir Frederic - Kill 5 Astral Oracles",    target = 5,  world = "World6", minLv = 680},
    {questId = "NPCQuest47", mob = "Sunflare Harpy",  title = "Alynn Therafin - Kill 15 Sunflare Harpies", target = 15, world = "World6", minLv = 715},
    {questId = "NPCQuest48", mob = "Seraphim Titan", title = "Alynn Therafin - Kill 3 Seraphim Titans", target = 3,  world = "World6", minLv = 725},
}

-- ══════════════════════════════════════════════════
--  BUSCA DE INSTÂNCIA VIVA DO MOB NO WORKSPACE
-- ══════════════════════════════════════════════════
-- Se mobName for nil, aceita QUALQUER mob vivo (usado pelo Farm Masmora,
-- onde não dá pra saber os nomes dos mobs de antemão).
local function findMobInstance(mobName)
    local enemies = workspace:FindFirstChild("Enemies")
    if not enemies then return nil end

    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")

    local best, bestDist = nil, math.huge
    for _, obj in ipairs(enemies:GetChildren()) do
        if (mobName == nil or obj.Name == mobName) and obj:IsA("Model") then
            local hum   = obj:FindFirstChildOfClass("Humanoid")
            local objHrp = obj:FindFirstChild("HumanoidRootPart")
            if hum and objHrp and hum.Health > 0 then
                if hrp then
                    local d = (objHrp.Position - hrp.Position).Magnitude
                    if d < bestDist then
                        bestDist = d
                        best = obj
                    end
                elseif not best then
                    best = obj
                end
            end
        end
    end
    return best
end

-- ══════════════════════════════════════════════════
--  ESTADO DE POSIÇÃO (compartilhado entre o farm e
--  o auto-coletor). "target" é a posição normal (em
--  cima do mob); "override" tem prioridade e é usado
--  pelo coletor pra desviar o personagem até um item
--  dropado sem perder o alvo anterior.
-- ══════════════════════════════════════════════════
local posState = {
    target   = nil,
    override = nil,
}
local isCollecting = false

-- ══════════════════════════════════════════════════
--  LOOP DO FARM (TP + AUTO ATTACK + SKILLS)
-- ══════════════════════════════════════════════════
local farmToken       = 0
local farmActive      = false
local currentMob      = nil
local currentQuestTitle = nil -- setado quando o farm foi iniciado por uma quest

local questStatusUpdaters = {} -- callbacks pra atualizar textos da UI de quest

local function refreshQuestStatusUI()
    for _, fn in ipairs(questStatusUpdaters) do
        pcall(fn)
    end
end

local function stopFarm()
    farmActive = false
    farmToken  = farmToken + 1
    currentMob = nil
    currentQuestTitle = nil
    posState.target = nil
    if statusLabel then
        statusLabel.Text = "Farm parado"
    end
    refreshQuestStatusUI()
end

-- mobEntry.name == nil  -> farma QUALQUER mob vivo (usado pelo Farm Masmora)
-- mobEntry.world == nil -> não tenta trocar/checar mundo (usado dentro de
--                          masmoras, onde CurrentWorld não é um dos mundos normais)
local function startFarm(mobEntry, questTitle)
    farmToken = farmToken + 1
    local myToken = farmToken
    farmActive = true
    currentMob = mobEntry
    currentQuestTitle = questTitle
    refreshQuestStatusUI()

    local mobLabel = mobEntry.name or "mobs da masmora"

    if mobEntry.world then
        if statusLabel then
            statusLabel.Text = ("Verificando mundo (%s)..."):format(mobEntry.world)
        end

        -- Garante que estamos no mundo certo ANTES de tentar
        -- localizar/farmar o mob (senão o mob nem existe ainda
        -- no client, ou o servidor rejeita a posição).
        task.spawn(function()
            ensureWorld(mobEntry.world)
        end)
    end

    task.spawn(function()
        local worldWaited = 0
        while mobEntry.world and farmActive and farmToken == myToken and getCurrentWorld() ~= mobEntry.world and worldWaited < 8 do
            task.wait(0.25)
            worldWaited = worldWaited + 0.25
        end

        while farmActive and farmToken == myToken do
            local mob = findMobInstance(mobEntry.name)
            if mob then
                local mobHrp = mob:FindFirstChild("HumanoidRootPart")
                if mobHrp then
                    posState.target = mobHrp.Position + Vector3.new(0, cfg.hoverHeight, 0)
                    if statusLabel and not isCollecting then
                        local prefix = currentQuestTitle and ("[Quest] " .. currentQuestTitle .. " — ") or ""
                        statusLabel.Text = prefix .. ("Farmando: %s"):format(mob.Name)
                    end
                end
            else
                posState.target = nil
                if statusLabel and not isCollecting then
                    statusLabel.Text = ("Aguardando respawn: %s"):format(mobLabel)
                end
            end
            task.wait(0.2)
        end
    end)

    -- ── Loop de Bring Mob: agrupa TODOS os mobs (do nome alvo, ou
    --    QUALQUER mob se mobEntry.name for nil) num ponto ──
    task.spawn(function()
        while farmActive and farmToken == myToken do
            if cfg.bringMob then
                local enemies = workspace:FindFirstChild("Enemies")
                if enemies then
                    -- Encontra o primeiro mob vivo como ponto de encontro
                    local meetPoint = nil
                    for _, obj in ipairs(enemies:GetChildren()) do
                        if (mobEntry.name == nil or obj.Name == mobEntry.name) and obj:IsA("Model") then
                            local hum = obj:FindFirstChildOfClass("Humanoid")
                            local objHrp = obj:FindFirstChild("HumanoidRootPart")
                            if hum and objHrp and hum.Health > 0 then
                                meetPoint = objHrp.Position
                                break
                            end
                        end
                    end
                    
                    -- Agrupa todos os mobs nesse ponto
                    if meetPoint then
                        for _, obj in ipairs(enemies:GetChildren()) do
                            if (mobEntry.name == nil or obj.Name == mobEntry.name) and obj:IsA("Model") then
                                local hum = obj:FindFirstChildOfClass("Humanoid")
                                local objHrp = obj:FindFirstChild("HumanoidRootPart")
                                if hum and objHrp and hum.Health > 0 then
                                    pcall(function()
                                        objHrp.CFrame = CFrame.new(meetPoint)
                                        objHrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                                        objHrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
                                    end)
                                end
                            end
                        end
                    end
                end
            end
            task.wait(0.1)
        end
    end)

    -- ── Loop de Hitbox Expander: aumenta hitbox de TODOS os mobs
    --    (do nome alvo, ou QUALQUER mob se mobEntry.name for nil) ──
    task.spawn(function()
        while farmActive and farmToken == myToken do
            if cfg.hitboxSize and cfg.hitboxSize > 0 then
                local enemies = workspace:FindFirstChild("Enemies")
                if enemies then
                    for _, obj in ipairs(enemies:GetChildren()) do
                        if (mobEntry.name == nil or obj.Name == mobEntry.name) and obj:IsA("Model") then
                            local hum = obj:FindFirstChildOfClass("Humanoid")
                            local objHrp = obj:FindFirstChild("HumanoidRootPart")
                            if hum and objHrp and hum.Health > 0 then
                                pcall(function()
                                    objHrp.Size = Vector3.new(cfg.hitboxSize, cfg.hitboxSize, cfg.hitboxSize)
                                    objHrp.Transparency = 0.8
                                    objHrp.CanCollide = false
                                end)
                            end
                        end
                    end
                end
            end
            task.wait(0.25)
        end
    end)

    -- ── Mantém o player flutuando em cima do mob (ou do
    --    item, se o coletor estiver com prioridade ativa) ──
    local heartbeatConn
    heartbeatConn = RunService.Heartbeat:Connect(function()
        if not (farmActive and farmToken == myToken) then
            if heartbeatConn then heartbeatConn:Disconnect() end
            return
        end

        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local goal = posState.override or posState.target
        if hrp and goal then
            hrp.CFrame = CFrame.new(goal, goal + hrp.CFrame.LookVector)
            hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        end
    end)

    -- ── Loop de ataque automático (pausa durante a coleta) ──
    task.spawn(function()
        while farmActive and farmToken == myToken do
            if cfg.autoAttack and not isCollecting then
                safeAttack()
            end
            task.wait(0.15)
        end
    end)

    -- ── Loop de skills automáticas (pausa durante a coleta) ──
    task.spawn(function()
        while farmActive and farmToken == myToken do
            if cfg.autoSkills and not isCollecting then
                safeSkill(1)
                task.wait(0.12)
                safeSkill(2)
                task.wait(0.12)
                safeSkill(3)
                task.wait(0.12)
            else
                task.wait(0.3)
            end
        end
    end)
end

-- ══════════════════════════════════════════════════
--  QUEST MAIS ALTA (loop autônomo)
--  A cada poucos segundos verifica o level do jogador,
--  encontra a quest de maior level disponível baseado
--  no campo minLv de cada quest (level requerido para
--  aceitar a quest, extraído do NPCQuestDialog.mod.lua).
-- ══════════════════════════════════════════════════
local currentQuestMob = nil
local currentQuestId  = nil -- questId real (ex: "NPCQuest30") atualmente ativo

local function findBestQuest(playerLevel)
    local best = nil
    local bestMinLv = 0
    
    for _, q in ipairs(QUEST_LIST) do
        -- Verifica se o jogador tem level suficiente para esta quest
        local questMinLv = q.minLv or 1
        
        if playerLevel >= questMinLv then
            -- Se essa quest tem level requerido maior que a melhor até agora,
            -- ela se torna a nova "melhor quest" (mais desafiadora disponível)
            if questMinLv > bestMinLv then
                best = q
                bestMinLv = questMinLv
            end
        end
    end
    
    return best
end

-- Aceita a quest no servidor (se ainda não estiver ativa) e então
-- inicia o farm no mob correspondente. Essa é a peça que faltava:
-- sem aceitar, o servidor nunca conta as mortes pra essa quest.
local function startQuestFarm(quest)
    local mobEntry = findMobEntry(quest.mob)
    if not mobEntry then return end

    currentQuestMob = quest.mob
    currentQuestId  = quest.questId

    if quest.questId and NPCQuestAcceptEvent then
        acceptNPCQuest(quest.questId)
    end

    startFarm(mobEntry, quest.title)
end

local lastQuestAcceptCheck = 0

task.spawn(function()
    while true do
        task.wait(2)

        if not cfg.autoQuestHighest then
            continue
        end

        local lvl = getPlayerLevel()
        local best = findBestQuest(lvl)

        if best and best.mob ~= currentQuestMob then
            startQuestFarm(best)
        elseif best and best.questId then
            -- Já estamos no mob certo. Confirma periodicamente (a cada 10s)
            -- que a quest continua aceita no servidor, sem espamar o remote.
            local now = os.clock()
            if now - lastQuestAcceptCheck > 10 then
                lastQuestAcceptCheck = now
                if getActiveNPCQuestId() ~= best.questId then
                    acceptNPCQuest(best.questId)
                end
            end
        end
    end
end)

-- ══════════════════════════════════════════════════
--  AUTO COLETA DE ITENS
--  Fica de olho nos drops ativos do jogo
--  (Controllers.Render.LootDrop.Active). Quando acha
--  um item cuja raridade está marcada no painel, pausa
--  o que o personagem estava fazendo (posição + hits),
--  vai até o item, coleta, e devolve o controle pro
--  alvo anterior (mob) automaticamente.
-- ══════════════════════════════════════════════════
task.spawn(function()
    while true do
        task.wait(0.25)

        if not (cfg.autoCollect and Combat and not isCollecting) then
            continue
        end

        local ok, renderLootDrop = pcall(function()
            return Combat.Controllers.Render.LootDrop
        end)
        if not (ok and renderLootDrop and renderLootDrop.Active) then
            continue
        end

        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then continue end

        local foundPart, bestDist = nil, math.huge
        for dropPart, data in pairs(renderLootDrop.Active) do
            local rarity = data.itemInfo and data.itemInfo.rarity
            if rarity and cfg.collectRarities[rarity] then
                local pos = dropPart.Position
                local d = (pos - hrp.Position).Magnitude
                if d < bestDist then
                    bestDist = d
                    foundPart = dropPart
                end
            end
        end

        if foundPart then
            isCollecting = true
            if statusLabel then
                statusLabel.Text = "Coletando item dropado..."
            end

            posState.override = foundPart.Position

            local t0 = os.clock()
            while foundPart.Parent and (os.clock() - t0) < 3 do
                task.wait(0.1)
                local c2 = LocalPlayer.Character
                local hrp2 = c2 and c2:FindFirstChild("HumanoidRootPart")
                if hrp2 and (hrp2.Position - foundPart.Position).Magnitude < 6 then
                    break
                end
            end

            pcall(function()
                renderLootDrop:AttemptPickup(foundPart)
            end)

            task.wait(0.35)
            posState.override = nil
            isCollecting = false
        end
    end
end)

-- ══════════════════════════════════════════════════
--  PALETA · PRETO E BRANCO PURO (sem cores de acento)
-- ══════════════════════════════════════════════════
-- ── Paleta (adicionar cor de sidebar) ──
local C = {
    bg      = Color3.fromRGB(0, 0, 0),
    bg2     = Color3.fromRGB(16, 16, 16),
    bg3     = Color3.fromRGB(28, 28, 28),
    sidebar = Color3.fromRGB(12, 12, 12),
    tabActive = Color3.fromRGB(40, 40, 40),
    line    = Color3.fromRGB(60, 60, 60),
    text    = Color3.fromRGB(240, 240, 240),
    dim     = Color3.fromRGB(150, 150, 150),
    on      = Color3.fromRGB(240, 240, 240),
    off     = Color3.fromRGB(45, 45, 45),
    knobOn  = Color3.fromRGB(0, 0, 0),
    knobOff = Color3.fromRGB(200, 200, 200),
    white   = Color3.new(1, 1, 1),
}

-- ══════════════════════════════════════════════════
--  GUI · Painel System Farm (coluna única com scroll)
-- ══════════════════════════════════════════════════
local Gui = Instance.new("ScreenGui")
Gui.Name           = "PainelSystemFarm"
Gui.ResetOnSpawn   = false
Gui.IgnoreGuiInset = true
Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
Gui.Parent         = (typeof(gethui) == "function" and gethui())
                     or LocalPlayer:WaitForChild("PlayerGui")

local PANEL_W, PANEL_H = 700, 450
local SIDEBAR_W = 100

local Main = Instance.new("Frame", Gui)
Main.Name             = "Main"
Main.Size             = UDim2.fromOffset(PANEL_W, PANEL_H)
Main.Position         = UDim2.new(0.5, -PANEL_W/2, 0.5, -PANEL_H/2)
Main.BackgroundColor3 = C.bg
Main.BorderSizePixel  = 0
Main.Active           = true
Main.ClipsDescendants = false
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 8)
local ms = Instance.new("UIStroke", Main)
ms.Color = C.line
ms.Thickness = 1

-- ── Barra de título ──
local TBar = Instance.new("Frame", Main)
TBar.Size             = UDim2.new(1, 0, 0, 32)
TBar.BackgroundColor3 = C.bg2
TBar.BorderSizePixel  = 0
Instance.new("UICorner", TBar).CornerRadius = UDim.new(0, 8)
local TBarFix = Instance.new("Frame", TBar)
TBarFix.Size             = UDim2.new(1, 0, 0, 10)
TBarFix.Position         = UDim2.new(0, 0, 1, -10)
TBarFix.BackgroundColor3 = C.bg2
TBarFix.BorderSizePixel  = 0

local TTitle = Instance.new("TextLabel", TBar)
TTitle.Size               = UDim2.new(1, -110, 1, 0)
TTitle.Position           = UDim2.new(0, 14, 0, 0)
TTitle.BackgroundTransparency = 1
TTitle.TextColor3         = C.white
TTitle.TextSize           = 13
TTitle.Font               = Enum.Font.GothamBold
TTitle.Text               = "PAINEL SYSTEM FARM"
TTitle.TextXAlignment     = Enum.TextXAlignment.Left

local TClose = Instance.new("TextButton", TBar)
TClose.Size             = UDim2.fromOffset(22, 20)
TClose.Position         = UDim2.new(1, -28, 0.5, -10)
TClose.BackgroundColor3 = C.bg3
TClose.Text             = "X"
TClose.TextColor3       = C.white
TClose.TextSize         = 11
TClose.Font             = Enum.Font.GothamBold
TClose.BorderSizePixel  = 0
Instance.new("UICorner", TClose).CornerRadius = UDim.new(0, 4)
TClose.MouseButton1Click:Connect(function()
    Main.Visible = false
end)

local TMinimize = Instance.new("TextButton", TBar)
TMinimize.Size             = UDim2.fromOffset(22, 20)
TMinimize.Position         = UDim2.new(1, -54, 0.5, -10)
TMinimize.BackgroundColor3 = C.bg3
TMinimize.Text             = "_"
TMinimize.TextColor3       = C.white
TMinimize.TextSize         = 13
TMinimize.Font             = Enum.Font.GothamBold
TMinimize.BorderSizePixel  = 0
Instance.new("UICorner", TMinimize).CornerRadius = UDim.new(0, 4)

-- ── Sistema de Minimizar: esconde tudo exceto a TBar e reduz o painel
--    a apenas a altura da barra de título ──
local isMinimized = false
local expandedHeight = PANEL_H
local function setMinimized(minimized)
    isMinimized = minimized
    TMinimize.Text = minimized and "□" or "_"

    if minimized then
        Main.Size = UDim2.fromOffset(PANEL_W, 32)
    else
        Main.Size = UDim2.fromOffset(PANEL_W, expandedHeight)
    end

    -- SBar, Sidebar e conteúdo das tabs ficam ocultos quando minimizado.
    -- Os overlays (MobOverlay, QuestOverlay, etc.) são ignorados aqui pra
    -- não forçar eles a abrir de novo quando o painel é restaurado.
    for _, child in ipairs(Main:GetChildren()) do
        if child ~= TBar and child:IsA("GuiObject") and not string.find(child.Name, "Overlay") then
            child.Visible = not minimized
        elseif minimized and child:IsA("GuiObject") and string.find(child.Name, "Overlay") then
            -- Fecha overlays abertos ao minimizar (evita ficarem "flutuando")
            child.Visible = false
        end
    end
end

TMinimize.MouseButton1Click:Connect(function()
    setMinimized(not isMinimized)
end)

-- ── Drag manual pela barra de título (evita bug de "descolamento"
--    visual que a propriedade Frame.Draggable causa em alguns
--    executors quando o frame tem ScrollingFrames/children complexos) ──
do
    local UserInputService = game:GetService("UserInputService")
    local dragging = false
    local dragStart = nil
    local startPos = nil

    local function updateDrag(input)
        local delta = input.Position - dragStart
        Main.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end

    TBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = Main.Position

            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            updateDrag(input)
        end
    end)
end

-- ── Barra de status ──
local SBar = Instance.new("Frame", Main)
SBar.Size             = UDim2.new(1, 0, 0, 20)
SBar.Position         = UDim2.new(0, 0, 0, 32)
SBar.BackgroundColor3 = C.bg2
SBar.BorderSizePixel  = 0

statusLabel = Instance.new("TextLabel", SBar)
statusLabel.Size               = UDim2.new(1, -16, 1, 0)
statusLabel.Position           = UDim2.new(0, 8, 0, 0)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3         = C.dim
statusLabel.TextSize           = 10
statusLabel.Font               = Enum.Font.Gotham
statusLabel.Text               = "Nenhum mob selecionado"
statusLabel.TextXAlignment     = Enum.TextXAlignment.Left
statusLabel.TextTruncate       = Enum.TextTruncate.AtEnd

-- ── Sidebar com Tabs (Farm / Forja / Player / Misc) ──
local Sidebar = Instance.new("Frame", Main)
Sidebar.Name             = "Sidebar"
Sidebar.Size             = UDim2.new(0, SIDEBAR_W, 1, -52)
Sidebar.Position         = UDim2.new(0, 0, 0, 52)
Sidebar.BackgroundColor3 = C.sidebar
Sidebar.BorderSizePixel  = 0
Instance.new("UICorner", Sidebar).CornerRadius = UDim.new(0, 8)
local SidebarFix = Instance.new("Frame", Sidebar)
SidebarFix.Size             = UDim2.new(0, 10, 1, 0)
SidebarFix.Position         = UDim2.new(1, -10, 0, 0)
SidebarFix.BackgroundColor3 = C.sidebar
SidebarFix.BorderSizePixel  = 0

local SidebarLayout = Instance.new("UIListLayout", Sidebar)
SidebarLayout.SortOrder           = Enum.SortOrder.LayoutOrder
SidebarLayout.Padding             = UDim.new(0, 4)
SidebarLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

local SidebarPad = Instance.new("UIPadding", Sidebar)
SidebarPad.PaddingTop = UDim.new(0, 8)

local tabs = {"Farm", "Forja", "Player", "Misc"}
local currentTab = "Farm"
local tabButtons = {}
local tabContents = {}

local function makeTabButton(tabName, order)
    local btn = Instance.new("TextButton", Sidebar)
    btn.Name             = "Tab_" .. tabName
    btn.Size             = UDim2.new(1, -12, 0, 40)
    btn.LayoutOrder      = order
    btn.BackgroundColor3 = C.tabActive
    btn.BackgroundTransparency = (currentTab == tabName) and 0 or 1
    btn.Text             = ""
    btn.AutoButtonColor  = false
    btn.BorderSizePixel  = 0
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

    local lbl = Instance.new("TextLabel", btn)
    lbl.Size               = UDim2.new(1, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3         = C.text
    lbl.TextSize           = 12
    lbl.Font               = Enum.Font.GothamBold
    lbl.Text               = tabName:upper()
    lbl.TextXAlignment     = Enum.TextXAlignment.Center

    tabButtons[tabName] = btn
    return btn
end

local function makeTabContent(tabName)
    local content = Instance.new("ScrollingFrame", Main)
    content.Name                    = "Content_" .. tabName
    content.Size                    = UDim2.new(1, -(SIDEBAR_W + 12), 1, -60)
    content.Position                = UDim2.new(0, SIDEBAR_W + 6, 0, 56)
    content.BackgroundTransparency  = 1
    content.BorderSizePixel         = 0
    content.ScrollBarThickness      = 6
    content.ScrollBarImageColor3    = C.dim
    content.AutomaticCanvasSize     = Enum.AutomaticSize.Y
    content.CanvasSize              = UDim2.new()
    content.Visible                 = (tabName == currentTab)

    local pad = Instance.new("UIPadding", content)
    pad.PaddingLeft   = UDim.new(0, 4)
    pad.PaddingRight  = UDim.new(0, 8)
    pad.PaddingTop    = UDim.new(0, 4)
    pad.PaddingBottom = UDim.new(0, 8)

    local layout = Instance.new("UIListLayout", content)
    layout.SortOrder          = Enum.SortOrder.LayoutOrder
    layout.Padding            = UDim.new(0, 8)
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center

    tabContents[tabName] = content
    return content
end

local function switchTab(tabName)
    currentTab = tabName
    for name, btn in pairs(tabButtons) do
        btn.BackgroundTransparency = (name == tabName) and 0 or 1
    end
    for name, content in pairs(tabContents) do
        content.Visible = (name == tabName)
    end
end

for i, tabName in ipairs(tabs) do
    local btn = makeTabButton(tabName, i)
    btn.MouseButton1Click:Connect(function()
        switchTab(tabName)
    end)
end

for _, tabName in ipairs(tabs) do
    makeTabContent(tabName)
end

-- Body = conteúdo da tab Farm (mantém compatibilidade com código existente)
local Body = tabContents["Farm"]

-- Helper: um "card" com título pequeno + conteúdo + BORDA BRANCA
-- parentOverride: se omitido, usa Body (tab Farm) por padrão
local cardOrder = 0
local function makeCard(height, title, withBorder, parentOverride)
    cardOrder = cardOrder + 1
    local card = Instance.new("Frame", parentOverride or Body)
    card.Size             = UDim2.new(1, 0, 0, height)
    card.BackgroundColor3 = C.bg2
    card.BorderSizePixel  = 0
    card.LayoutOrder      = cardOrder
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 6)
    
    -- Adiciona borda branca se solicitado
    if withBorder then
        local stroke = Instance.new("UIStroke", card)
        stroke.Color = C.white
        stroke.Thickness = 1
        stroke.Transparency = 0.85
    end

    if title then
        local lbl = Instance.new("TextLabel", card)
        lbl.Size               = UDim2.new(1, -16, 0, 14)
        lbl.Position           = UDim2.new(0, 8, 0, 4)
        lbl.BackgroundTransparency = 1
        lbl.TextColor3         = withBorder and C.white or C.dim
        lbl.TextSize           = withBorder and 11 or 9
        lbl.Font               = Enum.Font.GothamBold
        lbl.Text               = title:upper()
        lbl.TextXAlignment     = Enum.TextXAlignment.Left
    end

    return card
end

-- ══════════════════════════════════════════════════
--  SELETOR DE MOB (com borda)
-- ══════════════════════════════════════════════════
local MobCard = makeCard(40, "Mob", true)

local Selector = Instance.new("TextButton", MobCard)
Selector.Size             = UDim2.new(1, -16, 0, 20)
Selector.Position         = UDim2.new(0, 8, 0, 20)
Selector.BackgroundColor3 = C.bg3
Selector.Text             = ""
Selector.AutoButtonColor  = false
Selector.BorderSizePixel  = 0
Instance.new("UICorner", Selector).CornerRadius = UDim.new(0, 4)

local SelectorText = Instance.new("TextLabel", Selector)
SelectorText.Size               = UDim2.new(1, -26, 1, 0)
SelectorText.Position           = UDim2.new(0, 8, 0, 0)
SelectorText.BackgroundTransparency = 1
SelectorText.TextColor3         = C.dim
SelectorText.TextSize           = 11
SelectorText.Font               = Enum.Font.GothamBold
SelectorText.Text               = "Selecionar mob..."
SelectorText.TextXAlignment     = Enum.TextXAlignment.Left
SelectorText.TextTruncate       = Enum.TextTruncate.AtEnd

local SelectorArrow = Instance.new("TextLabel", Selector)
SelectorArrow.Size               = UDim2.new(0, 18, 1, 0)
SelectorArrow.Position           = UDim2.new(1, -20, 0, 0)
SelectorArrow.BackgroundTransparency = 1
SelectorArrow.TextColor3         = C.dim
SelectorArrow.TextSize           = 10
SelectorArrow.Font               = Enum.Font.GothamBold
SelectorArrow.Text               = "v"
SelectorArrow.TextXAlignment     = Enum.TextXAlignment.Center

-- Overlay (lista de mobs) — abre por cima do painel, centralizado
-- (bloco do...end para liberar registradores locais do compilador)
do
local MobOverlay = Instance.new("Frame", Main)
MobOverlay.Name             = "MobOverlay"
MobOverlay.Size             = UDim2.new(0, 280, 0, 280)
MobOverlay.Position         = UDim2.new(0.5, -140, 0.5, -140)
MobOverlay.BackgroundColor3 = C.bg2
MobOverlay.BorderSizePixel  = 0
MobOverlay.Visible          = false
MobOverlay.ZIndex           = 30
Instance.new("UICorner", MobOverlay).CornerRadius = UDim.new(0, 6)
local mobOvStroke = Instance.new("UIStroke", MobOverlay)
mobOvStroke.Color = C.line
mobOvStroke.Thickness = 1

local MobOverlayClose = Instance.new("TextButton", MobOverlay)
MobOverlayClose.Size             = UDim2.fromOffset(20, 20)
MobOverlayClose.Position         = UDim2.new(1, -26, 0, 6)
MobOverlayClose.BackgroundColor3 = C.bg3
MobOverlayClose.Text             = "X"
MobOverlayClose.TextColor3       = C.white
MobOverlayClose.TextSize         = 10
MobOverlayClose.Font             = Enum.Font.GothamBold
MobOverlayClose.BorderSizePixel  = 0
MobOverlayClose.ZIndex           = 31
Instance.new("UICorner", MobOverlayClose).CornerRadius = UDim.new(0, 4)

local MobListFrame = Instance.new("ScrollingFrame", MobOverlay)
MobListFrame.Size                 = UDim2.new(1, -12, 1, -36)
MobListFrame.Position             = UDim2.new(0, 6, 0, 30)
MobListFrame.BackgroundTransparency = 1
MobListFrame.BorderSizePixel      = 0
MobListFrame.ScrollBarThickness   = 4
MobListFrame.ScrollBarImageColor3 = C.dim
MobListFrame.AutomaticCanvasSize  = Enum.AutomaticSize.Y
MobListFrame.CanvasSize           = UDim2.new()
MobListFrame.ZIndex               = 31

local MobListLayout = Instance.new("UIListLayout", MobListFrame)
MobListLayout.SortOrder = Enum.SortOrder.LayoutOrder
MobListLayout.Padding   = UDim.new(0, 2)

local MobListPad = Instance.new("UIPadding", MobListFrame)
MobListPad.PaddingLeft   = UDim.new(0, 4)
MobListPad.PaddingRight  = UDim.new(0, 4)
MobListPad.PaddingTop    = UDim.new(0, 4)
MobListPad.PaddingBottom = UDim.new(0, 4)

local mobOverlayOpen = false
local function setMobOverlayOpen(open)
    mobOverlayOpen = open
    MobOverlay.Visible = open
    SelectorArrow.Text = open and "^" or "v"
end

Selector.MouseButton1Click:Connect(function()
    setMobOverlayOpen(not mobOverlayOpen)
end)
MobOverlayClose.MouseButton1Click:Connect(function()
    setMobOverlayOpen(false)
end)

local function selectMobManually(mobEntry, displaySuffix)
    cfg.autoQuestHighest = false
    currentQuestMob = nil
    SelectorText.Text = mobEntry.name .. (displaySuffix or "")
    SelectorText.TextColor3 = C.text
    setMobOverlayOpen(false)
    startFarm(mobEntry, nil)
end

local currentWorldHeader = nil
local mobOrder = 0

local function addWorldHeader(worldName)
    mobOrder = mobOrder + 1
    local lbl = Instance.new("TextLabel", MobListFrame)
    lbl.Size               = UDim2.new(1, 0, 0, 20)
    lbl.LayoutOrder         = mobOrder
    lbl.BackgroundTransparency = 1
    lbl.TextColor3         = C.dim
    lbl.TextSize           = 11
    lbl.Font               = Enum.Font.GothamBold
    lbl.Text               = "-- " .. worldName .. " --"
    lbl.TextXAlignment     = Enum.TextXAlignment.Left
    lbl.ZIndex              = 31
end

for _, mob in ipairs(MOB_LIST) do
    if mob.world ~= currentWorldHeader then
        currentWorldHeader = mob.world
        addWorldHeader(mob.world)
    end

    mobOrder = mobOrder + 1

    local row = Instance.new("TextButton", MobListFrame)
    row.Size             = UDim2.new(1, 0, 0, 28)
    row.LayoutOrder       = mobOrder
    row.BackgroundColor3 = C.bg3
    row.Text             = ""
    row.BorderSizePixel  = 0
    row.AutoButtonColor  = false
    row.ZIndex            = 31
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 4)

    local tagStr = mob.tag and (" [" .. mob.tag .. "]") or ""
    local nameLbl = Instance.new("TextLabel", row)
    nameLbl.Size               = UDim2.new(0.55, 0, 1, 0)
    nameLbl.Position           = UDim2.new(0, 8, 0, 0)
    nameLbl.BackgroundTransparency = 1
    nameLbl.TextColor3         = C.text
    nameLbl.TextSize           = 12
    nameLbl.Font               = Enum.Font.Gotham
    nameLbl.Text               = mob.name .. tagStr
    nameLbl.TextXAlignment     = Enum.TextXAlignment.Left
    nameLbl.TextTruncate       = Enum.TextTruncate.AtEnd
    nameLbl.ZIndex              = 32

    local lvLbl = Instance.new("TextLabel", row)
    lvLbl.Size               = UDim2.new(0.22, 0, 1, 0)
    lvLbl.Position           = UDim2.new(0.55, 0, 0, 0)
    lvLbl.BackgroundTransparency = 1
    lvLbl.TextColor3         = C.dim
    lvLbl.TextSize           = 11
    lvLbl.Font               = Enum.Font.Gotham
    lvLbl.Text               = "Lv " .. mob.lv
    lvLbl.TextXAlignment     = Enum.TextXAlignment.Left
    lvLbl.ZIndex              = 32

    local minLvLbl = Instance.new("TextLabel", row)
    minLvLbl.Size               = UDim2.new(0.23, 0, 1, 0)
    minLvLbl.Position           = UDim2.new(0.77, 0, 0, 0)
    minLvLbl.BackgroundTransparency = 1
    minLvLbl.TextColor3         = C.dim
    minLvLbl.TextSize           = 11
    minLvLbl.Font               = Enum.Font.Gotham
    minLvLbl.Text               = "Min " .. mob.minLv
    minLvLbl.TextXAlignment     = Enum.TextXAlignment.Right
    minLvLbl.ZIndex              = 32

    row.MouseButton1Click:Connect(function()
        selectMobManually(mob, tagStr)
    end)
end
end -- fim do bloco MobOverlay

-- ══════════════════════════════════════════════════
--  AUTO QUEST (seletor manual de quest) (com borda)
-- ══════════════════════════════════════════════════
local QuestCard = makeCard(40, "Auto Quest", true)

local QuestSelector = Instance.new("TextButton", QuestCard)
QuestSelector.Size             = UDim2.new(1, -16, 0, 20)
QuestSelector.Position         = UDim2.new(0, 8, 0, 16)
QuestSelector.BackgroundColor3 = C.bg3
QuestSelector.Text             = ""
QuestSelector.AutoButtonColor  = false
QuestSelector.BorderSizePixel  = 0
Instance.new("UICorner", QuestSelector).CornerRadius = UDim.new(0, 4)

local QuestSelectorText = Instance.new("TextLabel", QuestSelector)
QuestSelectorText.Size               = UDim2.new(1, -26, 1, 0)
QuestSelectorText.Position           = UDim2.new(0, 8, 0, 0)
QuestSelectorText.BackgroundTransparency = 1
QuestSelectorText.TextColor3         = C.dim
QuestSelectorText.TextSize           = 11
QuestSelectorText.Font               = Enum.Font.GothamBold
QuestSelectorText.Text               = "Selecionar quest..."
QuestSelectorText.TextXAlignment     = Enum.TextXAlignment.Left
QuestSelectorText.TextTruncate       = Enum.TextTruncate.AtEnd

local QuestSelectorArrow = Instance.new("TextLabel", QuestSelector)
QuestSelectorArrow.Size               = UDim2.new(0, 18, 1, 0)
QuestSelectorArrow.Position           = UDim2.new(1, -20, 0, 0)
QuestSelectorArrow.BackgroundTransparency = 1
QuestSelectorArrow.TextColor3         = C.dim
QuestSelectorArrow.TextSize           = 10
QuestSelectorArrow.Font               = Enum.Font.GothamBold
QuestSelectorArrow.Text               = "v"
QuestSelectorArrow.TextXAlignment     = Enum.TextXAlignment.Center

do
local QuestOverlay = Instance.new("Frame", Main)
QuestOverlay.Name             = "QuestOverlay"
QuestOverlay.Size             = UDim2.new(0, 320, 0, 280)
QuestOverlay.Position         = UDim2.new(0.5, -160, 0.5, -140)
QuestOverlay.BackgroundColor3 = C.bg2
QuestOverlay.BorderSizePixel  = 0
QuestOverlay.Visible          = false
QuestOverlay.ZIndex           = 30
Instance.new("UICorner", QuestOverlay).CornerRadius = UDim.new(0, 6)
local questOvStroke = Instance.new("UIStroke", QuestOverlay)
questOvStroke.Color = C.line
questOvStroke.Thickness = 1

local QuestOverlayClose = Instance.new("TextButton", QuestOverlay)
QuestOverlayClose.Size             = UDim2.fromOffset(20, 20)
QuestOverlayClose.Position         = UDim2.new(1, -26, 0, 6)
QuestOverlayClose.BackgroundColor3 = C.bg3
QuestOverlayClose.Text             = "X"
QuestOverlayClose.TextColor3       = C.white
QuestOverlayClose.TextSize         = 10
QuestOverlayClose.Font             = Enum.Font.GothamBold
QuestOverlayClose.BorderSizePixel  = 0
QuestOverlayClose.ZIndex           = 31
Instance.new("UICorner", QuestOverlayClose).CornerRadius = UDim.new(0, 4)

local QuestListFrame = Instance.new("ScrollingFrame", QuestOverlay)
QuestListFrame.Size                 = UDim2.new(1, -12, 1, -36)
QuestListFrame.Position             = UDim2.new(0, 6, 0, 30)
QuestListFrame.BackgroundTransparency = 1
QuestListFrame.BorderSizePixel      = 0
QuestListFrame.ScrollBarThickness   = 4
QuestListFrame.ScrollBarImageColor3 = C.dim
QuestListFrame.AutomaticCanvasSize  = Enum.AutomaticSize.Y
QuestListFrame.CanvasSize           = UDim2.new()
QuestListFrame.ZIndex               = 31

local QuestListLayout = Instance.new("UIListLayout", QuestListFrame)
QuestListLayout.SortOrder = Enum.SortOrder.LayoutOrder
QuestListLayout.Padding   = UDim.new(0, 2)

local QuestListPad = Instance.new("UIPadding", QuestListFrame)
QuestListPad.PaddingLeft   = UDim.new(0, 4)
QuestListPad.PaddingRight  = UDim.new(0, 4)
QuestListPad.PaddingTop    = UDim.new(0, 4)
QuestListPad.PaddingBottom = UDim.new(0, 4)

local questOverlayOpen = false
local function setQuestOverlayOpen(open)
    questOverlayOpen = open
    QuestOverlay.Visible = open
    QuestSelectorArrow.Text = open and "^" or "v"
end

QuestSelector.MouseButton1Click:Connect(function()
    setQuestOverlayOpen(not questOverlayOpen)
end)
QuestOverlayClose.MouseButton1Click:Connect(function()
    setQuestOverlayOpen(false)
end)

local currentQuestWorldHeader = nil
local questOrder = 0

local function addQuestWorldHeader(worldName)
    questOrder = questOrder + 1
    local lbl = Instance.new("TextLabel", QuestListFrame)
    lbl.Size               = UDim2.new(1, 0, 0, 20)
    lbl.LayoutOrder         = questOrder
    lbl.BackgroundTransparency = 1
    lbl.TextColor3         = C.dim
    lbl.TextSize           = 11
    lbl.Font               = Enum.Font.GothamBold
    lbl.Text               = ("-- %s (Min Lv %d) --"):format(worldName, WORLD_MIN_LV[worldName] or 1)
    lbl.TextXAlignment     = Enum.TextXAlignment.Left
    lbl.ZIndex              = 31
end

for _, quest in ipairs(QUEST_LIST) do
    if quest.world ~= currentQuestWorldHeader then
        currentQuestWorldHeader = quest.world
        addQuestWorldHeader(quest.world)
    end

    questOrder = questOrder + 1

    local row = Instance.new("TextButton", QuestListFrame)
    row.Size             = UDim2.new(1, 0, 0, 30)
    row.LayoutOrder       = questOrder
    row.BackgroundColor3 = C.bg3
    row.Text             = ""
    row.BorderSizePixel  = 0
    row.AutoButtonColor  = false
    row.ZIndex            = 31
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 4)

    local titleLbl = Instance.new("TextLabel", row)
    titleLbl.Size               = UDim2.new(1, -16, 0, 15)
    titleLbl.Position           = UDim2.new(0, 8, 0, 2)
    titleLbl.BackgroundTransparency = 1
    titleLbl.TextColor3         = C.text
    titleLbl.TextSize           = 11
    titleLbl.Font               = Enum.Font.Gotham
    titleLbl.Text               = quest.title
    titleLbl.TextXAlignment     = Enum.TextXAlignment.Left
    titleLbl.TextTruncate       = Enum.TextTruncate.AtEnd
    titleLbl.ZIndex              = 32

    local subLbl = Instance.new("TextLabel", row)
    subLbl.Size               = UDim2.new(1, -16, 0, 12)
    subLbl.Position           = UDim2.new(0, 8, 0, 16)
    subLbl.BackgroundTransparency = 1
    subLbl.TextColor3         = C.dim
    subLbl.TextSize           = 9
    subLbl.Font               = Enum.Font.Gotham
    subLbl.Text               = ("Mob: %s  |  Meta: %d  |  Min Lv %d"):format(quest.mob, quest.target, WORLD_MIN_LV[quest.world] or 1)
    subLbl.TextXAlignment     = Enum.TextXAlignment.Left
    subLbl.ZIndex              = 32

    row.MouseButton1Click:Connect(function()
        local mobEntry = findMobEntry(quest.mob)
        if not mobEntry then return end

        cfg.autoQuestHighest = false
        QuestSelectorText.Text = quest.title
        QuestSelectorText.TextColor3 = C.text
        SelectorText.Text = mobEntry.name
        SelectorText.TextColor3 = C.text
        setQuestOverlayOpen(false)
        startQuestFarm(quest)
    end)
end
end -- fim do bloco QuestOverlay

-- ══════════════════════════════════════════════════
--  ALTURA DO TP
-- ══════════════════════════════════════════════════
do
local HeightCard = makeCard(40, "Altura do TP")

local MIN_H, MAX_H, STEP_H = 2, 40, 2

local heightMinus = Instance.new("TextButton", HeightCard)
heightMinus.Size             = UDim2.fromOffset(24, 20)
heightMinus.Position         = UDim2.new(0, 8, 0, 16)
heightMinus.BackgroundColor3 = C.off
heightMinus.Text             = "-"
heightMinus.TextColor3       = C.white
heightMinus.TextSize         = 15
heightMinus.Font             = Enum.Font.GothamBold
heightMinus.BorderSizePixel  = 0
Instance.new("UICorner", heightMinus).CornerRadius = UDim.new(0, 4)

local heightVal = Instance.new("TextLabel", HeightCard)
heightVal.Size               = UDim2.new(1, -72, 0, 20)
heightVal.Position           = UDim2.new(0, 36, 0, 16)
heightVal.BackgroundTransparency = 1
heightVal.TextColor3         = C.white
heightVal.TextSize           = 12
heightVal.Font               = Enum.Font.GothamBold
heightVal.Text               = tostring(cfg.hoverHeight)
heightVal.TextXAlignment     = Enum.TextXAlignment.Center

local heightPlus = Instance.new("TextButton", HeightCard)
heightPlus.Size             = UDim2.fromOffset(24, 20)
heightPlus.Position         = UDim2.new(1, -32, 0, 16)
heightPlus.BackgroundColor3 = C.off
heightPlus.Text             = "+"
heightPlus.TextColor3       = C.white
heightPlus.TextSize         = 15
heightPlus.Font             = Enum.Font.GothamBold
heightPlus.BorderSizePixel  = 0
Instance.new("UICorner", heightPlus).CornerRadius = UDim.new(0, 4)

heightMinus.MouseButton1Click:Connect(function()
    cfg.hoverHeight = math.max(MIN_H, cfg.hoverHeight - STEP_H)
    heightVal.Text = tostring(cfg.hoverHeight)
end)
heightPlus.MouseButton1Click:Connect(function()
    cfg.hoverHeight = math.min(MAX_H, cfg.hoverHeight + STEP_H)
    heightVal.Text = tostring(cfg.hoverHeight)
end)
end -- fim do bloco Altura TP

-- ══════════════════════════════════════════════════
--  HITBOX SIZE (ajusta máximo baseado no mob ou manual)
-- ══════════════════════════════════════════════════
do
local HitboxCard = makeCard(70, "Hitbox Size", true, tabContents["Player"])

local MIN_HITBOX, MAX_HITBOX, STEP_HITBOX = 5, 25, 5

-- Toggle Hitbox Auto
local autoHitboxLbl = Instance.new("TextLabel", HitboxCard)
autoHitboxLbl.Size               = UDim2.new(1, -60, 0, 12)
autoHitboxLbl.Position           = UDim2.new(0, 8, 0, 16)
autoHitboxLbl.BackgroundTransparency = 1
autoHitboxLbl.TextColor3         = C.text
autoHitboxLbl.TextSize           = 10
autoHitboxLbl.Font               = Enum.Font.Gotham
autoHitboxLbl.Text               = "Hitbox Automática"
autoHitboxLbl.TextXAlignment     = Enum.TextXAlignment.Left

local autoHitboxPill = Instance.new("Frame", HitboxCard)
autoHitboxPill.Size             = UDim2.fromOffset(36, 18)
autoHitboxPill.Position         = UDim2.new(1, -44, 0, 15)
autoHitboxPill.BackgroundColor3 = cfg.hitboxAuto and C.on or C.off
autoHitboxPill.BorderSizePixel  = 0
Instance.new("UICorner", autoHitboxPill).CornerRadius = UDim.new(1, 0)

local autoHitboxKnob = Instance.new("Frame", autoHitboxPill)
autoHitboxKnob.Size             = UDim2.fromOffset(12, 12)
autoHitboxKnob.Position         = cfg.hitboxAuto and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
autoHitboxKnob.BackgroundColor3 = cfg.hitboxAuto and C.knobOn or C.knobOff
autoHitboxKnob.BorderSizePixel  = 0
Instance.new("UICorner", autoHitboxKnob).CornerRadius = UDim.new(1, 0)

local autoHitboxHit = Instance.new("TextButton", autoHitboxPill)
autoHitboxHit.Size               = UDim2.new(1, 0, 1, 0)
autoHitboxHit.BackgroundTransparency = 1
autoHitboxHit.Text               = ""
autoHitboxHit.BorderSizePixel    = 0

-- Controles de tamanho
local hitboxMinus = Instance.new("TextButton", HitboxCard)
hitboxMinus.Size             = UDim2.fromOffset(24, 20)
hitboxMinus.Position         = UDim2.new(0, 8, 0, 42)
hitboxMinus.BackgroundColor3 = C.off
hitboxMinus.Text             = "-"
hitboxMinus.TextColor3       = C.white
hitboxMinus.TextSize         = 15
hitboxMinus.Font             = Enum.Font.GothamBold
hitboxMinus.BorderSizePixel  = 0
Instance.new("UICorner", hitboxMinus).CornerRadius = UDim.new(0, 4)

local hitboxVal = Instance.new("TextLabel", HitboxCard)
hitboxVal.Size               = UDim2.new(1, -72, 0, 20)
hitboxVal.Position           = UDim2.new(0, 36, 0, 42)
hitboxVal.BackgroundTransparency = 1
hitboxVal.TextColor3         = C.white
hitboxVal.TextSize           = 12
hitboxVal.Font               = Enum.Font.GothamBold
hitboxVal.Text               = tostring(cfg.hitboxSize)
hitboxVal.TextXAlignment     = Enum.TextXAlignment.Center

local hitboxPlus = Instance.new("TextButton", HitboxCard)
hitboxPlus.Size             = UDim2.fromOffset(24, 20)
hitboxPlus.Position         = UDim2.new(1, -32, 0, 42)
hitboxPlus.BackgroundColor3 = C.off
hitboxPlus.Text             = "+"
hitboxPlus.TextColor3       = C.white
hitboxPlus.TextSize         = 15
hitboxPlus.Font             = Enum.Font.GothamBold
hitboxPlus.BorderSizePixel  = 0
Instance.new("UICorner", hitboxPlus).CornerRadius = UDim.new(0, 4)

-- Função para atualizar o máximo da hitbox baseado no mob atual
local function updateHitboxMax()
    if cfg.hitboxAuto then
        if currentMob and currentMob.maxHitbox then
            MAX_HITBOX = currentMob.maxHitbox
            -- Se o valor atual é maior que o novo máximo, ajusta
            if cfg.hitboxSize > MAX_HITBOX then
                cfg.hitboxSize = MAX_HITBOX
                hitboxVal.Text = tostring(cfg.hitboxSize)
            end
        else
            MAX_HITBOX = 25 -- padrão
        end
    else
        MAX_HITBOX = 50 -- modo manual: até 50
    end
end

autoHitboxHit.MouseButton1Click:Connect(function()
    cfg.hitboxAuto = not cfg.hitboxAuto
    autoHitboxPill.BackgroundColor3 = cfg.hitboxAuto and C.on or C.off
    autoHitboxKnob.Position         = cfg.hitboxAuto and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
    autoHitboxKnob.BackgroundColor3 = cfg.hitboxAuto and C.knobOn or C.knobOff
    updateHitboxMax()
    -- Atualiza o display para mostrar novo máximo
    hitboxVal.Text = tostring(cfg.hitboxSize)
end)

hitboxMinus.MouseButton1Click:Connect(function()
    cfg.hitboxSize = math.max(MIN_HITBOX, cfg.hitboxSize - STEP_HITBOX)
    hitboxVal.Text = tostring(cfg.hitboxSize)
end)
hitboxPlus.MouseButton1Click:Connect(function()
    updateHitboxMax()
    cfg.hitboxSize = math.min(MAX_HITBOX, cfg.hitboxSize + STEP_HITBOX)
    hitboxVal.Text = tostring(cfg.hitboxSize)
end)
end -- fim do bloco Hitbox Size

-- ══════════════════════════════════════════════════
--  BRING MOB
-- ══════════════════════════════════════════════════
do
local BringMobCard = makeCard(36, "Bring Mob", true)

local function makeBringMobToggle(parent, label, key)
    local lbl = Instance.new("TextLabel", parent)
    lbl.Size               = UDim2.new(1, -60, 0, 12)
    lbl.Position           = UDim2.new(0, 8, 0, 16)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3         = C.text
    lbl.TextSize           = 10
    lbl.Font               = Enum.Font.Gotham
    lbl.Text               = label
    lbl.TextXAlignment     = Enum.TextXAlignment.Left

    local pill = Instance.new("Frame", parent)
    pill.Size             = UDim2.fromOffset(36, 18)
    pill.Position         = UDim2.new(1, -44, 0, 15)
    pill.BackgroundColor3 = cfg[key] and C.on or C.off
    pill.BorderSizePixel  = 0
    Instance.new("UICorner", pill).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame", pill)
    knob.Size             = UDim2.fromOffset(12, 12)
    knob.Position         = cfg[key] and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
    knob.BackgroundColor3 = cfg[key] and C.knobOn or C.knobOff
    knob.BorderSizePixel  = 0
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local hit = Instance.new("TextButton", pill)
    hit.Size               = UDim2.new(1, 0, 1, 0)
    hit.BackgroundTransparency = 1
    hit.Text               = ""
    hit.BorderSizePixel    = 0
    hit.MouseButton1Click:Connect(function()
        cfg[key] = not cfg[key]
        pill.BackgroundColor3 = cfg[key] and C.on or C.off
        knob.Position         = cfg[key] and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
        knob.BackgroundColor3 = cfg[key] and C.knobOn or C.knobOff
    end)

    return pill, knob
end

makeBringMobToggle(BringMobCard, "Agrupar mobs da quest", "bringMob")
end -- fim do bloco Bring Mob

-- ══════════════════════════════════════════════════
--  AUTOMAÇÃO (toggles em grid vertical) (com borda)
-- ══════════════════════════════════════════════════
do
local TogglesCard = makeCard(155, "Automação", true)

local function makeToggleSlot(parent, y, label, key, onToggled)
    local lbl = Instance.new("TextLabel", parent)
    lbl.Size               = UDim2.new(1, -60, 0, 12)
    lbl.Position           = UDim2.new(0, 8, 0, y)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3         = C.text
    lbl.TextSize           = 10
    lbl.Font               = Enum.Font.Gotham
    lbl.Text               = label
    lbl.TextXAlignment     = Enum.TextXAlignment.Left

    local pill = Instance.new("Frame", parent)
    pill.Size             = UDim2.fromOffset(36, 18)
    pill.Position         = UDim2.new(1, -44, 0, y - 1)
    pill.BackgroundColor3 = cfg[key] and C.on or C.off
    pill.BorderSizePixel  = 0
    Instance.new("UICorner", pill).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame", pill)
    knob.Size             = UDim2.fromOffset(12, 12)
    knob.Position         = cfg[key] and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
    knob.BackgroundColor3 = cfg[key] and C.knobOn or C.knobOff
    knob.BorderSizePixel  = 0
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local hit = Instance.new("TextButton", pill)
    hit.Size               = UDim2.new(1, 0, 1, 0)
    hit.BackgroundTransparency = 1
    hit.Text               = ""
    hit.BorderSizePixel    = 0
    hit.MouseButton1Click:Connect(function()
        cfg[key] = not cfg[key]
        pill.BackgroundColor3 = cfg[key] and C.on or C.off
        knob.Position         = cfg[key] and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
        knob.BackgroundColor3 = cfg[key] and C.knobOn or C.knobOff
        if onToggled then onToggled(cfg[key]) end
    end)

    return pill, knob
end

local farmDungeonPill, farmDungeonKnob -- referenciados pelo toggle "Quest Mais Alta" abaixo

makeToggleSlot(TogglesCard, 16, "Ataque", "autoAttack")
makeToggleSlot(TogglesCard, 42, "Skills", "autoSkills")
makeToggleSlot(TogglesCard, 68, "Coletar Drop", "autoCollect")
makeToggleSlot(TogglesCard, 94, "Quest Mais Alta", "autoQuestHighest", function(enabled)
    if enabled then
        -- Quest Mais Alta e Farm Masmora são mutuamente exclusivos
        cfg.farmDungeon = false
        if farmDungeonPill then
            farmDungeonPill.BackgroundColor3 = C.off
            farmDungeonKnob.Position         = UDim2.fromOffset(3, 3)
            farmDungeonKnob.BackgroundColor3 = C.knobOff
        end

        -- Quando ativado, pega a quest mais alta IMEDIATAMENTE
        -- (e já aceita ela no servidor via startQuestFarm)
        local lvl = getPlayerLevel()
        local best = findBestQuest(lvl)

        if best then
            startQuestFarm(best)
        end
    else
        -- Quando desativado, limpa a quest atual
        currentQuestMob = nil
        currentQuestId  = nil
    end
end)
farmDungeonPill, farmDungeonKnob = makeToggleSlot(TogglesCard, 120, "Farm Masmora", "farmDungeon", function(enabled)
    if enabled then
        -- Farm Masmora e Quest Mais Alta são mutuamente exclusivos
        cfg.autoQuestHighest = false
        currentQuestMob = nil
        currentQuestId  = nil

        -- Limpa qualquer seleção de mob/quest manual
        if SelectorText then
            SelectorText.Text = "Selecionar mob..."
            SelectorText.TextColor3 = C.dim
        end
        if QuestSelectorText then
            QuestSelectorText.Text = "Selecionar quest..."
            QuestSelectorText.TextColor3 = C.dim
        end

        -- Farma QUALQUER mob vivo, sem checar/trocar mundo (a masmora
        -- não é um dos mundos normais registrados em WORLD_MIN_LV)
        startFarm({ name = nil, world = nil }, "Farm Masmora")
    else
        stopFarm()
    end
end)
end -- fim do bloco Automação

-- ══════════════════════════════════════════════════
--  QUEST ATIVA (status da Quest Mais Alta / manual)
-- ══════════════════════════════════════════════════
local QuestStatusCard = makeCard(30, nil)
local QuestStatusLabel = Instance.new("TextLabel", QuestStatusCard)
QuestStatusLabel.Size               = UDim2.new(1, -16, 1, -4)
QuestStatusLabel.Position           = UDim2.new(0, 8, 0, 2)
QuestStatusLabel.BackgroundTransparency = 1
QuestStatusLabel.TextColor3         = C.dim
QuestStatusLabel.TextSize           = 10
QuestStatusLabel.Font               = Enum.Font.Gotham
QuestStatusLabel.Text               = "Quest ativa: nenhuma"
QuestStatusLabel.TextXAlignment     = Enum.TextXAlignment.Left
QuestStatusLabel.TextTruncate       = Enum.TextTruncate.AtEnd

table.insert(questStatusUpdaters, function()
    if currentQuestTitle then
        QuestStatusLabel.Text = "Quest ativa: " .. currentQuestTitle
        QuestStatusLabel.TextColor3 = C.text
    else
        QuestStatusLabel.Text = "Quest ativa: nenhuma"
        QuestStatusLabel.TextColor3 = C.dim
    end
end)

-- ══════════════════════════════════════════════════
--  SELETOR DE RARIDADES (com borda)
-- ══════════════════════════════════════════════════
do
local RarityCard = makeCard(40, "Raridades para coletar", true)

local RaritySelector = Instance.new("TextButton", RarityCard)
RaritySelector.Size             = UDim2.new(1, -16, 0, 20)
RaritySelector.Position         = UDim2.new(0, 8, 0, 16)
RaritySelector.BackgroundColor3 = C.bg3
RaritySelector.Text             = ""
RaritySelector.AutoButtonColor  = false
RaritySelector.BorderSizePixel  = 0
Instance.new("UICorner", RaritySelector).CornerRadius = UDim.new(0, 4)

local RaritySelectorText = Instance.new("TextLabel", RaritySelector)
RaritySelectorText.Size               = UDim2.new(1, -26, 1, 0)
RaritySelectorText.Position           = UDim2.new(0, 8, 0, 0)
RaritySelectorText.BackgroundTransparency = 1
RaritySelectorText.TextColor3         = C.dim
RaritySelectorText.TextSize           = 11
RaritySelectorText.Font               = Enum.Font.GothamBold
RaritySelectorText.Text               = "Raridades (0)"
RaritySelectorText.TextXAlignment     = Enum.TextXAlignment.Left
RaritySelectorText.TextTruncate       = Enum.TextTruncate.AtEnd

local RaritySelectorArrow = Instance.new("TextLabel", RaritySelector)
RaritySelectorArrow.Size               = UDim2.new(0, 18, 1, 0)
RaritySelectorArrow.Position           = UDim2.new(1, -20, 0, 0)
RaritySelectorArrow.BackgroundTransparency = 1
RaritySelectorArrow.TextColor3         = C.dim
RaritySelectorArrow.TextSize           = 10
RaritySelectorArrow.Font               = Enum.Font.GothamBold
RaritySelectorArrow.Text               = "v"
RaritySelectorArrow.TextXAlignment     = Enum.TextXAlignment.Center

do
local RarityOverlay = Instance.new("Frame", Main)
RarityOverlay.Name             = "RarityOverlay"
RarityOverlay.Size             = UDim2.new(0, 220, 0, 280)
RarityOverlay.Position         = UDim2.new(0.5, -110, 0.5, -140)
RarityOverlay.BackgroundColor3 = C.bg2
RarityOverlay.BorderSizePixel  = 0
RarityOverlay.Visible          = false
RarityOverlay.ZIndex           = 30
Instance.new("UICorner", RarityOverlay).CornerRadius = UDim.new(0, 6)
local rarOvStroke = Instance.new("UIStroke", RarityOverlay)
rarOvStroke.Color = C.line
rarOvStroke.Thickness = 1

local RarityOverlayClose = Instance.new("TextButton", RarityOverlay)
RarityOverlayClose.Size             = UDim2.fromOffset(20, 20)
RarityOverlayClose.Position         = UDim2.new(1, -26, 0, 6)
RarityOverlayClose.BackgroundColor3 = C.bg3
RarityOverlayClose.Text             = "X"
RarityOverlayClose.TextColor3       = C.white
RarityOverlayClose.TextSize         = 10
RarityOverlayClose.Font             = Enum.Font.GothamBold
RarityOverlayClose.BorderSizePixel  = 0
RarityOverlayClose.ZIndex           = 31
Instance.new("UICorner", RarityOverlayClose).CornerRadius = UDim.new(0, 4)

local RarityListFrame = Instance.new("ScrollingFrame", RarityOverlay)
RarityListFrame.Size                 = UDim2.new(1, -12, 1, -36)
RarityListFrame.Position             = UDim2.new(0, 6, 0, 30)
RarityListFrame.BackgroundTransparency = 1
RarityListFrame.BorderSizePixel      = 0
RarityListFrame.ScrollBarThickness   = 4
RarityListFrame.ScrollBarImageColor3 = C.dim
RarityListFrame.AutomaticCanvasSize  = Enum.AutomaticSize.Y
RarityListFrame.CanvasSize           = UDim2.new()
RarityListFrame.ZIndex               = 31

local RarityListLayout = Instance.new("UIListLayout", RarityListFrame)
RarityListLayout.SortOrder = Enum.SortOrder.LayoutOrder
RarityListLayout.Padding   = UDim.new(0, 3)

local RarityListPad = Instance.new("UIPadding", RarityListFrame)
RarityListPad.PaddingLeft   = UDim.new(0, 4)
RarityListPad.PaddingRight  = UDim.new(0, 4)
RarityListPad.PaddingTop    = UDim.new(0, 4)
RarityListPad.PaddingBottom = UDim.new(0, 4)

local rarityOverlayOpen = false
local function setRarityOverlayOpen(open)
    rarityOverlayOpen = open
    RarityOverlay.Visible = open
    RaritySelectorArrow.Text = open and "^" or "v"
end

RaritySelector.MouseButton1Click:Connect(function()
    setRarityOverlayOpen(not rarityOverlayOpen)
end)
RarityOverlayClose.MouseButton1Click:Connect(function()
    setRarityOverlayOpen(false)
end)

local function updateRaritySelectorText()
    local count = 0
    for _ in pairs(cfg.collectRarities) do
        count = count + 1
    end
    RaritySelectorText.Text = ("Raridades (%d)"):format(count)
    RaritySelectorText.TextColor3 = count > 0 and C.text or C.dim
end

for i, rarity in ipairs(RARITY_LIST) do
    local row = Instance.new("TextButton", RarityListFrame)
    row.Size             = UDim2.new(1, 0, 0, 26)
    row.LayoutOrder       = i
    row.BackgroundColor3 = C.bg3
    row.Text             = ""
    row.BorderSizePixel  = 0
    row.AutoButtonColor  = false
    row.ZIndex            = 31
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 4)

    local nameLbl = Instance.new("TextLabel", row)
    nameLbl.Size               = UDim2.new(1, -40, 1, 0)
    nameLbl.Position           = UDim2.new(0, 10, 0, 0)
    nameLbl.BackgroundTransparency = 1
    nameLbl.TextColor3         = C.text
    nameLbl.TextSize           = 12
    nameLbl.Font               = Enum.Font.Gotham
    nameLbl.Text               = rarity.name
    nameLbl.TextXAlignment     = Enum.TextXAlignment.Left
    nameLbl.ZIndex              = 32

    local check = Instance.new("TextLabel", row)
    check.Size               = UDim2.new(0, 24, 1, 0)
    check.Position           = UDim2.new(1, -28, 0, 0)
    check.BackgroundTransparency = 1
    check.TextColor3         = C.white
    check.TextSize           = 14
    check.Font               = Enum.Font.GothamBold
    check.Text               = cfg.collectRarities[rarity.id] and "V" or ""
    check.TextXAlignment     = Enum.TextXAlignment.Center
    check.ZIndex              = 32

    row.MouseButton1Click:Connect(function()
        cfg.collectRarities[rarity.id] = not cfg.collectRarities[rarity.id] or nil
        check.Text = cfg.collectRarities[rarity.id] and "V" or ""
        updateRaritySelectorText()
    end)
end
end -- fim do bloco RarityOverlay
end -- fim do bloco Seletor de Raridades

-- ══════════════════════════════════════════════════
--  STATS DO PLAYER
-- ══════════════════════════════════════════════════
do
local StatsCard = makeCard(120, "Player Stats", true, tabContents["Player"])

local function makeStatRow(parent, y, label)
    local lbl = Instance.new("TextLabel", parent)
    lbl.Size               = UDim2.new(0.4, 0, 0, 20)
    lbl.Position           = UDim2.new(0, 8, 0, y)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3         = C.dim
    lbl.TextSize           = 10
    lbl.Font               = Enum.Font.GothamBold
    lbl.Text               = label:upper()
    lbl.TextXAlignment     = Enum.TextXAlignment.Left

    local val = Instance.new("TextLabel", parent)
    val.Size               = UDim2.new(0.6, -16, 0, 20)
    val.Position           = UDim2.new(0.4, 0, 0, y)
    val.BackgroundTransparency = 1
    val.TextColor3         = C.white
    val.TextSize           = 12
    val.Font               = Enum.Font.GothamBold
    val.Text               = "--"
    val.TextXAlignment     = Enum.TextXAlignment.Left

    return val
end

local levelVal  = makeStatRow(StatsCard, 16, "Level")
local worldVal  = makeStatRow(StatsCard, 40, "Mundo")
local goldVal   = makeStatRow(StatsCard, 64, "Gold")
local shardsVal = makeStatRow(StatsCard, 88, "Shards")

local function fmtNumber(n)
    if type(n) ~= "number" then return "--" end
    if n >= 1e9 then return string.format("%.2fB", n / 1e9)
    elseif n >= 1e6 then return string.format("%.2fM", n / 1e6)
    elseif n >= 1e3 then return string.format("%.1fK", n / 1e3)
    end
    return tostring(math.floor(n))
end

task.spawn(function()
    while true do
        task.wait(1)
        pcall(function()
            levelVal.Text  = tostring(getPlayerLevel())
            goldVal.Text   = fmtNumber(getPlayerGold())
            shardsVal.Text = fmtNumber(getPlayerShards())
            worldVal.Text  = getCurrentWorld() or "--"
        end)
    end
end)
end -- fim do bloco Player Stats

-- ══════════════════════════════════════════════════
--  TAB: FORJA (sistema completo de auto forja)
-- ══════════════════════════════════════════════════
local ForjaTab = tabContents["Forja"]

-- ── Card: Seletor de Itens ──
do
local ForgeItemsCard = makeCard(60, "Itens para Forjar", true, ForjaTab)

local ForgeItemsSelector = Instance.new("TextButton", ForgeItemsCard)
ForgeItemsSelector.Size             = UDim2.new(1, -16, 0, 26)
ForgeItemsSelector.Position         = UDim2.new(0, 8, 0, 24)
ForgeItemsSelector.BackgroundColor3 = C.bg3
ForgeItemsSelector.Text             = ""
ForgeItemsSelector.AutoButtonColor  = false
ForgeItemsSelector.BorderSizePixel  = 0
Instance.new("UICorner", ForgeItemsSelector).CornerRadius = UDim.new(0, 4)

local ForgeItemsSelectorText = Instance.new("TextLabel", ForgeItemsSelector)
ForgeItemsSelectorText.Size               = UDim2.new(1, -26, 1, 0)
ForgeItemsSelectorText.Position           = UDim2.new(0, 8, 0, 0)
ForgeItemsSelectorText.BackgroundTransparency = 1
ForgeItemsSelectorText.TextColor3         = C.dim
ForgeItemsSelectorText.TextSize           = 11
ForgeItemsSelectorText.Font               = Enum.Font.GothamBold
ForgeItemsSelectorText.Text               = "Selecionar itens... (0)"
ForgeItemsSelectorText.TextXAlignment     = Enum.TextXAlignment.Left
ForgeItemsSelectorText.TextTruncate       = Enum.TextTruncate.AtEnd

local ForgeItemsSelectorArrow = Instance.new("TextLabel", ForgeItemsSelector)
ForgeItemsSelectorArrow.Size               = UDim2.new(0, 18, 1, 0)
ForgeItemsSelectorArrow.Position           = UDim2.new(1, -20, 0, 0)
ForgeItemsSelectorArrow.BackgroundTransparency = 1
ForgeItemsSelectorArrow.TextColor3         = C.dim
ForgeItemsSelectorArrow.TextSize           = 10
ForgeItemsSelectorArrow.Font               = Enum.Font.GothamBold
ForgeItemsSelectorArrow.Text               = "v"
ForgeItemsSelectorArrow.TextXAlignment     = Enum.TextXAlignment.Center

-- ── Overlay: Lista de Itens do Inventário (multi-seleção,
--    com filtro de categoria + busca por nome) ──
do
local ForgeItemsOverlay = Instance.new("Frame", Main)
ForgeItemsOverlay.Name             = "ForgeItemsOverlay"
ForgeItemsOverlay.Size             = UDim2.new(0, 400, 0, 400)
ForgeItemsOverlay.Position         = UDim2.new(0.5, -200, 0.5, -200)
ForgeItemsOverlay.BackgroundColor3 = C.bg2
ForgeItemsOverlay.BorderSizePixel  = 0
ForgeItemsOverlay.Visible          = false
ForgeItemsOverlay.ZIndex           = 30
Instance.new("UICorner", ForgeItemsOverlay).CornerRadius = UDim.new(0, 6)
local forgeOvStroke = Instance.new("UIStroke", ForgeItemsOverlay)
forgeOvStroke.Color = C.white
forgeOvStroke.Thickness = 1
forgeOvStroke.Transparency = 0.6

local ForgeItemsOverlayTitle = Instance.new("TextLabel", ForgeItemsOverlay)
ForgeItemsOverlayTitle.Size               = UDim2.new(1, -60, 0, 22)
ForgeItemsOverlayTitle.Position           = UDim2.new(0, 10, 0, 4)
ForgeItemsOverlayTitle.BackgroundTransparency = 1
ForgeItemsOverlayTitle.TextColor3         = C.white
ForgeItemsOverlayTitle.TextSize           = 12
ForgeItemsOverlayTitle.Font               = Enum.Font.GothamBold
ForgeItemsOverlayTitle.Text               = "SELECIONE OS ITENS"
ForgeItemsOverlayTitle.TextXAlignment     = Enum.TextXAlignment.Left

local ForgeItemsOverlayClose = Instance.new("TextButton", ForgeItemsOverlay)
ForgeItemsOverlayClose.Size             = UDim2.fromOffset(20, 20)
ForgeItemsOverlayClose.Position         = UDim2.new(1, -26, 0, 4)
ForgeItemsOverlayClose.BackgroundColor3 = C.bg3
ForgeItemsOverlayClose.Text             = "X"
ForgeItemsOverlayClose.TextColor3       = C.white
ForgeItemsOverlayClose.TextSize         = 10
ForgeItemsOverlayClose.Font             = Enum.Font.GothamBold
ForgeItemsOverlayClose.BorderSizePixel  = 0
ForgeItemsOverlayClose.ZIndex           = 31
Instance.new("UICorner", ForgeItemsOverlayClose).CornerRadius = UDim.new(0, 4)

-- ── Campo de busca (lupa) ──
local ForgeSearchBox = Instance.new("TextBox", ForgeItemsOverlay)
ForgeSearchBox.Size             = UDim2.new(1, -20, 0, 24)
ForgeSearchBox.Position         = UDim2.new(0, 10, 0, 28)
ForgeSearchBox.BackgroundColor3 = C.bg3
ForgeSearchBox.Text             = ""
ForgeSearchBox.PlaceholderText   = "🔍 Pesquisar item..."
ForgeSearchBox.PlaceholderColor3 = C.dim
ForgeSearchBox.TextColor3       = C.text
ForgeSearchBox.TextSize         = 11
ForgeSearchBox.Font             = Enum.Font.Gotham
ForgeSearchBox.ClearTextOnFocus = false
ForgeSearchBox.BorderSizePixel  = 0
ForgeSearchBox.ZIndex           = 31
local searchPad = Instance.new("UIPadding", ForgeSearchBox)
searchPad.PaddingLeft = UDim.new(0, 8)
Instance.new("UICorner", ForgeSearchBox).CornerRadius = UDim.new(0, 4)

-- ── Filtros de categoria (Todos / Weapon / Headgear / Chestplate / Leggings / Boots) ──
local ForgeCategoryBar = Instance.new("Frame", ForgeItemsOverlay)
ForgeCategoryBar.Size             = UDim2.new(1, -20, 0, 22)
ForgeCategoryBar.Position         = UDim2.new(0, 10, 0, 56)
ForgeCategoryBar.BackgroundTransparency = 1
ForgeCategoryBar.ZIndex           = 31

local ForgeCategoryLayout = Instance.new("UIListLayout", ForgeCategoryBar)
ForgeCategoryLayout.FillDirection = Enum.FillDirection.Horizontal
ForgeCategoryLayout.Padding      = UDim.new(0, 4)
ForgeCategoryLayout.SortOrder    = Enum.SortOrder.LayoutOrder

local FORGE_CATEGORIES = {"Todos", "Weapon", "Headgear", "Chestplate", "Leggings", "Boots"}
local selectedForgeCategory = "Todos"
local forgeCategoryButtons = {}

local function makeForgeCategoryButton(name, order)
    local btn = Instance.new("TextButton", ForgeCategoryBar)
    btn.Size             = UDim2.new(0, 58, 1, 0)
    btn.LayoutOrder      = order
    btn.BackgroundColor3 = (selectedForgeCategory == name) and C.on or C.bg3
    btn.Text             = name
    btn.TextColor3       = (selectedForgeCategory == name) and C.knobOn or C.text
    btn.TextSize         = 9
    btn.Font             = Enum.Font.GothamBold
    btn.AutoButtonColor  = false
    btn.BorderSizePixel  = 0
    btn.ZIndex           = 31
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
    forgeCategoryButtons[name] = btn
    return btn
end

for i, catName in ipairs(FORGE_CATEGORIES) do
    makeForgeCategoryButton(catName, i)
end

local ForgeItemsRefreshBtn = Instance.new("TextButton", ForgeItemsOverlay)
ForgeItemsRefreshBtn.Size             = UDim2.new(1, -20, 0, 20)
ForgeItemsRefreshBtn.Position         = UDim2.new(0, 10, 0, 82)
ForgeItemsRefreshBtn.BackgroundColor3 = C.bg3
ForgeItemsRefreshBtn.Text             = "Atualizar lista do inventário"
ForgeItemsRefreshBtn.TextColor3       = C.white
ForgeItemsRefreshBtn.TextSize         = 10
ForgeItemsRefreshBtn.Font             = Enum.Font.GothamBold
ForgeItemsRefreshBtn.BorderSizePixel  = 0
ForgeItemsRefreshBtn.ZIndex           = 31
Instance.new("UICorner", ForgeItemsRefreshBtn).CornerRadius = UDim.new(0, 4)

local ForgeItemsListFrame = Instance.new("ScrollingFrame", ForgeItemsOverlay)
ForgeItemsListFrame.Size                 = UDim2.new(1, -12, 1, -138)
ForgeItemsListFrame.Position             = UDim2.new(0, 6, 0, 106)
ForgeItemsListFrame.BackgroundTransparency = 1
ForgeItemsListFrame.BorderSizePixel      = 0
ForgeItemsListFrame.ScrollBarThickness   = 4
ForgeItemsListFrame.ScrollBarImageColor3 = C.dim
ForgeItemsListFrame.AutomaticCanvasSize  = Enum.AutomaticSize.Y
ForgeItemsListFrame.CanvasSize           = UDim2.new()
ForgeItemsListFrame.ZIndex               = 31

local ForgeItemsListLayout = Instance.new("UIListLayout", ForgeItemsListFrame)
ForgeItemsListLayout.SortOrder = Enum.SortOrder.LayoutOrder
ForgeItemsListLayout.Padding   = UDim.new(0, 2)

local ForgeItemsListPad = Instance.new("UIPadding", ForgeItemsListFrame)
ForgeItemsListPad.PaddingLeft   = UDim.new(0, 4)
ForgeItemsListPad.PaddingRight  = UDim.new(0, 4)
ForgeItemsListPad.PaddingTop    = UDim.new(0, 4)
ForgeItemsListPad.PaddingBottom = UDim.new(0, 4)

local ForgeItemsSelectAllBtn = Instance.new("TextButton", ForgeItemsOverlay)
ForgeItemsSelectAllBtn.Size             = UDim2.new(1, -20, 0, 22)
ForgeItemsSelectAllBtn.Position         = UDim2.new(0, 10, 1, -28)
ForgeItemsSelectAllBtn.BackgroundColor3 = C.bg3
ForgeItemsSelectAllBtn.Text             = "Confirmar seleção"
ForgeItemsSelectAllBtn.TextColor3       = C.white
ForgeItemsSelectAllBtn.TextSize         = 11
ForgeItemsSelectAllBtn.Font             = Enum.Font.GothamBold
ForgeItemsSelectAllBtn.BorderSizePixel  = 0
ForgeItemsSelectAllBtn.ZIndex           = 31
Instance.new("UICorner", ForgeItemsSelectAllBtn).CornerRadius = UDim.new(0, 4)

local function updateForgeItemsSelectorText()
    local count = 0
    for _, sel in pairs(selectedForgeItems) do
        if sel then count = count + 1 end
    end
    ForgeItemsSelectorText.Text = ("Selecionar itens... (%d)"):format(count)
    ForgeItemsSelectorText.TextColor3 = count > 0 and C.text or C.dim
end

-- Cache da última lista buscada no inventário (evita rechamar o
-- inventário a cada tecla digitada na busca)
local cachedForgeItems = nil

-- Popula a lista de itens do inventário aplicando filtro de categoria
-- + busca por nome. Chamada ao abrir o overlay, digitar na busca,
-- trocar categoria ou clicar em "Atualizar".
local function refreshForgeItemsList(skipRefetch)
    if not skipRefetch or not cachedForgeItems then
        cachedForgeItems = getForgeableItems()
    end

    for _, child in ipairs(ForgeItemsListFrame:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end

    local searchText = ForgeSearchBox.Text:lower()

    local filtered = {}
    for _, item in ipairs(cachedForgeItems) do
        local matchesCategory = (selectedForgeCategory == "Todos") or (item.category == selectedForgeCategory)
        local matchesSearch = (searchText == "") or item.name:lower():find(searchText, 1, true)
        if matchesCategory and matchesSearch then
            table.insert(filtered, item)
        end
    end

    if #filtered == 0 then
        local emptyLbl = Instance.new("TextLabel", ForgeItemsListFrame)
        emptyLbl.Size = UDim2.new(1, 0, 0, 30)
        emptyLbl.BackgroundTransparency = 1
        emptyLbl.TextColor3 = C.dim
        emptyLbl.TextSize = 10
        emptyLbl.Font = Enum.Font.Gotham
        emptyLbl.Text = (#cachedForgeItems == 0)
            and "Nenhum item encontrado. Abra o inventário no jogo\npara garantir que os dados foram carregados."
            or "Nenhum item corresponde ao filtro/busca."
        emptyLbl.TextWrapped = true
        emptyLbl.ZIndex = 31
        return
    end

    for i, item in ipairs(filtered) do
        local row = Instance.new("TextButton", ForgeItemsListFrame)
        row.Size             = UDim2.new(1, 0, 0, 34)
        row.LayoutOrder       = i
        row.BackgroundColor3 = C.bg3
        row.Text             = ""
        row.BorderSizePixel  = 0
        row.AutoButtonColor  = false
        row.ZIndex            = 31
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 4)

        local nameLbl = Instance.new("TextLabel", row)
        nameLbl.Size               = UDim2.new(0.55, 0, 0, 16)
        nameLbl.Position           = UDim2.new(0, 8, 0, 3)
        nameLbl.BackgroundTransparency = 1
        nameLbl.TextColor3         = C.text
        nameLbl.TextSize           = 11
        nameLbl.Font               = Enum.Font.Gotham
        nameLbl.Text               = item.name .. (item.equipped and " [Equipado]" or "")
        nameLbl.TextXAlignment     = Enum.TextXAlignment.Left
        nameLbl.TextTruncate       = Enum.TextTruncate.AtEnd
        nameLbl.ZIndex              = 32

        -- Categoria + status de forja (nível atual / se já foi forjado)
        local subLbl = Instance.new("TextLabel", row)
        subLbl.Size               = UDim2.new(0.55, 0, 0, 12)
        subLbl.Position           = UDim2.new(0, 8, 0, 19)
        subLbl.BackgroundTransparency = 1
        subLbl.TextColor3         = C.dim
        subLbl.TextSize           = 9
        subLbl.Font               = Enum.Font.Gotham
        subLbl.Text               = item.category .. "  •  " .. (item.level > 0
            and ("Forjado até +" .. item.level)
            or "Não forjado")
        subLbl.TextXAlignment     = Enum.TextXAlignment.Left
        subLbl.ZIndex              = 32

        -- Badge do nível de forja atual (bem visível, canto direito)
        local lvlBadge = Instance.new("TextLabel", row)
        lvlBadge.Size               = UDim2.new(0, 44, 0, 20)
        lvlBadge.Position           = UDim2.new(1, -78, 0, 7)
        lvlBadge.BackgroundColor3   = item.level > 0 and C.on or C.off
        lvlBadge.TextColor3         = item.level > 0 and C.knobOn or C.dim
        lvlBadge.TextSize           = 11
        lvlBadge.Font               = Enum.Font.GothamBold
        lvlBadge.Text               = "+" .. item.level
        lvlBadge.TextXAlignment     = Enum.TextXAlignment.Center
        lvlBadge.ZIndex              = 32
        Instance.new("UICorner", lvlBadge).CornerRadius = UDim.new(0, 4)

        local check = Instance.new("TextLabel", row)
        check.Size               = UDim2.new(0, 24, 1, 0)
        check.Position           = UDim2.new(1, -28, 0, 0)
        check.BackgroundTransparency = 1
        check.TextColor3         = C.white
        check.TextSize           = 14
        check.Font               = Enum.Font.GothamBold
        check.Text               = selectedForgeItems[item.key] and "V" or ""
        check.TextXAlignment     = Enum.TextXAlignment.Center
        check.ZIndex              = 32

        row.MouseButton1Click:Connect(function()
            selectedForgeItems[item.key] = not selectedForgeItems[item.key] or nil
            check.Text = selectedForgeItems[item.key] and "V" or ""
            updateForgeItemsSelectorText()
        end)
    end
end

local function selectForgeCategory(catName)
    selectedForgeCategory = catName
    for name, btn in pairs(forgeCategoryButtons) do
        btn.BackgroundColor3 = (name == catName) and C.on or C.bg3
        btn.TextColor3       = (name == catName) and C.knobOn or C.text
    end
    refreshForgeItemsList(true)
end

for catName, btn in pairs(forgeCategoryButtons) do
    btn.MouseButton1Click:Connect(function()
        selectForgeCategory(catName)
    end)
end

ForgeSearchBox:GetPropertyChangedSignal("Text"):Connect(function()
    refreshForgeItemsList(true)
end)

local forgeItemsOverlayOpen = false
local function setForgeItemsOverlayOpen(open)
    forgeItemsOverlayOpen = open
    ForgeItemsOverlay.Visible = open
    ForgeItemsSelectorArrow.Text = open and "^" or "v"
    if open then
        refreshForgeItemsList(false)
    end
end

ForgeItemsSelector.MouseButton1Click:Connect(function()
    setForgeItemsOverlayOpen(not forgeItemsOverlayOpen)
end)
ForgeItemsOverlayClose.MouseButton1Click:Connect(function()
    setForgeItemsOverlayOpen(false)
end)
ForgeItemsRefreshBtn.MouseButton1Click:Connect(function()
    refreshForgeItemsList(false)
end)
ForgeItemsSelectAllBtn.MouseButton1Click:Connect(function()
    setForgeItemsOverlayOpen(false)
end)
end -- fim do bloco ForgeItemsOverlay
end -- fim do bloco Seletor de Itens da Forja

-- ── Card: Nível Alvo ──
do
local ForgeTargetCard = makeCard(50, "Nível Alvo da Forja", true, ForjaTab)

local MIN_FORGE_LVL, MAX_FORGE_LVL = 1, 15

local forgeTargetMinus = Instance.new("TextButton", ForgeTargetCard)
forgeTargetMinus.Size             = UDim2.fromOffset(24, 20)
forgeTargetMinus.Position         = UDim2.new(0, 8, 0, 24)
forgeTargetMinus.BackgroundColor3 = C.off
forgeTargetMinus.Text             = "-"
forgeTargetMinus.TextColor3       = C.white
forgeTargetMinus.TextSize         = 15
forgeTargetMinus.Font             = Enum.Font.GothamBold
forgeTargetMinus.BorderSizePixel  = 0
Instance.new("UICorner", forgeTargetMinus).CornerRadius = UDim.new(0, 4)

local forgeTargetVal = Instance.new("TextLabel", ForgeTargetCard)
forgeTargetVal.Size               = UDim2.new(1, -72, 0, 20)
forgeTargetVal.Position           = UDim2.new(0, 36, 0, 24)
forgeTargetVal.BackgroundTransparency = 1
forgeTargetVal.TextColor3         = C.white
forgeTargetVal.TextSize           = 12
forgeTargetVal.Font               = Enum.Font.GothamBold
forgeTargetVal.Text               = "+" .. forgeTargetLevel
forgeTargetVal.TextXAlignment     = Enum.TextXAlignment.Center

local forgeTargetPlus = Instance.new("TextButton", ForgeTargetCard)
forgeTargetPlus.Size             = UDim2.fromOffset(24, 20)
forgeTargetPlus.Position         = UDim2.new(1, -32, 0, 24)
forgeTargetPlus.BackgroundColor3 = C.off
forgeTargetPlus.Text             = "+"
forgeTargetPlus.TextColor3       = C.white
forgeTargetPlus.TextSize         = 15
forgeTargetPlus.Font             = Enum.Font.GothamBold
forgeTargetPlus.BorderSizePixel  = 0
Instance.new("UICorner", forgeTargetPlus).CornerRadius = UDim.new(0, 4)

forgeTargetMinus.MouseButton1Click:Connect(function()
    forgeTargetLevel = math.max(MIN_FORGE_LVL, forgeTargetLevel - 1)
    forgeTargetVal.Text = "+" .. forgeTargetLevel
end)
forgeTargetPlus.MouseButton1Click:Connect(function()
    forgeTargetLevel = math.min(MAX_FORGE_LVL, forgeTargetLevel + 1)
    forgeTargetVal.Text = "+" .. forgeTargetLevel
end)

end -- fim do bloco Nível Alvo

-- ── Card: Proteção Forgeguard ──
do
local ForgeProtectionCard = makeCard(40, "Proteção", true, ForjaTab)

local protLbl = Instance.new("TextLabel", ForgeProtectionCard)
protLbl.Size               = UDim2.new(1, -60, 0, 12)
protLbl.Position           = UDim2.new(0, 8, 0, 22)
protLbl.BackgroundTransparency = 1
protLbl.TextColor3         = C.text
protLbl.TextSize           = 10
protLbl.Font               = Enum.Font.Gotham
protLbl.Text               = "Usar Forgeguard (proteção)"
protLbl.TextXAlignment     = Enum.TextXAlignment.Left

local protPill = Instance.new("Frame", ForgeProtectionCard)
protPill.Size             = UDim2.fromOffset(36, 18)
protPill.Position         = UDim2.new(1, -44, 0, 21)
protPill.BackgroundColor3 = cfg.forgeUseProtection and C.on or C.off
protPill.BorderSizePixel  = 0
Instance.new("UICorner", protPill).CornerRadius = UDim.new(1, 0)

local protKnob = Instance.new("Frame", protPill)
protKnob.Size             = UDim2.fromOffset(12, 12)
protKnob.Position         = cfg.forgeUseProtection and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
protKnob.BackgroundColor3 = cfg.forgeUseProtection and C.knobOn or C.knobOff
protKnob.BorderSizePixel  = 0
Instance.new("UICorner", protKnob).CornerRadius = UDim.new(1, 0)

local protHit = Instance.new("TextButton", protPill)
protHit.Size               = UDim2.new(1, 0, 1, 0)
protHit.BackgroundTransparency = 1
protHit.Text               = ""
protHit.BorderSizePixel    = 0
protHit.MouseButton1Click:Connect(function()
    cfg.forgeUseProtection = not cfg.forgeUseProtection
    protPill.BackgroundColor3 = cfg.forgeUseProtection and C.on or C.off
    protKnob.Position         = cfg.forgeUseProtection and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
    protKnob.BackgroundColor3 = cfg.forgeUseProtection and C.knobOn or C.knobOff
end)

end -- fim do bloco Proteção

-- ── Card: Status + Botões ──
local ForgeControlCard = makeCard(76, nil, false, ForjaTab)

forgeStatusLabel = Instance.new("TextLabel", ForgeControlCard)
forgeStatusLabel.Size               = UDim2.new(1, -16, 0, 16)
forgeStatusLabel.Position           = UDim2.new(0, 8, 0, 4)
forgeStatusLabel.BackgroundTransparency = 1
forgeStatusLabel.TextColor3         = C.dim
forgeStatusLabel.TextSize           = 10
forgeStatusLabel.Font               = Enum.Font.Gotham
forgeStatusLabel.Text               = "Aguardando..."
forgeStatusLabel.TextXAlignment     = Enum.TextXAlignment.Left
forgeStatusLabel.TextTruncate       = Enum.TextTruncate.AtEnd

local forgeStartBtn = Instance.new("TextButton", ForgeControlCard)
forgeStartBtn.Size             = UDim2.new(1, -16, 0, 28)
forgeStartBtn.Position         = UDim2.new(0, 8, 0, 24)
forgeStartBtn.BackgroundColor3 = C.bg3
forgeStartBtn.Text             = "INICIAR AUTO FORJA"
forgeStartBtn.TextColor3       = C.white
forgeStartBtn.TextSize         = 12
forgeStartBtn.Font             = Enum.Font.GothamBold
forgeStartBtn.BorderSizePixel  = 0
Instance.new("UICorner", forgeStartBtn).CornerRadius = UDim.new(0, 5)
local forgeStartStroke = Instance.new("UIStroke", forgeStartBtn)
forgeStartStroke.Color = C.white
forgeStartStroke.Thickness = 1
forgeStartStroke.Transparency = 0.6

forgeStartBtn.MouseButton1Click:Connect(function()
    if autoForgeRunning then
        stopAutoForge()
        forgeStartBtn.Text = "INICIAR AUTO FORJA"
    else
        startAutoForge()
        forgeStartBtn.Text = "PARAR AUTO FORJA"
    end
end)

-- ── Card: Info do sistema ──
do
local ForgeInfoCard = makeCard(90, "Info", true, ForjaTab)

local forgeInfo = Instance.new("TextLabel", ForgeInfoCard)
forgeInfo.Size               = UDim2.new(1, -16, 1, -20)
forgeInfo.Position           = UDim2.new(0, 8, 0, 18)
forgeInfo.BackgroundTransparency = 1
forgeInfo.TextColor3         = C.dim
forgeInfo.TextSize           = 10
forgeInfo.Font               = Enum.Font.Gotham
forgeInfo.Text               = "• Forge Normal: +0 a +6 (Gold + Shards)\n• Magic Forge: +6 a +10 (Gold + Shards)\n• Expert Forge: +10 a +15 (ForgeShards)\n\n⚠️ Proteção recomendada a partir de +6"
forgeInfo.TextXAlignment     = Enum.TextXAlignment.Left
forgeInfo.TextYAlignment     = Enum.TextYAlignment.Top
forgeInfo.TextWrapped        = true

end -- fim do bloco Info da Forja

-- ══════════════════════════════════════════════════
--  BOTÃO PARAR
-- ══════════════════════════════════════════════════
do
local StopCard = makeCard(32, nil)

local stopButton = Instance.new("TextButton", StopCard)
stopButton.Size             = UDim2.new(1, -16, 1, -8)
stopButton.Position         = UDim2.new(0, 8, 0, 4)
stopButton.BackgroundColor3 = C.bg3
stopButton.Text             = "PARAR FARM"
stopButton.TextColor3       = C.white
stopButton.TextSize           = 12
stopButton.Font             = Enum.Font.GothamBold
stopButton.BorderSizePixel  = 0
Instance.new("UICorner", stopButton).CornerRadius = UDim.new(0, 5)
local stopStroke = Instance.new("UIStroke", stopButton)
stopStroke.Color = C.line
stopStroke.Thickness = 1
stopButton.MouseButton1Click:Connect(function()
    stopFarm()
    SelectorText.Text = "Selecionar mob..."
    SelectorText.TextColor3 = C.dim
    QuestSelectorText.Text = "Selecionar quest..."
    QuestSelectorText.TextColor3 = C.dim
end)

end -- fim do bloco Botão Parar

-- ══════════════════════════════════════════════════
--  TAB: MISC (Speed Player + Fly Mode)
-- ══════════════════════════════════════════════════
local MiscTab = tabContents["Misc"]

-- ── Speed Player ──
do
local SpeedCard = makeCard(60, "Movement Speed", true, MiscTab)

local MIN_SPEED, MAX_SPEED, STEP_SPEED = 16, 100, 4
local currentSpeed = 16

local speedMinus = Instance.new("TextButton", SpeedCard)
speedMinus.Size             = UDim2.fromOffset(24, 20)
speedMinus.Position         = UDim2.new(0, 8, 0, 28)
speedMinus.BackgroundColor3 = C.off
speedMinus.Text             = "-"
speedMinus.TextColor3       = C.white
speedMinus.TextSize         = 15
speedMinus.Font             = Enum.Font.GothamBold
speedMinus.BorderSizePixel  = 0
Instance.new("UICorner", speedMinus).CornerRadius = UDim.new(0, 4)

local speedVal = Instance.new("TextLabel", SpeedCard)
speedVal.Size               = UDim2.new(1, -72, 0, 20)
speedVal.Position           = UDim2.new(0, 36, 0, 28)
speedVal.BackgroundTransparency = 1
speedVal.TextColor3         = C.white
speedVal.TextSize           = 12
speedVal.Font               = Enum.Font.GothamBold
speedVal.Text               = tostring(currentSpeed)
speedVal.TextXAlignment     = Enum.TextXAlignment.Center

local speedPlus = Instance.new("TextButton", SpeedCard)
speedPlus.Size             = UDim2.fromOffset(24, 20)
speedPlus.Position         = UDim2.new(1, -32, 0, 28)
speedPlus.BackgroundColor3 = C.off
speedPlus.Text             = "+"
speedPlus.TextColor3       = C.white
speedPlus.TextSize         = 15
speedPlus.Font             = Enum.Font.GothamBold
speedPlus.BorderSizePixel  = 0
Instance.new("UICorner", speedPlus).CornerRadius = UDim.new(0, 4)

local function updateSpeed()
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            hum.WalkSpeed = currentSpeed
        end
    end
end

speedMinus.MouseButton1Click:Connect(function()
    currentSpeed = math.max(MIN_SPEED, currentSpeed - STEP_SPEED)
    speedVal.Text = tostring(currentSpeed)
    updateSpeed()
end)

speedPlus.MouseButton1Click:Connect(function()
    currentSpeed = math.min(MAX_SPEED, currentSpeed + STEP_SPEED)
    speedVal.Text = tostring(currentSpeed)
    updateSpeed()
end)

end -- fim do bloco Speed Player

-- ── Fly Mode ──
do
local FlyCard = makeCard(90, "Fly Mode", true, MiscTab)

local flyEnabled = false
local flySpeed = 50
local flyConnection = nil

local flyToggleLbl = Instance.new("TextLabel", FlyCard)
flyToggleLbl.Size               = UDim2.new(1, -60, 0, 12)
flyToggleLbl.Position           = UDim2.new(0, 8, 0, 24)
flyToggleLbl.BackgroundTransparency = 1
flyToggleLbl.TextColor3         = C.text
flyToggleLbl.TextSize           = 10
flyToggleLbl.Font               = Enum.Font.Gotham
flyToggleLbl.Text               = "Fly Ativado"
flyToggleLbl.TextXAlignment     = Enum.TextXAlignment.Left

local flyPill = Instance.new("Frame", FlyCard)
flyPill.Size             = UDim2.fromOffset(36, 18)
flyPill.Position         = UDim2.new(1, -44, 0, 23)
flyPill.BackgroundColor3 = flyEnabled and C.on or C.off
flyPill.BorderSizePixel  = 0
Instance.new("UICorner", flyPill).CornerRadius = UDim.new(1, 0)

local flyKnob = Instance.new("Frame", flyPill)
flyKnob.Size             = UDim2.fromOffset(12, 12)
flyKnob.Position         = flyEnabled and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
flyKnob.BackgroundColor3 = flyEnabled and C.knobOn or C.knobOff
flyKnob.BorderSizePixel  = 0
Instance.new("UICorner", flyKnob).CornerRadius = UDim.new(1, 0)

local flyHit = Instance.new("TextButton", flyPill)
flyHit.Size               = UDim2.new(1, 0, 1, 0)
flyHit.BackgroundTransparency = 1
flyHit.Text               = ""
flyHit.BorderSizePixel    = 0

-- Fly Speed Control
local flySpeedLabel = Instance.new("TextLabel", FlyCard)
flySpeedLabel.Size               = UDim2.new(1, 0, 0, 12)
flySpeedLabel.Position           = UDim2.new(0, 8, 0, 50)
flySpeedLabel.BackgroundTransparency = 1
flySpeedLabel.TextColor3         = C.dim
flySpeedLabel.TextSize           = 9
flySpeedLabel.Font               = Enum.Font.Gotham
flySpeedLabel.Text               = "Velocidade do Fly"
flySpeedLabel.TextXAlignment     = Enum.TextXAlignment.Left

local flySpeedMinus = Instance.new("TextButton", FlyCard)
flySpeedMinus.Size             = UDim2.fromOffset(24, 20)
flySpeedMinus.Position         = UDim2.new(0, 8, 0, 64)
flySpeedMinus.BackgroundColor3 = C.off
flySpeedMinus.Text             = "-"
flySpeedMinus.TextColor3       = C.white
flySpeedMinus.TextSize         = 15
flySpeedMinus.Font             = Enum.Font.GothamBold
flySpeedMinus.BorderSizePixel  = 0
Instance.new("UICorner", flySpeedMinus).CornerRadius = UDim.new(0, 4)

local flySpeedVal = Instance.new("TextLabel", FlyCard)
flySpeedVal.Size               = UDim2.new(1, -72, 0, 20)
flySpeedVal.Position           = UDim2.new(0, 36, 0, 64)
flySpeedVal.BackgroundTransparency = 1
flySpeedVal.TextColor3         = C.white
flySpeedVal.TextSize           = 12
flySpeedVal.Font               = Enum.Font.GothamBold
flySpeedVal.Text               = tostring(flySpeed)
flySpeedVal.TextXAlignment     = Enum.TextXAlignment.Center

local flySpeedPlus = Instance.new("TextButton", FlyCard)
flySpeedPlus.Size             = UDim2.fromOffset(24, 20)
flySpeedPlus.Position         = UDim2.new(1, -32, 0, 64)
flySpeedPlus.BackgroundColor3 = C.off
flySpeedPlus.Text             = "+"
flySpeedPlus.TextColor3       = C.white
flySpeedPlus.TextSize         = 15
flySpeedPlus.Font             = Enum.Font.GothamBold
flySpeedPlus.BorderSizePixel  = 0
Instance.new("UICorner", flySpeedPlus).CornerRadius = UDim.new(0, 4)

flySpeedMinus.MouseButton1Click:Connect(function()
    flySpeed = math.max(25, flySpeed - 5)
    flySpeedVal.Text = tostring(flySpeed)
end)

flySpeedPlus.MouseButton1Click:Connect(function()
    flySpeed = math.min(100, flySpeed + 5)
    flySpeedVal.Text = tostring(flySpeed)
end)

local function startFly()
    if flyConnection then return end

    local char = LocalPlayer.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local bg = Instance.new("BodyGyro", hrp)
    bg.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
    bg.CFrame = hrp.CFrame

    local bv = Instance.new("BodyVelocity", hrp)
    bv.MaxForce = Vector3.new(9e9, 9e9, 9e9)
    bv.Velocity = Vector3.new()

    local uis = game:GetService("UserInputService")
    local keys = {}

    local conn1 = uis.InputBegan:Connect(function(input, gpe)
        if gpe then return end
        if input.KeyCode == Enum.KeyCode.W then keys.W = true end
        if input.KeyCode == Enum.KeyCode.S then keys.S = true end
        if input.KeyCode == Enum.KeyCode.A then keys.A = true end
        if input.KeyCode == Enum.KeyCode.D then keys.D = true end
        if input.KeyCode == Enum.KeyCode.Space then keys.Up = true end
        if input.KeyCode == Enum.KeyCode.LeftShift then keys.Down = true end
    end)

    local conn2 = uis.InputEnded:Connect(function(input)
        if input.KeyCode == Enum.KeyCode.W then keys.W = false end
        if input.KeyCode == Enum.KeyCode.S then keys.S = false end
        if input.KeyCode == Enum.KeyCode.A then keys.A = false end
        if input.KeyCode == Enum.KeyCode.D then keys.D = false end
        if input.KeyCode == Enum.KeyCode.Space then keys.Up = false end
        if input.KeyCode == Enum.KeyCode.LeftShift then keys.Down = false end
    end)

    flyConnection = RunService.Heartbeat:Connect(function()
        if not flyEnabled then
            if flyConnection then flyConnection:Disconnect() end
            flyConnection = nil
            conn1:Disconnect()
            conn2:Disconnect()
            if bg then bg:Destroy() end
            if bv then bv:Destroy() end
            return
        end

        local cam = workspace.CurrentCamera
        local vel = Vector3.new()

        if keys.W then vel = vel + cam.CFrame.LookVector * flySpeed end
        if keys.S then vel = vel - cam.CFrame.LookVector * flySpeed end
        if keys.A then vel = vel - cam.CFrame.RightVector * flySpeed end
        if keys.D then vel = vel + cam.CFrame.RightVector * flySpeed end
        if keys.Up then vel = vel + Vector3.new(0, flySpeed, 0) end
        if keys.Down then vel = vel - Vector3.new(0, flySpeed, 0) end

        bv.Velocity = vel
        bg.CFrame = cam.CFrame
    end)
end

local function stopFly()
    if flyConnection then
        flyConnection:Disconnect()
        flyConnection = nil
    end

    local char = LocalPlayer.Character
    if char then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp then
            for _, obj in ipairs(hrp:GetChildren()) do
                if obj:IsA("BodyGyro") or obj:IsA("BodyVelocity") then
                    obj:Destroy()
                end
            end
        end
    end
end

flyHit.MouseButton1Click:Connect(function()
    flyEnabled = not flyEnabled
    flyPill.BackgroundColor3 = flyEnabled and C.on or C.off
    flyKnob.Position         = flyEnabled and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
    flyKnob.BackgroundColor3 = flyEnabled and C.knobOn or C.knobOff

    if flyEnabled then
        startFly()
    else
        stopFly()
    end
end)
end -- fim do bloco Fly Mode

print("Painel System Farm carregado.")
