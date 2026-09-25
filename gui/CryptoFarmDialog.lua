-- CryptoFarmDialog.lua
-- Dialogo simples do ATM: mostra saldo/cotacao e tem botoes de acao.
-- Baseado no padrao real confirmado em NumericInputDialog.lua (mod
-- FS25_BankCredit) - estende MessageDialog, que ja vem com toda a
-- infraestrutura de abrir/fechar dialogo.

CryptoFarmDialog = {}
local CryptoFarmDialog_mt = Class(CryptoFarmDialog, MessageDialog)

CryptoFarmDialog.CONTROLS = {
    "balanceText",
    "amountInput",
}

function CryptoFarmDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or CryptoFarmDialog_mt)
    return self
end

function CryptoFarmDialog:onLoad()
    CryptoFarmDialog:superClass().onLoad(self)
    self:registerControls(CryptoFarmDialog.CONTROLS)
end

function CryptoFarmDialog:onOpen()
    CryptoFarmDialog:superClass().onOpen(self)
    self:refreshBalanceText()
    if self.amountInput ~= nil then
        self.amountInput:setText("1000000")
    end
end

-- Rastreiam se o campo de valor esta em foco, pra Backspace so vender
-- quando o jogador NAO estiver editando o campo (senao o Backspace
-- precisa continuar apagando digito, como esperado).
-- Metodo OFICIAL do GuiElement (confirmado na documentacao da GDN) pra
-- capturar acoes de input enquanto o dialogo esta em foco.
function CryptoFarmDialog:inputEvent(actionName, inputValue, eventUsed)
    eventUsed = CryptoFarmDialog:superClass().inputEvent(self, actionName, inputValue, eventUsed)

    if not eventUsed then
        if actionName == InputAction.MENU_ACCEPT then
            self:onClickBuy()
            eventUsed = true
        end
    end

    return eventUsed
end

function CryptoFarmDialog:onInputTextChanged(element, text)
    local filtered = string.gsub(text or "", "[^0-9]", "")
    if filtered ~= text then
        element:setText(filtered)
    end
end

function CryptoFarmDialog:getEnteredAmount()
    local raw = self.amountInput ~= nil and self.amountInput:getText() or nil
    local value = tonumber(raw)
    if value == nil or value <= 0 then
        return nil
    end
    return value
end

function CryptoFarmDialog:refreshBalanceText()
    if self.balanceText ~= nil and g_cryptoFarm ~= nil then
        self.balanceText:setText(g_cryptoFarm:getBalanceMultilineText())
    end
end

function CryptoFarmDialog:onClickBuy()
    local amount = self:getEnteredAmount()
    if amount == nil then
        if g_currentMission ~= nil then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_FAILED, "Valor invalido")
        end
        return
    end

    if g_cryptoFarm ~= nil then
        local ok, result = g_cryptoFarm:deposit(amount)
        if ok then
            if result > 0 then
                g_cryptoFarm:playKaChing()
            end
            if g_currentMission ~= nil then
                g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
                    string.format("Comprado! +%s CFC", g_cryptoFarm:formatMoney(result)))
            end
        else
            if g_currentMission ~= nil then
                g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_FAILED,
                    tostring(result))
            end
        end
    end
    self:refreshBalanceText()
end

function CryptoFarmDialog:onClickSell()
    local amount = self:getEnteredAmount()
    if amount == nil then
        if g_currentMission ~= nil then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_FAILED, "Valor invalido")
        end
        return
    end

    if g_cryptoFarm ~= nil then
        local ok, result, partial = g_cryptoFarm:withdraw(amount)
        if ok then
            if result > 0 then
                g_cryptoFarm:playKaChing()
            end
            if g_currentMission ~= nil then
                g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
                    string.format("Vendido! +$%s%s", g_cryptoFarm:formatMoney(result), partial and " (parcial)" or ""))
            end
        else
            if g_currentMission ~= nil then
                g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_FAILED,
                    tostring(result))
            end
        end
    end
    self:refreshBalanceText()
end

function CryptoFarmDialog:onClickClose()
    self:close()
end

-- Chamada de fora (cryptoFarmATM.lua) pra abrir o dialogo
function CryptoFarmDialog.show()
    g_gui:showDialog("CryptoFarmDialog")
end
