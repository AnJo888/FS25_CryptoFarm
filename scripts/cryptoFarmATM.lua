--[[
    cryptoFarmATM.lua

    MODELO: especializacao propria (nao hooking).

    Registrada via placeableSpecializations/placeableTypes no modDesc.xml.
    O motor chama nossas funcoes automaticamente SO para placeables do
    tipo "cryptoFarmATM" - nao precisamos filtrar entre todos os
    placeables do mapa como fazíamos no modelo de hooking.

    IMPORTANTE: isto e uma TABELA SIMPLES (mixin), NAO uma classe OOP.
    Nunca chamar Class(cryptoFarmATM, Placeable) aqui - foi essa linha
    que causava o bug de "Event already registered" quando tentamos
    isso a primeira vez. Todas as funcoes abaixo sao registradas pelo
    TypeManager via registerFunctions/registerEventListeners.
]]

cryptoFarmATM = {}

function cryptoFarmATM.prerequisitesPresent(specializations)
    return true
end

function cryptoFarmATM.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(placeableType, "updateNightLight", cryptoFarmATM.updateNightLight)
    SpecializationUtil.registerFunction(placeableType, "triggerCallback", cryptoFarmATM.triggerCallback)
    SpecializationUtil.registerFunction(placeableType, "getIsActivatable", cryptoFarmATM.getIsActivatable)
    SpecializationUtil.registerFunction(placeableType, "getActivateText", cryptoFarmATM.getActivateText)
    SpecializationUtil.registerFunction(placeableType, "onActivateObject", cryptoFarmATM.onActivateObject)
    SpecializationUtil.registerFunction(placeableType, "run", cryptoFarmATM.onActivateObject)
    SpecializationUtil.registerFunction(placeableType, "openCryptoFarmMenu", cryptoFarmATM.openCryptoFarmMenu)
    SpecializationUtil.registerFunction(placeableType, "periodicCheck", cryptoFarmATM.periodicCheck)
end

function cryptoFarmATM.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", cryptoFarmATM)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", cryptoFarmATM)
    SpecializationUtil.registerEventListener(placeableType, "onUpdate", cryptoFarmATM)
end

function cryptoFarmATM:onLoad(savegame)
    self.spec_cryptoFarmATM = self.spec_cryptoFarmATM or {}
    local spec = self.spec_cryptoFarmATM

    local configPath = self.configFileName
    if configPath ~= nil then
        local xmlHandle = loadXMLFile("cryptoFarmATMConfig", configPath)
        if xmlHandle ~= nil and xmlHandle ~= 0 then
            local lightNodeName = getXMLString(xmlHandle, "placeable.cryptoFarmATM.lightNode#node")
            local triggerNodeName = getXMLString(xmlHandle, "placeable.cryptoFarmATM.triggerNode#node")

            spec.hourOn = getXMLFloat(xmlHandle, "placeable.cryptoFarmATM.nightLight#hourOn") or 18
            spec.hourOff = getXMLFloat(xmlHandle, "placeable.cryptoFarmATM.nightLight#hourOff") or 6

            local buyFee = getXMLFloat(xmlHandle, "placeable.cryptoFarmATM.economy#buyFee")
            local sellFee = getXMLFloat(xmlHandle, "placeable.cryptoFarmATM.economy#sellFee")
            local maxFeeAmount = getXMLFloat(xmlHandle, "placeable.cryptoFarmATM.economy#maxFeeAmount")

            if g_cryptoFarm ~= nil then
                g_cryptoFarm:setFees(buyFee, sellFee, maxFeeAmount)
            end

            if lightNodeName ~= nil and self.components ~= nil then
                spec.lightNode = I3DUtil.indexToObject(self.components, lightNodeName, self.i3dMappings)
            end

            if triggerNodeName ~= nil and self.components ~= nil then
                spec.triggerNode = I3DUtil.indexToObject(self.components, triggerNodeName, self.i3dMappings)
            end

            delete(xmlHandle)
        else
            Logging.warning("[cryptoFarmATM] Nao consegui abrir '%s' pra ler a configuracao.", tostring(configPath))
        end
    end

    if spec.lightNode == nil then
        Logging.warning("[cryptoFarmATM] Node de luz nao encontrado - luz noturna desativada.")
    end

    if spec.triggerNode == nil then
        Logging.warning("[cryptoFarmATM] Node de trigger nao encontrado - interacao desativada.")
    else
        addTrigger(spec.triggerNode, "triggerCallback", self)
    end

    spec.isPlayerInRange = false
    spec.timeSinceCheck = 0
    spec.lastCheckedDay = nil

    self.activateText = self:getActivateText()

    self:updateNightLight()
end

function cryptoFarmATM:onDelete()
    local spec = self.spec_cryptoFarmATM
    if spec == nil then
        return
    end

    if spec.triggerNode ~= nil then
        removeTrigger(spec.triggerNode)
    end

    if spec.isPlayerInRange and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self)
    end
end

function cryptoFarmATM:onUpdate(dt)
    self:periodicCheck(dt)
end

-- Checagem periodica (a cada ~5s) em vez de um listener de evento de dia/hora
function cryptoFarmATM:periodicCheck(dt)
    local spec = self.spec_cryptoFarmATM
    if spec == nil then
        return
    end

    spec.timeSinceCheck = (spec.timeSinceCheck or 0) + (dt or 0)
    if spec.timeSinceCheck < 5000 then
        return
    end
    spec.timeSinceCheck = 0

    self:updateNightLight()

    if g_currentMission ~= nil and g_currentMission.environment ~= nil then
        local currentDay = g_currentMission.environment.currentDay
        if currentDay ~= nil and currentDay ~= spec.lastCheckedDay then
            spec.lastCheckedDay = currentDay
            if g_cryptoFarm ~= nil then
                g_cryptoFarm:dayChanged()
            end
        end
    end
end

function cryptoFarmATM:updateNightLight()
    local spec = self.spec_cryptoFarmATM
    if spec == nil or spec.lightNode == nil or g_currentMission == nil or g_currentMission.environment == nil then
        return
    end

    local hour = g_currentMission.environment.currentHour
    local isOn = (hour >= spec.hourOn) or (hour < spec.hourOff)

    setVisibility(spec.lightNode, isOn)
end

function cryptoFarmATM:triggerCallback(triggerId, otherId, onEnter, onLeave, onStay)
    local spec = self.spec_cryptoFarmATM
    if spec == nil then
        return
    end

    if g_localPlayer == nil or otherId ~= g_localPlayer.rootNode then
        return
    end

    if onEnter then
        spec.isPlayerInRange = true
        self.activateText = self:getActivateText()
        if g_currentMission.activatableObjectsSystem ~= nil then
            g_currentMission.activatableObjectsSystem:addActivatable(self)
        end
    elseif onLeave then
        spec.isPlayerInRange = false
        if g_currentMission.activatableObjectsSystem ~= nil then
            g_currentMission.activatableObjectsSystem:removeActivatable(self)
        end
    end
end

function cryptoFarmATM:getIsActivatable()
    local spec = self.spec_cryptoFarmATM
    return spec ~= nil and spec.isPlayerInRange == true
end

function cryptoFarmATM:getActivateText()
    return "Crypto Farm (Buy / Sell / Balance)"
end

function cryptoFarmATM:onActivateObject()
    self:openCryptoFarmMenu()
end

function cryptoFarmATM:openCryptoFarmMenu()
    if CryptoFarmDialog ~= nil then
        CryptoFarmDialog.show()
    else
        Logging.warning("[cryptoFarmATM] CryptoFarmDialog nao esta disponivel ainda.")
    end
end
