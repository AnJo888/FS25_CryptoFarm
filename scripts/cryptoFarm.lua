--[[
    cryptoFarm.lua

    Lógica central do mod "crypto Farm":
    - Saldo em uma unidade fictícia (CFC = crypto Farm Coin), SEPARADO
      POR FAZENDA (self.balances[farmId]) - pronto pra multiplayer, já
      que no FS25 todos os jogadores compartilham o mesmo savegame
      (não existe "arquivo por jogador"), então indexamos por farmId
      dentro do mesmo save.
    - Cotação flutuante (random walk, atualizada a cada dia in-game),
      compartilhada entre todas as fazendas
    - Taxa de transação em depósitos/saques
    - Saque respeita o teto de dinheiro da fazenda (999.999.999)
    - Persistência no savegame (XML)

    LIMITAÇÃO CONHECIDA (multiplayer de verdade, não testado):
    Isso resolve o saldo estar correto POR FAZENDA dentro do save.
    NÃO implementa sincronização de rede em tempo real entre clientes
    conectados simultaneamente (se dois jogadores humanos diferentes
    usarem o ATM ao mesmo tempo, cada máquina tem sua própria cópia de
    g_cryptoFarm em memória - sincronizar isso via rede exigiria Events
    customizados, que não foram implementados ainda).

    AVISO PRA VOCÊ (AnJo888):
    Algumas chamadas de API abaixo (g_currentMission:getMoney,
    g_currentMission:addMoney) seguem o padrão que mods de dinheiro/
    economia da comunidade costumam usar, mas eu não tenho como
    confirmar 100% a assinatura exata dessas funções na versão atual do
    FS25 sem testar no jogo. Se der erro no log.txt ao carregar o save,
    me manda a mensagem de erro que a gente ajusta a chamada certa.

    ATUALIZACAO: o save/load NAO usa mais hook em FSCareerMissionInfo
    (confirmado, via testes extensivos, que esse hook nunca disparava).
    Agora usamos um arquivo XML proprio (CryptoFarm.xml, dentro da
    pasta do savegame), lido/escrito diretamente por nos - ver
    getSaveFilePath/saveToDisk/loadFromDisk mais abaixo. Padrao
    confirmado no codigo real do Courseplay.
]]

cryptoFarm = {}
local cryptoFarm_mt = Class(cryptoFarm)

-- Formata um numero com separador de milhares (ex: 1234567.89 ->
-- "1,234,567.89"). E literalmente a piada do mod: o jogo trava o
-- dinheiro em 999.999.999 pra nunca deixar o jogador entrar no
-- "clube das tres virgulas" - entao aqui, no Crypto Farm, a gente
-- mostra as virgulas com orgulho.
local function formatWithThousands(value)
    local formatted = string.format("%.2f", value or 0)
    local sign, intPart, decPart = formatted:match("^(-?)(%d+)%.(%d+)$")
    if intPart == nil then
        return formatted
    end

    local reversed = intPart:reverse()
    local withSep = reversed:gsub("(%d%d%d)", "%1,")
    withSep = withSep:reverse()
    withSep = withSep:gsub("^,", "")

    return sign .. withSep .. "." .. decPart
end

-- IMPORTANTE: g_currentModDirectory só é válido aqui no topo do arquivo
-- (no momento em que o mod carrega este script), não dentro de funções
-- chamadas depois, tipo loadMap() - por isso capturamos e guardamos.
local modDirectory = g_currentModDirectory
local kaChingSample = nil

cryptoFarm.MIN_RATE = 0.5          -- cotação mínima (1 CFC = $0,50)
cryptoFarm.MAX_RATE = 2.5          -- cotação máxima (1 CFC = $2,50)
cryptoFarm.RATE_STEP = 0.31        -- variação máxima por dia in-game (random walk)
cryptoFarm.DEFAULT_FEE = 0.02      -- taxa padrão (2%), usada se o xml não configurar nada
cryptoFarm.DEFAULT_MAX_FEE_AMOUNT = 200000  -- teto padrão da taxa, em $, se o xml não configurar
cryptoFarm.MONEY_CAP = 999999999   -- teto de dinheiro do FS25

