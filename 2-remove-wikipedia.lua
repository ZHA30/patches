local function removeArrayValue(items, value)
    if type(items) ~= "table" then
        return
    end
    for i = #items, 1, -1 do
        if items[i] == value then
            table.remove(items, i)
        end
    end
end

local function nilIfMatches(value, target)
    if value == target then
        return nil
    end
    return value
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
        ReaderWikipedia.lookupInput = function() return true end
        ReaderWikipedia.onShowWikipediaLookup = function() return true end
        ReaderWikipedia.onLookupWikipedia = function() return true end
        ReaderWikipedia.lookupWikipedia = function() return true end
        ReaderWikipedia.getWikiLanguages = function(self)
            local lang = self and self.wiki_last_language or nil
            return {}, lang
        end
        ReaderWikipedia.setLastSelectedLanguage = function() return true end
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
    local ok, DictQuickLookup = pcall(require, "ui/widget/dictquicklookup")
    if ok and DictQuickLookup then
        local Presets = require("ui/presets")
        local ButtonDialog = require("ui/widget/buttondialog")
        local InputDialog = require("ui/widget/inputdialog")
        local Event = require("ui/event")
        local UIManager = require("ui/uimanager")
        local _ = require("gettext")

        local getButtonPool_orig = DictQuickLookup._getButtonPool
        DictQuickLookup._getButtonPool = function(self, ...)
            local pool = getButtonPool_orig(self, ...)
            pool.wikipedia = nil
            return pool
        end

        DictQuickLookup.lookupWikipedia = function() return true end

        DictQuickLookup.lookupInputWord = function(self, hint)
            local buttons = {
                {
                    {
                        text = _("Translate"),
                        callback = function()
                            local text = self.input_dialog:getInputText()
                            if text ~= "" then
                                UIManager:close(self.input_dialog)
                                require("ui/translator"):showTranslation(text, true)
                            end
                        end,
                    },
                },
                {
                    {
                        text = _("Find in definition"),
                        enabled_func = function()
                            return self.is_html and self.shw_widget
                        end,
                        callback = function()
                            local text = self.input_dialog:getInputText()
                            if text ~= "" and not text:match("^%s*$") then
                                UIManager:close(self.input_dialog)
                                self:searchInDefinition(text)
                            end
                        end,
                    },
                },
                {
                    {
                        text = _("Cancel"),
                        id = "close",
                        callback = function()
                            UIManager:close(self.input_dialog)
                        end,
                    },
                    {
                        text = _("Search dictionary"),
                        is_enter_default = true,
                        callback = function()
                            local text = self.input_dialog:getInputText()
                            if text ~= "" then
                                UIManager:close(self.input_dialog)
                                self.is_wiki = false
                                self.ui:handleEvent(Event:new("LookupWord", text, true))
                            end
                        end,
                    },
                },
            }

            local preset_names = Presets.getPresets(self.ui.dictionary.preset_obj)
            if preset_names and #preset_names > 0 then
                table.insert(buttons[2], {
                    text = _("Search with preset"),
                    callback = function()
                        local text = self.input_dialog:getInputText()
                        if text == "" or text:match("^%s*$") then
                            return
                        end
                        local current_dict_state = self.ui.dictionary:buildPreset()
                        local button_dialog
                        local dialog_buttons = {}
                        for _, preset_name in ipairs(preset_names) do
                            table.insert(dialog_buttons, {
                                {
                                    align = "left",
                                    text = preset_name,
                                    callback = function()
                                        self.ui.dictionary:loadPreset(self.ui.dictionary.preset_obj.presets[preset_name], true)
                                        UIManager:close(button_dialog)
                                        UIManager:close(self.input_dialog)
                                        self.ui:handleEvent(Event:new("LookupWord", text, true, nil, nil, nil, function()
                                            self.ui.dictionary:loadPreset(current_dict_state, true)
                                        end))
                                    end,
                                },
                            })
                        end
                        button_dialog = ButtonDialog:new{
                            buttons = dialog_buttons,
                            shrink_unneeded_width = true,
                        }
                        self.input_dialog:onCloseKeyboard()
                        UIManager:show(button_dialog)
                    end,
                })
            end

            self.is_wiki = false
            self.input_dialog = InputDialog:new{
                title = _("Enter a word or phrase to look up"),
                input = hint,
                input_hint = hint,
                buttons = buttons,
            }
            UIManager:show(self.input_dialog)
            self.input_dialog:onShowKeyboard()
        end

        local lookupDictionaryOrWikipedia_orig = DictQuickLookup.lookupDictionaryOrWikipedia
        DictQuickLookup.lookupDictionaryOrWikipedia = function(self, selected_text, switch_domain, ...)
            if switch_domain and self.is_wiki then
                self.is_wiki = false
            end
            return lookupDictionaryOrWikipedia_orig(self, selected_text, false, ...)
        end

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
