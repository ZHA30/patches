local ok
local ButtonDialog
local InfoMessage
local NetworkMgr
local Trapper
local UIManager
local ffiUtil
local url
local _

ok, ButtonDialog = pcall(require, "ui/widget/buttondialog")
if not ok or not ButtonDialog then return end
ok, InfoMessage = pcall(require, "ui/widget/infomessage")
if not ok or not InfoMessage then return end
ok, NetworkMgr = pcall(require, "ui/network/manager")
if not ok or not NetworkMgr then return end
ok, Trapper = pcall(require, "ui/trapper")
if not ok or not Trapper then return end
ok, UIManager = pcall(require, "ui/uimanager")
if not ok or not UIManager then return end
ok, ffiUtil = pcall(require, "ffi/util")
if not ok or not ffiUtil then return end
ok, url = pcall(require, "socket.url")
if not ok or not url then return end
ok, _ = pcall(require, "gettext")
if not ok or not _ then return end
local T = ffiUtil.template

---
--- Patch i18n: inject translations directly into KOReader's gettext table.
---
local PATCH_I18N = {
    zh_CN = {
        ["Download this catalog"] = "下载此目录",
        ["Force download this catalog"] = "强制下载此目录",
    },
    zh_TW = {
        ["Download this catalog"] = "下載此目錄",
        ["Force download this catalog"] = "強制下載此目錄",
    },
}

local function patchInjectTranslations()
    local lang = _.current_lang
    local t = PATCH_I18N[lang] or PATCH_I18N[lang:match("^(..)")]
    if t then
        for k, v in pairs(t) do
            _.translation[k] = v
        end
    end
end

patchInjectTranslations()

local changeLang_orig = _.changeLang
_.changeLang = function(new_lang)
    local result = changeLang_orig(new_lang)
    patchInjectTranslations()
    return result
end

---
--- Use registerPatchPluginFunc to run after the OPDS plugin is loaded,
--- guaranteeing the plugin dir is in package.path before we require opdsbrowser.
---
local userpatch = require("userpatch")