function cryptoFarm.new()
    local self = setmetatable({}, cryptoFarm_mt)
    self.balances = {}   -- saldo em CFC, POR FAZENDA: self.balances[farmId] = valor
    self.rate = 1.0      -- 1 CFC = self.rate em dinheiro do jogo (compartilhado entre fazendas)
    self.buyFee = cryptoFarm.DEFAULT_FEE   -- taxa ao comprar/depositar (configurável via xml)
    self.sellFee = cryptoFarm.DEFAULT_FEE  -- taxa ao vender/sacar (configurável via xml)
    self.maxFeeAmount = cryptoFarm.DEFAULT_MAX_FEE_AMOUNT  -- teto absoluto da taxa, em $ (configurável via xml)
    return self
end

--- Le o saldo em CFC de uma fazenda especifica (0 se nunca usou o ATM)
function cryptoFarm:getBalance(farmId)
    return self.balances[farmId] or 0
end

function cryptoFarm:setBalance(farmId, value)
    self.balances[farmId] = value
end

-- Chamado pelo cryptoFarmATM:onLoad com os valores lidos do cryptoFarmATM.xml
function cryptoFarm:setFees(buyFee, sellFee, maxFeeAmount)
    if buyFee ~= nil then
        self.buyFee = buyFee
    end
    if sellFee ~= nil then
        self.sellFee = sellFee
    end
    if maxFeeAmount ~= nil then
        self.maxFeeAmount = maxFeeAmount
    end
end

-- Toca o som de "ka-ching" (chamar apos compra/venda concluida com
-- valor > 0).
function cryptoFarm:playKaChing()
    if kaChingSample ~= nil then
        g_soundManager:playSample(kaChingSample)
    end
end

function cryptoFarm:loadMap()
    self:loadFromDisk()

    -- Carrega a GUI do dialogo do ATM (uma vez, ao iniciar o mapa)
    if g_gui ~= nil and g_gui.guis["CryptoFarmDialog"] == nil then
        g_gui:loadGui(modDirectory .. "gui/CryptoFarmDialog.xml", "CryptoFarmDialog", CryptoFarmDialog.new())
    end

    -- Som de "ka-ching" (2D, sem posicao no mundo - independente de
    -- qualquer node do i3d, e do som nativo do proprio ATM que toca
    -- sozinho na construcao). Carregado uma vez, tocado a cada
    -- compra/venda concluida com valor > 0.
    if kaChingSample == nil then
        local soundsDir = modDirectory .. "sounds/"
        local soundXmlHandle = loadXMLFile("cryptoFarmSounds", soundsDir .. "sounds.xml")
        if soundXmlHandle ~= nil and soundXmlHandle ~= 0 then
            kaChingSample = g_soundManager:loadSample2DFromXML(soundXmlHandle, "sounds", "kaChing", soundsDir, 1, AudioGroup.GUI)
            delete(soundXmlHandle)
        else
            Logging.warning("[cryptoFarm] Nao consegui abrir sounds/sounds.xml pra carregar o som.")
        end
    end

    -- Removido: addDayChangeListener nao existe (confirmado por erro em
    -- jogo). A cotacao agora e atualizada via cryptoFarmATM, que checa a
    -- mudanca de dia periodicamente dentro do proprio update() do
    -- placeable - um callback que sabemos que existe de verdade.

    -- Comandos de console pra testar antes do caixa eletrônico 3D existir.
    -- No console do jogo (tecla ~ ou conforme configurado):
    --   cfSaldo
    --   cfDepositar 50000
    --   cfSacar 1000        (valor em CFC, não em dinheiro)
    addConsoleCommand("cfSaldo", "Mostra saldo e cotação do crypto Farm", "consoleCommandSaldo", self)
    addConsoleCommand("cfDepositar", "Deposita dinheiro no crypto Farm (cfDepositar <valor em $>)", "consoleCommandDepositar", self)
    addConsoleCommand("cfSacar", "Saca do crypto Farm (cfSacar <valor em CFC>)", "consoleCommandSacar", self)
end

function cryptoFarm:deleteMap()
    removeConsoleCommand("cfSaldo")
    removeConsoleCommand("cfDepositar")
    removeConsoleCommand("cfSacar")
end

