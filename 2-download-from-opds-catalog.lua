local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local url = require("socket.url")
local _ = require("gettext")
local T = ffiUtil.template

---
--- Patch i18n: inject translations directly into KOReader's gettext table.
--- Add translations for your language below.
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
    -- Try exact "zh_CN", then prefix "zh", then fallback to nil
    local t = PATCH_I18N[lang] or PATCH_I18N[lang:match("^(..)")]
    if t then
        for k, v in pairs(t) do
            _.translation[k] = v
        end
    end
end

patchInjectTranslations()

-- Re-inject after language switch
local changeLang_orig = _.changeLang
_.changeLang = function(new_lang)
    local result = changeLang_orig(new_lang)
    patchInjectTranslations()
    return result
end

local ok, OPDSBrowser = pcall(require, "opdsbrowser")
if not ok then return end

---
--- Build a one-shot server entry from the current path and trigger
--- download via the existing fillPendingSyncs + downloadPendingSyncs pipeline.
---
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

    -- Reset server list so we only download from the current catalog
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

---
--- Simple download menu for catalogs that don't have facets or search.
--- Replaces the direct addSubCatalog call from updateCatalog's else branch.
---
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

---
--- Replace showFacetMenu to append download options.
--- The original builds a local buttons table; we can't inject into it,
--- so we rebuild the menu including the original content plus our additions.
---
OPDSBrowser.showFacetMenu = function(self)
    local buttons = {}
    local dialog
    local catalog_url = self.paths[#self.paths].url

    -- Add sub-catalog option (same as original)
    table.insert(buttons, {{
        text = "\u{f067} " .. _("Add catalog"),
        callback = function()
            UIManager:close(dialog)
            self:addSubCatalog(catalog_url)
        end,
        align = "left",
    }})
    table.insert(buttons, {})

    -- Search option (same as original)
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

    -- Facet groups (same as original)
    if self.facet_groups then
        for group_name, facets in ffiUtil.orderedPairs(self.facet_groups) do
            table.insert(buttons, {
                { text = "\u{f0b0} " .. group_name, enabled = false, align = "left" }
            })
            for __, link in ipairs(facets) do
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

    -- Download options (new)
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

---
--- Intercept updateCatalog so that catalogs without facets also show a menu
--- instead of directly calling addSubCatalog.
---
local updateCatalog_orig = OPDSBrowser.updateCatalog
OPDSBrowser.updateCatalog = function(self, item_url, paths_updated)
    updateCatalog_orig(self, item_url, paths_updated)

    if #self.paths > 0 and not self.facet_groups and not self.search_url then
        self.onLeftButtonTap = function()
            self:showCatalogDownloadMenu(item_url)
        end
    end
end
