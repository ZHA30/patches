local ok
local ButtonDialog
local InfoMessage
local NetworkMgr
local TextViewer
local Trapper
local UIManager
local ffiUtil
local lfs
local url
local util
local _

ok, ButtonDialog = pcall(require, "ui/widget/buttondialog")
if not ok or not ButtonDialog then return end
ok, InfoMessage = pcall(require, "ui/widget/infomessage")
if not ok or not InfoMessage then return end
ok, NetworkMgr = pcall(require, "ui/network/manager")
if not ok or not NetworkMgr then return end
ok, TextViewer = pcall(require, "ui/widget/textviewer")
if not ok or not TextViewer then return end
ok, Trapper = pcall(require, "ui/trapper")
if not ok or not Trapper then return end
ok, UIManager = pcall(require, "ui/uimanager")
if not ok or not UIManager then return end
ok, ffiUtil = pcall(require, "ffi/util")
if not ok or not ffiUtil then return end
ok, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok or not lfs then return end
ok, url = pcall(require, "socket.url")
if not ok or not url then return end
ok, util = pcall(require, "util")
if not ok or not util then return end
ok, _ = pcall(require, "gettext")
if not ok or not _ then return end
local T = ffiUtil.template
local N_ = _.ngettext

---
--- Patch i18n: inject translations directly into KOReader's gettext table.
---
local PATCH_I18N = {
    zh_CN = {
        ["Download this catalog"] = "下载此目录",
        ["Force download this catalog"] = "强制下载此目录",
        ["Downloading… (%1/%2, tap to cancel)"] = "正在下载…（%1/%2，点按以取消）",
        ["Download already in progress"] = "下载已在进行中",
    },
    zh_TW = {
        ["Download this catalog"] = "下載此目錄",
        ["Force download this catalog"] = "強制下載此目錄",
        ["Downloading… (%1/%2, tap to cancel)"] = "下載中…（%1/%2，點按以取消）",
        ["Download already in progress"] = "下載已在進行中",
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
        if self.opds_download_in_progress then
            UIManager:show(InfoMessage:new{ text = _("Download already in progress") })
            return
        end

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

    --- Replace sync download to update file-level progress in the cancel dialog.
    function OPDSBrowser:downloadPendingSyncs()
        if self.opds_download_in_progress then
            UIManager:show(InfoMessage:new{ text = _("Download already in progress") })
            return
        end

        self.opds_download_in_progress = true
        local dl_list = self.pending_syncs

        local function finishDownload()
            self.opds_download_in_progress = nil
        end

        local function getDownloadPlan()
            local active_items = {}
            local duplicate_list = {}
            for _, item in ipairs(dl_list) do
                if self.sync_server_list[item.catalog] then
                    if lfs.attributes(item.file) and not self.sync_force then
                        table.insert(duplicate_list, item)
                    else
                        table.insert(active_items, item)
                    end
                end
            end
            return active_items, duplicate_list
        end

        local function dismissable_download()
            local active_items, duplicate_list = getDownloadPlan()
            local downloaded = {}
            local canceled_file
            local total_count = #active_items

            for idx, item in ipairs(active_items) do
                local completed, ok_download = Trapper:dismissableRunInSubprocess(function()
                    return self:downloadFile(item.file, item.url, item.username, item.password)
                end, T(_("Downloading… (%1/%2, tap to cancel)"), idx, total_count))

                if not completed then
                    canceled_file = item.file
                    break
                end
                if ok_download then
                    downloaded[item.file] = true
                end
            end

            local dl_count = 0
            local dl_size = #dl_list
            for i = dl_size, 1, -1 do
                local item = dl_list[i]
                if downloaded[item.file] then
                    dl_count = dl_count + 1
                    table.remove(dl_list, i)
                elseif canceled_file then
                    if item.file == canceled_file and lfs.attributes(item.file) then
                        os.remove(item.file)
                    end
                else
                    local attr = lfs.attributes(item.file)
                    if attr then
                        if attr.size > 0 then
                            table.remove(dl_list, i)
                            if attr.modification > os.time() - 300 then
                                dl_count = dl_count + 1
                            end
                        else
                            os.remove(item.file)
                        end
                    end
                end
            end

            if canceled_file then
                self._manager.updated = true
                return
            end

            local duplicate_count = duplicate_list and #duplicate_list or 0
            dl_count = math.max(0, dl_count - duplicate_count)
            local timeout = duplicate_count > 0 and 3 or nil
            if dl_count > 0 then
                UIManager:show(InfoMessage:new{
                    text = T(N_("1 book downloaded", "%1 books downloaded", dl_count), dl_count),
                    timeout = timeout,
                })
            end
            self._manager.updated = true
            return duplicate_list
        end

        local ok_download_batch, duplicate_list = pcall(dismissable_download)
        if not ok_download_batch then
            finishDownload()
            error(duplicate_list)
        end

        if duplicate_list and #duplicate_list > 0 then
            finishDownload()

            local textviewer
            local duplicate_files = { _("These files are already on the device:") }
            for _, entry in ipairs(duplicate_list) do
                table.insert(duplicate_files, entry.file)
            end
            local text = table.concat(duplicate_files, "\n")
            textviewer = TextViewer:new{
                title = _("Duplicate files"),
                text = text,
                buttons_table = {
                    {
                        {
                            text = _("Do nothing"),
                            callback = function()
                                textviewer:onClose()
                            end
                        },
                        {
                            text = _("Overwrite"),
                            callback = function()
                                self.sync_force = true
                                textviewer:onClose()
                                for _, entry in ipairs(duplicate_list) do
                                    table.insert(dl_list, entry)
                                end
                                self.opds_download_in_progress = true
                                Trapper:wrap(function()
                                    local ok_dup_batch, err = pcall(dismissable_download)
                                    finishDownload()
                                    if not ok_dup_batch then
                                        error(err)
                                    end
                                end)
                            end
                        },
                        {
                            text = _("Download copies"),
                            callback = function()
                                self.sync_force = true
                                textviewer:onClose()
                                local copy_download_dir, original_dir, copies_dir, copy_download_path
                                copies_dir = "copies"
                                original_dir = util.splitFilePathName(duplicate_list[1].file)
                                copy_download_dir = original_dir .. copies_dir .. "/"
                                util.makePath(copy_download_dir)
                                for _, entry in ipairs(duplicate_list) do
                                    local _, file_name = util.splitFilePathName(entry.file)
                                    copy_download_path = copy_download_dir .. file_name
                                    entry.file = copy_download_path
                                    table.insert(dl_list, entry)
                                end
                                self.opds_download_in_progress = true
                                Trapper:wrap(function()
                                    local ok_dup_batch, err = pcall(dismissable_download)
                                    finishDownload()
                                    if not ok_dup_batch then
                                        error(err)
                                    end
                                end)
                            end
                        },
                    },
                },
            }
            UIManager:show(textviewer)
        else
            finishDownload()
        end
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
