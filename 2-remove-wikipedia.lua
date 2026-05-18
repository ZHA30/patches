local _ = require("gettext")
local NOOP = function() return true end
local WIKIPEDIA = _("Wikipedia")
local WIKIPEDIA_SETTINGS = _("Wikipedia settings")
local SEARCH_WIKIPEDIA = _("Search Wikipedia")

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

local function nilIfMatches(value, target)
    if value == target then
        return nil
    end
    return value
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

local function removeButtonEntriesById(rows, target_id)
    if type(rows) ~= "table" then
        return false
    end
    local changed = false
    for i = #rows, 1, -1 do
        local row = rows[i]
        if type(row) == "table" then
            for j = #row, 1, -1 do
                local button = row[j]
                if type(button) == "table" and button.id == target_id then
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
        removeNestedArrayValue(config.layout, "wikipedia")
        changed = changed or #config.layout ~= before
    end
    if type(config.order) == "table" then
        local before = #config.order
        removeArrayValue(config.order, "wikipedia")
        changed = changed or #config.order ~= before
    end
    return config, changed
end

do
    local ok, Dispatcher = pcall(require, "dispatcher")
    if ok and Dispatcher and Dispatcher.removeAction then
        Dispatcher:removeAction("wikipedia_lookup")
    end
end

do
    local ok, FileManagerShortcuts = pcall(require, "apps/filemanager/filemanagershortcuts")
    if ok and FileManagerShortcuts then
        local providers = FileManagerShortcuts.providers
        local provider_props = FileManagerShortcuts.provider_props
        local had_provider = type(provider_props) == "table" and provider_props.wikipedia_save_dir ~= nil

        removeArrayValue(providers, "wikipedia_save_dir")
        if type(provider_props) == "table" then
            provider_props.wikipedia_save_dir = nil
        end
        if had_provider and type(FileManagerShortcuts.providers_nb) == "number"
                and FileManagerShortcuts.providers_nb > 0 then
            FileManagerShortcuts.providers_nb = FileManagerShortcuts.providers_nb - 1
        end
    end
end

do
    local ok, ReaderWikipedia = pcall(require, "apps/reader/modules/readerwikipedia")
    if ok and ReaderWikipedia then
        ReaderWikipedia.addToMainMenu = function() end
        ReaderWikipedia.lookupInput = NOOP
        ReaderWikipedia.onShowWikipediaLookup = NOOP
        ReaderWikipedia.onLookupWikipedia = NOOP
        ReaderWikipedia.lookupWikipedia = NOOP
        ReaderWikipedia.getWikiLanguages = function(self)
            local lang = self and self.wiki_last_language or nil
            return {}, lang
        end
        ReaderWikipedia.setLastSelectedLanguage = NOOP
    end
end

do
    local ok, ReaderDictionary = pcall(require, "apps/reader/modules/readerdictionary")
    if ok and ReaderDictionary then
        local init_orig = ReaderDictionary.init
        ReaderDictionary.init = function(self, ...)
            local result = init_orig(self, ...)
            removeNestedArrayValue(self.default_layout, "wikipedia")
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
                    [WIKIPEDIA] = true,
                })
                return menu
            end
        end
    end
end

do
    local ok, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
    if ok and ReaderHighlight then
        local init_orig = ReaderHighlight.init
        ReaderHighlight.init = function(self, ...)
            local result = init_orig(self, ...)
            if type(self._highlight_buttons) == "table" then
                self._highlight_buttons["05_wikipedia"] = nil
            end
            return result
        end

        local addToMainMenu_orig = ReaderHighlight.addToMainMenu
        ReaderHighlight.addToMainMenu = function(self, menu_items, ...)
            local result = addToMainMenu_orig(self, menu_items, ...)
            local banned = {
                [WIKIPEDIA] = true,
                [WIKIPEDIA_SETTINGS] = true,
            }
            removeMenuEntriesByText(menu_items.long_press and menu_items.long_press.sub_item_table, banned)
            removeMenuEntriesByText(menu_items.selection_text and menu_items.selection_text.sub_item_table, banned)
            menu_items.wikipedia_settings = nil
            return result
        end

        ReaderHighlight.lookupWikipedia = NOOP

        local onTap_orig = ReaderHighlight.onTap
        if onTap_orig then
            ReaderHighlight.onTap = function(self, ...)
                if G_reader_settings:readSetting("default_highlight_action", "ask") == "wikipedia" then
                    G_reader_settings:saveSetting("default_highlight_action", "ask")
                end
                return onTap_orig(self, ...)
            end
        end
    end
end

do
    local ok, ReaderLink = pcall(require, "apps/reader/modules/readerlink")
    if ok and ReaderLink then
        local init_orig = ReaderLink.init
        ReaderLink.init = function(self, ...)
            local result = init_orig(self, ...)
            if self._external_link_buttons then
                self._external_link_buttons["40_wiki_lookup"] = nil
                self._external_link_buttons["45_wiki_saved"] = nil
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
            if self.show_parent then
                if self.show_parent.lookupword ~= nil then
                    removeButtonEntriesById(self.buttons, "wikipedia")
                elseif self.show_parent.title == _("Enter a word or phrase to look up") then
                    removeButtonEntriesByText(self.buttons, {
                        [SEARCH_WIKIPEDIA] = true,
                    })
                end
            end
            return init_orig(self, ...)
        end
    end
end

do
    local ok, DictQuickLookup = pcall(require, "ui/widget/dictquicklookup")
    if ok and DictQuickLookup then
        local getButtonPool_orig = DictQuickLookup._getButtonPool
        DictQuickLookup._getButtonPool = function(self, ...)
            local pool = getButtonPool_orig(self, ...)
            pool.wikipedia = nil
            return pool
        end

        DictQuickLookup.lookupWikipedia = NOOP

        local lookupInputWord_orig = DictQuickLookup.lookupInputWord
        DictQuickLookup.lookupInputWord = function(self, ...)
            local result = lookupInputWord_orig(self, ...)
            self.is_wiki = false
            local dialog = self.input_dialog
            if dialog then
                local changed = removeButtonEntriesByText(dialog.buttons, {
                    [SEARCH_WIKIPEDIA] = true,
                })
                if type(dialog._buttons_backup) == "table" then
                    removeButtonEntriesByText(dialog._buttons_backup, {
                        [SEARCH_WIKIPEDIA] = true,
                    })
                end
                if changed then
                    dialog:reinit()
                end
            end
            return result
        end

        local lookupDictionaryOrWikipedia_orig = DictQuickLookup.lookupDictionaryOrWikipedia
        DictQuickLookup.lookupDictionaryOrWikipedia = function(self, selected_text, _, ...)
            self.is_wiki = false
            return lookupDictionaryOrWikipedia_orig(self, selected_text, false, ...)
        end

        local changeDictionary_orig = DictQuickLookup.changeDictionary
        if changeDictionary_orig then
            DictQuickLookup.changeDictionary = function(self, index, skip_update, ...)
                local result = changeDictionary_orig(self, index, skip_update, ...)
                self.is_wiki = false
                if self.results then
                    for _, result_item in ipairs(self.results) do
                        result_item.is_wiki_fullpage = nilIfMatches(result_item.is_wiki_fullpage, true)
                    end
                end
                return result
            end
        end
    end
end