userpatch.registerPatchPluginFunc("opds", function(plugin)
    if plugin.patched_download_catalog then return end
    plugin.patched_download_catalog = true

    local OPDSBrowser = require("opdsbrowser")

    --- Build a one-shot server entry from the current path and trigger
    --- download via the existing fillPendingSyncs + downloadPendingSyncs pipeline.
    function OPDSBrowser:downloadCurrentCatalog()
        if not self.settings.sync_dir then
            UIManager:show(InfoMessage:new{
                text = _("Please choose a folder for sync downloads first"),
            })
            return
        end

        self.sync = true

        local path = self.paths[#self.paths]
        local temp_server = {
            title     = path.title or self.catalog_title,
            url       = path.url,
            username  = self.root_catalog_username,
            password  = self.root_catalog_password,
            raw_names = self.root_catalog_raw_names,
        }

        self.sync_server_list = {}

        local info = InfoMessage:new{ text = _("Synchronizing lists…") }
        UIManager:show(info)
        UIManager:forceRePaint()

        self:fillPendingSyncs(temp_server)

        UIManager:close(info)

        if #self.pending_syncs > 0 then
            Trapper:wrap(function()
                self:downloadPendingSyncs()
            end)
        else
            UIManager:show(InfoMessage:new{ text = _("Up to date!") })
        end
        self.sync = false
    end

    --- Simple download menu for catalogs that don't have facets or search.
    function OPDSBrowser:showCatalogDownloadMenu(item_url)
        local dialog
        local buttons = {
            {{
                text = "\u{f067} " .. _("Add catalog"),
                callback = function()
                    UIManager:close(dialog)
                    self:addSubCatalog(item_url)
                end,
                align = "left",
            }},
            {},
            {{
                text = "\u{f019} " .. _("Download this catalog"),
                callback = function()
                    UIManager:close(dialog)
                    NetworkMgr:runWhenConnected(function()
                        self.sync_force = false
                        self:downloadCurrentCatalog()
                    end)
                end,
                align = "left",
            }},
            {{
                text = "\u{f019} " .. _("Force download this catalog"),
                callback = function()
                    UIManager:close(dialog)
                    NetworkMgr:runWhenConnected(function()
                        self.sync_force = true
                        self:downloadCurrentCatalog()
                    end)
                end,
                align = "left",
            }},
        }
        dialog = ButtonDialog:new{
            buttons = buttons,
            shrink_unneeded_width = true,
            anchor = function()
                return self.title_bar.left_button.image.dimen
            end,
        }
        UIManager:show(dialog)
    end

    --- Replace showFacetMenu to append download options.
    OPDSBrowser.showFacetMenu = function(self)
        local buttons = {}
        local dialog
        local catalog_url = self.paths[#self.paths].url

        table.insert(buttons, {{
            text = "\u{f067} " .. _("Add catalog"),
            callback = function()
                UIManager:close(dialog)
                self:addSubCatalog(catalog_url)
            end,
            align = "left",
        }})
        table.insert(buttons, {})

        if self.search_url then
            table.insert(buttons, {{
                text = "\u{f002} " .. _("Search"),
                callback = function()
                    UIManager:close(dialog)
                    self:searchCatalog(self.search_url)
                end,
                align = "left",
            }})
            table.insert(buttons, {})
        end

        if self.facet_groups then
            for group_name, facets in ffiUtil.orderedPairs(self.facet_groups) do
                table.insert(buttons, {
                    { text = "\u{f0b0} " .. group_name, enabled = false, align = "left" }
                })
                for link_pos = 1, #facets do
                    local link = facets[link_pos]
                    local facet_text = link.title
                    if link["thr:count"] then
                        facet_text = T(_("%1 (%2)"), facet_text, link["thr:count"])
                    end
                    if link["opds:activeFacet"] == "true" then
                        facet_text = "✓ " .. facet_text
                    end
                    table.insert(buttons, {{
                        text = facet_text,
                        callback = function()
                            UIManager:close(dialog)
                            self:updateCatalog(url.absolute(catalog_url, link.href))
                        end,
                        align = "left",
                    }})
                end
                table.insert(buttons, {})
            end
        end

        table.insert(buttons, {{
            text = "\u{f019} " .. _("Download this catalog"),
            callback = function()
                UIManager:close(dialog)
                NetworkMgr:runWhenConnected(function()
                    self.sync_force = false
                    self:downloadCurrentCatalog()
                end)
            end,
            align = "left",
        }})
        table.insert(buttons, {{
            text = "\u{f019} " .. _("Force download this catalog"),
            callback = function()
                UIManager:close(dialog)
                NetworkMgr:runWhenConnected(function()
                    self.sync_force = true
                    self:downloadCurrentCatalog()
                end)
            end,
            align = "left",
        }})

        dialog = ButtonDialog:new{
            buttons = buttons,
            shrink_unneeded_width = true,
            anchor = function()
                return self.title_bar.left_button.image.dimen
            end,
        }
        UIManager:show(dialog)
    end

    --- Replace updateCatalog to show download menu for catalogs without facets.
    OPDSBrowser.updateCatalog = function(self, item_url, paths_updated)
        local menu_table = self:genItemTableFromURL(item_url)
        if #menu_table > 0 or self.facet_groups or self.search_url then
            if not paths_updated then
                table.insert(self.paths, {
                    url   = item_url,
                    title = self.catalog_title,
                })
            end
            self:switchItemTable(self.catalog_title, menu_table)

            if self.facet_groups or self.search_url then
                self:setTitleBarLeftIcon("appbar.menu")
                self.onLeftButtonTap = function()
                    self:showFacetMenu()
                end
            else
                self:setTitleBarLeftIcon("plus")
                self.onLeftButtonTap = function()
                    self:showCatalogDownloadMenu(item_url)
                end
            end

            if self.page_num <= 1 then
                self:onNextPage(true)
            end
        end
    end
end)