-- Chamado automaticamente pelo jogo a cada virada de dia in-game
function cryptoFarm:dayChanged()
    local delta = (math.random() * 2 - 1) * cryptoFarm.RATE_STEP
    local newRate = self.rate + delta

    if newRate < cryptoFarm.MIN_RATE then
        newRate = cryptoFarm.MIN_RATE
    elseif newRate > cryptoFarm.MAX_RATE then
        newRate = cryptoFarm.MAX_RATE
    end

    self.rate = newRate
end

-- Retorna o farmId do contexto atual (jogador/console que chamou a acao)
function cryptoFarm:getFarmId()
    return g_currentMission:getFarmId()
end

function cryptoFarm:getFarmMoney(farmId)
    -- Ponto de ajuste: dependendo da versão do FS25, pode ser
    -- g_currentMission:getMoney(farmId) ou g_farmManager:getFarmById(farmId).money
    return g_currentMission:getMoney(farmId)
end

--- Deposita dinheiro real da fazenda no saldo crypto Farm
-- @param amount valor em dinheiro do jogo a depositar
-- @param farmId opcional - fazenda a creditar (default: fazenda atual)
-- @return sucesso (bool), coinsRecebidas ou mensagem de erro
function cryptoFarm:deposit(amount, farmId)
    if amount == nil or amount <= 0 then
        return false, "Valor inválido"
    end

    farmId = farmId or self:getFarmId()
    local farmMoney = self:getFarmMoney(farmId)

    if amount > farmMoney then
        return false, "Saldo insuficiente na conta da fazenda"
    end

    local fee = math.min(amount * self.buyFee, self.maxFeeAmount)
    local netAmount = amount - fee
    local coinsReceived = netAmount / self.rate

    g_currentMission:addMoney(-amount, farmId, MoneyType.OTHER, true, true)
    self:setBalance(farmId, self:getBalance(farmId) + coinsReceived)
    self:saveToDisk()

    return true, coinsReceived
end

--- Saca do saldo crypto Farm de volta pra conta da fazenda,
--- respeitando o teto de 999.999.999
-- @param coinAmount valor em CFC a sacar
-- @param farmId opcional - fazenda a debitar (default: fazenda atual)
-- @return sucesso (bool), valorCreditado ou mensagem de erro, foiParcial (bool)
function cryptoFarm:withdraw(coinAmount, farmId)
    farmId = farmId or self:getFarmId()
    local currentBalance = self:getBalance(farmId)

    if coinAmount == nil or coinAmount <= 0 or coinAmount > currentBalance then
        return false, "Saldo crypto insuficiente"
    end

    local farmMoney = self:getFarmMoney(farmId)

    local grossMoney = coinAmount * self.rate
    local fee = math.min(grossMoney * self.sellFee, self.maxFeeAmount)
    local netMoney = grossMoney - fee

    local espacoDisponivel = cryptoFarm.MONEY_CAP - farmMoney

    if espacoDisponivel <= 0 then
        return false, "A conta da fazenda já está no limite máximo (999.999.999)"
    end

    if netMoney > espacoDisponivel then
        -- Saca só o que cabe; o resto continua guardado em CFC.
        -- Recalcula a taxa proporcional ao valor bruto necessário pra
        -- gerar exatamente "espacoDisponivel" líquido, respeitando o
        -- mesmo teto configuravel (self.maxFeeAmount).
        local moneyToAdd = espacoDisponivel
        local grossNeeded = moneyToAdd + math.min(moneyToAdd * self.sellFee, self.maxFeeAmount)
        -- pequeno ajuste iterativo simples, já que o teto pode mudar o
        -- resultado da taxa dependendo do valor bruto calculado
        local feeOnGrossNeeded = math.min(grossNeeded * self.sellFee, self.maxFeeAmount)
        grossNeeded = moneyToAdd + feeOnGrossNeeded
        local coinsUsed = grossNeeded / self.rate

        self:setBalance(farmId, currentBalance - coinsUsed)
        g_currentMission:addMoney(moneyToAdd, farmId, MoneyType.OTHER, true, true)
        self:saveToDisk()

        return true, moneyToAdd, true
    end

    self:setBalance(farmId, currentBalance - coinAmount)
    g_currentMission:addMoney(netMoney, farmId, MoneyType.OTHER, true, true)
    self:saveToDisk()

    return true, netMoney, false
end

