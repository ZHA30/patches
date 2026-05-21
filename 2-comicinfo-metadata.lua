-- ComicInfo.xml metadata auto-extraction for CBZ/CBR files.
-- Intercepts FileManagerBookInfo metadata waterfall at two points:
--   1) extendProps() — lazy sidecar population for all consumers
--   2) getDocProps()  — pre-flight to skip MuPDF document open

local Archiver = require("ffi/archiver")
local DocSettings = require("docsettings")
local logger = require("logger")
local util = require("util")

local COMIC_EXTS = { cbz = true, cbr = true }

local function isComicFile(filepath)
    if not filepath then return false end
    local ext = util.getFileNameSuffix(filepath):lower()
    return COMIC_EXTS[ext] == true
end

local function warn(msg, ...)
    logger.warn("ComicInfo:", msg, ...)
end

local function hasData(items)
    return type(items) == "table" and next(items) ~= nil
end

local function parseComicInfoXML(xml_str)
    if not xml_str or xml_str == "" then return nil end
    xml_str = xml_str:gsub("^\xef\xbb\xbf", "", 1)

    local data = {}
    -- Extract simple text elements: <Tag opt_attrs>plain_text</Tag>
    for tag, content in xml_str:gmatch("<([%w_:]+)[^>]*>([^<]*)</%1>") do
        if content ~= "" and data[tag] == nil then
            data[tag] = content
        end
    end
    if not next(data) then return nil end
    return data
end

local function extractComicInfo(filepath)
    local arc = Archiver.Reader:new()
    if not arc:open(filepath) then
        warn("failed to open archive:", filepath, arc.err)
        return nil
    end

    local xml_path
    for entry in arc:iterate() do
        if entry.mode == "file" then
            local base = entry.path:match("([^/]+)$"):lower()
            if base == "comicinfo.xml" or base == "comicinfo" then
                xml_path = entry.path
                break
            end
        end
    end

    if not xml_path then
        arc:close()
        warn("no ComicInfo.xml found in:", filepath)
        return nil
    end

    local xml_str = arc:extractToMemory(xml_path)
    arc:close()

    if not xml_str then
        warn("failed to read ComicInfo.xml from:", xml_path)
        return nil
    end

    local comic_data = parseComicInfoXML(xml_str)
    if not comic_data then
        warn("failed to parse ComicInfo.xml in:", filepath)
        return nil
    end

    local metadata = {
        title = comic_data.Title,
        authors = comic_data.Writer,
        series = comic_data.Series,
        series_index = tonumber(comic_data.Number),
        description = comic_data.Summary,
        keywords = comic_data.Tags or comic_data.Genre,
        language = comic_data.LanguageISO,
        pages = tonumber(comic_data.PageCount),
    }

    for k, v in pairs(metadata) do
        if v and type(v) == "string" then
            metadata[k] = util.htmlEntitiesToUtf8(util.trim(v))
        end
    end

    if metadata.keywords then
        local tags = util.splitToArray(metadata.keywords, ",", false)
        for i, tag in ipairs(tags) do
            tags[i] = util.trim(tag)
        end
        metadata.keywords = table.concat(tags, "\n")
    end

    return metadata
end

local function splitMetadata(metadata)
    if type(metadata) ~= "table" then return nil end
    local custom_props = {}
    for key, value in pairs(metadata) do
        if key ~= "pages" and value ~= nil and value ~= "" then
            custom_props[key] = value
        end
    end
    local doc_props
    if metadata.pages then
        doc_props = { pages = metadata.pages }
    end
    if not hasData(custom_props) and not doc_props then return nil end
    return custom_props, doc_props
end

local function removeEmptyComicMetadata(custom_mf)
    local settings = DocSettings.openSettingsFile(custom_mf)
    if hasData(settings:readSetting("custom_props")) or hasData(settings:readSetting("doc_props")) then
        return false
    end
    os.remove(custom_mf)
    DocSettings.removeSidecarDir(util.splitFilePathName(custom_mf))
    return true
end

local function migrateCachedPages(custom_mf, filepath, custom_props, doc_props)
    if type(custom_props) ~= "table" or custom_props.pages == nil then
        return custom_props, doc_props
    end

    doc_props = type(doc_props) == "table" and doc_props or {}
    doc_props.pages = doc_props.pages or custom_props.pages
    custom_props.pages = nil

    local settings = DocSettings.openSettingsFile(custom_mf)
    settings:saveSetting("doc_props", doc_props)
    settings:saveSetting("custom_props", custom_props)
    settings:flushCustomMetadata(filepath)
    return custom_props, doc_props
end

local function saveComicMetadata(filepath, metadata, custom_mf)
    local custom_props, doc_props_update = splitMetadata(metadata)
    if not custom_props then return false end

    local custom_settings = DocSettings.openSettingsFile(custom_mf)
    local doc_props = custom_settings:readSetting("doc_props") or {}
    if doc_props_update then
        for key, value in pairs(doc_props_update) do
            doc_props[key] = value
        end
    end
    custom_settings:saveSetting("doc_props", doc_props)
    custom_settings:saveSetting("custom_props", custom_props)
    custom_settings:flushCustomMetadata(filepath)
    return true
end

local function ensureComicMetadataCached(filepath)
    local custom_mf = DocSettings:findCustomMetadataFile(filepath)
    if custom_mf then
        local settings = DocSettings.openSettingsFile(custom_mf)
        local custom_props = settings:readSetting("custom_props")
        local doc_props = settings:readSetting("doc_props")
        custom_props, doc_props = migrateCachedPages(custom_mf, filepath, custom_props, doc_props)
        if hasData(custom_props) or hasData(doc_props) then
            return true -- already cached with valid data
        end
        -- Previous versions could leave an empty cache that shadows KOReader's native metadata path.
        removeEmptyComicMetadata(custom_mf)
        custom_mf = nil
    end
    local meta = extractComicInfo(filepath)
    return saveComicMetadata(filepath, meta, custom_mf)
end

-- Monkey-patch FileManagerBookInfo
do
    local ok, FileManagerBookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
    if not ok or not FileManagerBookInfo then return end

    local orig_extendProps = FileManagerBookInfo.extendProps
    FileManagerBookInfo.extendProps = function(original_props, filepath)
        if filepath and isComicFile(filepath) then
            ensureComicMetadataCached(filepath)
        end
        return orig_extendProps(original_props, filepath)
    end

    local orig_getDocProps = FileManagerBookInfo.getDocProps
    function FileManagerBookInfo:getDocProps(file, book_props, no_open_document)
        if not book_props and not no_open_document and isComicFile(file) then
            ensureComicMetadataCached(file)
        end
        return orig_getDocProps(self, file, book_props, no_open_document)
    end
end
