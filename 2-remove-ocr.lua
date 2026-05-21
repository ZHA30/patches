local NO_OCR_RESULT = function() return nil end

local function removeOptionByName(options, name)
    if type(options) ~= "table" then
        return
    end
    for i = #options, 1, -1 do
        if type(options[i]) == "table" and options[i].name == name then
            table.remove(options, i)
        end
    end
end

do
    local ok, Dispatcher = pcall(require, "dispatcher")
    if ok and Dispatcher and Dispatcher.removeAction then
        Dispatcher:removeAction("kopt_forced_ocr")
    end
end

do
    local ok, OCR = pcall(require, "ui/data/ocr")
    if ok and OCR then
        OCR.getOCRLangs = function() return {} end
    end
end

do
    local ok, KoptInterface = pcall(require, "document/koptinterface")
    if ok and KoptInterface then
        KoptInterface.getOCRWord = NO_OCR_RESULT
        KoptInterface.getReflewOCRWord = NO_OCR_RESULT
        KoptInterface.getNativeOCRWord = NO_OCR_RESULT
        KoptInterface.getOCRText = NO_OCR_RESULT
        KoptInterface.ocrengine = nil
        KoptInterface.tessocr_data = nil
        KoptInterface.ocr_lang = nil
    end
end

do
    local ok, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
    if ok and ReaderHighlight then
        local lookupDictWord_orig = ReaderHighlight.lookupDictWord
        ReaderHighlight.lookupDictWord = function(self)
            if #self.selected_text.text == 0 and self.selected_text.sboxes then
                return
            end
            return lookupDictWord_orig(self)
        end

        local translate_orig = ReaderHighlight.translate
        ReaderHighlight.translate = function(self, index)
            if #self.selected_text.text == 0 and self.hold_pos then
                return
            end
            return translate_orig(self, index)
        end
    end
end

do
    local ok, KoptOptions = pcall(require, "ui/data/koptoptions")
    if ok and KoptOptions then
        for _, panel in ipairs(KoptOptions) do
            if type(panel) == "table" and panel.options then
                removeOptionByName(panel.options, "forced_ocr")
            end
        end
    end
end