-- ===================== Mapa do menu do caixa eletronico (GUI futura) =====================
--[[
    Tela do terminal "crypto Farm" (ver mockup do Blender):
        1 - Buy crypto    -> cryptoFarm:deposit(amount)
        2 - Sell crypto   -> cryptoFarm:withdraw(coinAmount)
        3 - Balance       -> cryptoFarm:consoleCommandSaldo() (texto por enquanto)
        4 - Exit          -> so fecha a GUI, sem chamada de logica de jogo

    (Removido "Transfer": era so um placeholder da imagem do mockup,
    nao existe como opcao real no menu.)
]]

-- ===================== Comandos de console (temporários) =====================

function cryptoFarm:consoleCommandSaldo()
    local farmId = self:getFarmId()
    local balance = self:getBalance(farmId)
    return string.format(
        "Saldo crypto Farm (fazenda %s): %.2f CFC | Cotacao atual: 1 CFC = $%.2f | Equivalente: $%.2f",
        tostring(farmId), balance, self.rate, balance * self.rate
    )
end

-- Igual ao consoleCommandSaldo, mas quebrado em varias linhas - usado
-- na GUI, onde uma linha unica longa fica cortada/dificil de ler.
-- Exposto publicamente pra outros arquivos (GUI) formatarem valores
-- com o mesmo separador de milhares.
function cryptoFarm:formatMoney(value)
    return formatWithThousands(value)
end

function cryptoFarm:getBalanceMultilineText()
    local farmId = self:getFarmId()
    local balance = self:getBalance(farmId)
    local farmMoney = self:getFarmMoney(farmId)
    return string.format(
        "Fazenda: %s\nSaldo em conta: $%s\nSaldo Crypto: %s CFC\nCotacao: 1 CFC = $%s\nEquivalente: $%s",
        tostring(farmId), formatWithThousands(farmMoney), formatWithThousands(balance),
        formatWithThousands(self.rate), formatWithThousands(balance * self.rate)
    )
end

function cryptoFarm:consoleCommandDepositar(amountStr)
    local amount = tonumber(amountStr)
    if amount == nil then
        return "Uso: cfDepositar <valor em dinheiro>"
    end

    local ok, result = self:deposit(amount)
    if ok then
        local feeCharged = math.min(amount * self.buyFee, self.maxFeeAmount)
        return string.format(
            "Depositado! Voce recebeu %.2f CFC (taxa cobrada: $%.2f, cotacao 1 CFC = $%.2f)",
            result, feeCharged, self.rate
        )
    end
    return "Erro: " .. tostring(result)
end

function cryptoFarm:consoleCommandSacar(amountStr)
    local amount = tonumber(amountStr)
    if amount == nil then
        return "Uso: cfSacar <valor em CFC>"
    end

    local ok, result, partial = self:withdraw(amount)
    if ok then
        local grossMoney = amount * self.rate
        local feeCharged = math.min(grossMoney * self.sellFee, self.maxFeeAmount)
        if partial then
            return string.format(
                "Saque parcial: $%.2f creditados (limite da conta atingido). O restante ficou guardado em CFC.",
                result
            )
        end
        return string.format(
            "Sacado! Voce recebeu $%.2f (taxa cobrada: $%.2f)",
            result, feeCharged
        )
    end
    return "Erro: " .. tostring(result)
end

-- ===================== Persistência no savegame =====================

-- ===================== Persistencia em arquivo PROPRIO =====================
--[[
    MUDANCA IMPORTANTE: abandonamos o hook em FSCareerMissionInfo
    (nunca disparava - confirmado por testes extensivos). Agora seguimos
    o padrao real do Courseplay: um arquivo XML PROPRIO
    ("CryptoFarm.xml"), dentro da propria pasta do savegame
    (missionInfo.savegameDirectory), lido/escrito por nos mesmos,
    sem depender de nenhum hook do jogo pra save/load.

    Vantagem extra: como salvamos direto apos cada deposito/saque (nao
    so quando o jogo salva), os dados nunca ficam desatualizados mesmo
    que o jogo feche sem salvar formalmente.
]]

function cryptoFarm:getSaveFilePath()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return nil
    end
    local dir = g_currentMission.missionInfo.savegameDirectory
    if dir == nil then
        return nil
    end
    return dir .. "/CryptoFarm.xml"
end

