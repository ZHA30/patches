local _ = require("gettext")
local NOOP = function() return true end
local TRANSLATE = _("Translate")
local TRANSLATION_SETTINGS = _("Translation settings")

local function removeArrayValue(items, value)
    if type(items) ~= "table" then
        return false
    end
    local changed = false
    for i = #items, 1, -1 do
        if items[i] == value then
            table.remove(items, i)
            changed = true
        end
    end
    return changed
end

local function removeNestedArrayValue(items, value)
    if type(items) ~= "table" then
        return false
    end
    local changed = false
    for i = #items, 1, -1 do
        local row = items[i]
        if type(row) == "table" then
            changed = removeArrayValue(row, value) or changed
            if #row == 0 then
                table.remove(items, i)
                changed = true
            end
        end
    end
    return changed
end

local function removeMenuEntriesByText(items, banned)
    if type(items) ~= "table" then
        return false
    end
    local changed = false
    for i = #items, 1, -1 do
        local item = items[i]
        if type(item) == "table" then
            if banned[item.text] then
                table.remove(items, i)
                changed = true
            else
                changed = removeMenuEntriesByText(item.sub_item_table, banned) or changed
            end
        end
    end
    return changed
end

local function removeButtonEntriesByText(rows, banned)
    if type(rows) ~= "table" then
        return false
    end
    local changed = false
    for i = #rows, 1, -1 do
        local row = rows[i]
        if type(row) == "table" then
            for j = #row, 1, -1 do
                local button = row[j]
                if type(button) == "table" and banned[button.text] then
                    table.remove(row, j)
                    changed = true
                end
            end
            if #row == 0 then
                table.remove(rows, i)
                changed = true
            end
        end
    end
    return changed
end

local function sanitizeDictButtonConfig(config)
    if type(config) ~= "table" then
        return config, false
    end
    local changed = false
    if type(config.layout) == "table" then
        local before = #config.layout
        removeNestedArrayValue(config.layout, "translate")
        changed = changed or #config.layout ~= before
    end
    if type(config.order) == "table" then
        local before = #config.order
        removeArrayValue(config.order, "translate")
        changed = changed or #config.order ~= before
    end
    return config, changed
end

do
    local ok, Dispatcher = pcall(require, "dispatcher")
    if ok and Dispatcher and Dispatcher.removeAction then
        Dispatcher:removeAction("translate_page")
    end
end

do
    local ok, Translator = pcall(require, "ui/translator")
    if ok and Translator then
        Translator.showTranslation = NOOP
        Translator._showTranslation = NOOP
        Translator.translate = NOOP
        Translator.loadPage = NOOP
        Translator.detect = function() return nil end
        Translator.getTransServer = NOOP
        Translator.getLanguageName = NOOP
        Translator.getDocumentLanguage = NOOP
        Translator.getSourceLanguage = NOOP
        Translator.getTargetLanguage = NOOP
        Translator.genSettingsMenu = NOOP
    end
end

do
    local ok, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
    if ok and ReaderHighlight then
        local init_orig = ReaderHighlight.init
        ReaderHighlight.init = function(self, ...)
            local result = init_orig(self, ...)
            if type(self._highlight_buttons) == "table" then
                self._highlight_buttons["07_translate"] = nil
            end
            return result
        end

        local addToMainMenu_orig = ReaderHighlight.addToMainMenu
        ReaderHighlight.addToMainMenu = function(self, menu_items, ...)
            local result = addToMainMenu_orig(self, menu_items, ...)
            local banned = {
                [TRANSLATE] = true,
                [TRANSLATION_SETTINGS] = true,
            }
            removeMenuEntriesByText(menu_items.long_press and menu_items.long_press.sub_item_table, banned)
            removeMenuEntriesByText(menu_items.selection_text and menu_items.selection_text.sub_item_table, banned)
            menu_items.translation_settings = nil
            menu_items.translate_current_page = nil
            return result
        end

        ReaderHighlight.translate = NOOP
        ReaderHighlight.onTranslateText = NOOP
        ReaderHighlight.onTranslateCurrentPage = NOOP

        local onTap_orig = ReaderHighlight.onTap
        if onTap_orig then
            ReaderHighlight.onTap = function(self, ...)
                if G_reader_settings:readSetting("default_highlight_action", "ask") == "translate" then
                    G_reader_settings:saveSetting("default_highlight_action", "ask")
                end
                return onTap_orig(self, ...)
            end
        end
    end
end

do
    local ok, DictQuickLookup = pcall(require, "ui/widget/dictquicklookup")
    if ok and DictQuickLookup then
        local getButtonPool_orig = DictQuickLookup._getButtonPool
        DictQuickLookup._getButtonPool = function(self, ...)
            local pool = getButtonPool_orig(self, ...)
            pool.translate = nil
            return pool
        end

        local lookupInputWord_orig = DictQuickLookup.lookupInputWord
        DictQuickLookup.lookupInputWord = function(self, ...)
            local result = lookupInputWord_orig(self, ...)
            local dialog = self.input_dialog
            if dialog then
                local changed = removeButtonEntriesByText(dialog.buttons, {
                    [TRANSLATE] = true,
                })
                if type(dialog._buttons_backup) == "table" then
                    removeButtonEntriesByText(dialog._buttons_backup, {
                        [TRANSLATE] = true,
                    })
                end
                if changed then
                    dialog:reinit()
                end
            end
            return result
        end
    end
end

do
    local ok, ButtonTable = pcall(require, "ui/widget/buttontable")
    if ok and ButtonTable then
        local init_orig = ButtonTable.init
        ButtonTable.init = function(self, ...)
            if self.show_parent and self.show_parent.title == _("Enter a word or phrase to look up") then
                removeButtonEntriesByText(self.buttons, {
                    [TRANSLATE] = true,
                })
            end
            return init_orig(self, ...)
        end
    end
end

do
    local ok, ReaderDictionary = pcall(require, "apps/reader/modules/readerdictionary")
    if ok and ReaderDictionary then
        local init_orig = ReaderDictionary.init
        ReaderDictionary.init = function(self, ...)
            local result = init_orig(self, ...)
            removeNestedArrayValue(self.default_layout, "translate")
            local config = G_reader_settings:readSetting("dict_button_config")
            local changed
            config, changed = sanitizeDictButtonConfig(config)
            if changed then
                G_reader_settings:saveSetting("dict_button_config", config)
            end
            return result
        end

        local genCustomizeButtonsMenu_orig = ReaderDictionary._genCustomizeButtonsMenu
        if genCustomizeButtonsMenu_orig then
            ReaderDictionary._genCustomizeButtonsMenu = function(self, ...)
                local menu = genCustomizeButtonsMenu_orig(self, ...)
                removeMenuEntriesByText(menu, {
                    [TRANSLATE] = true,
                })
                return menu
            end
        end
    end
end