function cryptoFarm:saveToDisk()
    local filePath = self:getSaveFilePath()
    if filePath == nil then
        Logging.warning("[cryptoFarm] saveToDisk: savegameDirectory indisponivel, nao salvou.")
        return
    end

    local xmlHandle = createXMLFile("cryptoFarmSave", filePath, "cryptoFarm")
    if xmlHandle == nil or xmlHandle == 0 then
        Logging.warning("[cryptoFarm] saveToDisk: nao consegui criar %s", filePath)
        return
    end

    setXMLFloat(xmlHandle, "cryptoFarm#rate", self.rate)

    local index = 0
    for farmId, balance in pairs(self.balances) do
        local farmKey = string.format("cryptoFarm.farm(%d)", index)
        setXMLInt(xmlHandle, farmKey .. "#id", farmId)
        setXMLFloat(xmlHandle, farmKey .. "#balance", balance)
        index = index + 1
    end

    saveXMLFile(xmlHandle)
    delete(xmlHandle)
end

function cryptoFarm:loadFromDisk()
    local filePath = self:getSaveFilePath()
    if filePath == nil then
        return
    end

    if not fileExists(filePath) then
        self:migrateFromOldCareerSavegame()
        return
    end

    local xmlHandle = loadXMLFile("cryptoFarmSave", filePath)
    if xmlHandle == nil or xmlHandle == 0 then
        Logging.warning("[cryptoFarm] loadFromDisk: nao consegui abrir %s", filePath)
        return
    end

    self.rate = getXMLFloat(xmlHandle, "cryptoFarm#rate") or 1.0

    self.balances = {}
    local index = 0
    while true do
        local farmKey = string.format("cryptoFarm.farm(%d)", index)
        if not hasXMLProperty(xmlHandle, farmKey .. "#id") then
            break
        end

        local farmId = getXMLInt(xmlHandle, farmKey .. "#id")
        local balance = getXMLFloat(xmlHandle, farmKey .. "#balance")

        if farmId ~= nil and balance ~= nil then
            self.balances[farmId] = balance
        end

        index = index + 1
    end

    delete(xmlHandle)
end

-- Migracao unica: busca saldo salvo pelo sistema ANTIGO (hook em
-- FSCareerMissionInfo, dentro do proprio careerSavegame.xml) - usado
-- so na primeira carga apos a troca pro arquivo proprio, pra nao
-- perder saldo que ja existia. Se achar algo, salva ja no formato novo.
function cryptoFarm:migrateFromOldCareerSavegame()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return
    end
    local dir = g_currentMission.missionInfo.savegameDirectory
    if dir == nil then
        return
    end

    local oldPath = dir .. "/careerSavegame.xml"
    if not fileExists(oldPath) then
        return
    end

    local xmlHandle = loadXMLFile("cryptoFarmOldSave", oldPath)
    if xmlHandle == nil or xmlHandle == 0 then
        return
    end

    local key = "careerSavegame.cryptoFarm"
    local foundAny = false

    local rate = getXMLFloat(xmlHandle, key .. "#rate")
    if rate ~= nil then
        self.rate = rate
    end

    local index = 0
    while true do
        local farmKey = string.format("%s.farm(%d)", key, index)
        if not hasXMLProperty(xmlHandle, farmKey .. "#id") then
            break
        end

        local farmId = getXMLInt(xmlHandle, farmKey .. "#id")
        local balance = getXMLFloat(xmlHandle, farmKey .. "#balance")

        if farmId ~= nil and balance ~= nil then
            self.balances[farmId] = balance
            foundAny = true
            Logging.warning("[cryptoFarm] Migrado do careerSavegame.xml antigo: fazenda %s = %s CFC", tostring(farmId), tostring(balance))
        end

        index = index + 1
    end

    delete(xmlHandle)

    if foundAny then
        self:saveToDisk()
    end
end

-- ===================== Registro do mod =====================

g_cryptoFarm = cryptoFarm.new()
addModEventListener(g_cryptoFarm)

-- Salva sempre que o jogo salva (rede de seguranca extra - o principal
-- e salvar direto apos cada deposito/saque, ver deposit()/withdraw()).
-- Padrao confirmado no Courseplay: FSBaseMission.saveSavegame.
FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, function(...)
    g_cryptoFarm:saveToDisk()
end)
