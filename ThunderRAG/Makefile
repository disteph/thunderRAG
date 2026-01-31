XPI_NAME ?= thunderRAG.xpi

STAGE_DIR := build/xpi
DIST_DIR := dist

XPI_SOURCES := $(shell find manifest.json background.js experiments ui icons -type f -print 2>/dev/null)

.PHONY: xpi clean

xpi: $(DIST_DIR)/$(XPI_NAME)

$(DIST_DIR)/$(XPI_NAME): $(XPI_SOURCES)
	@rm -rf "$(STAGE_DIR)"
	@mkdir -p "$(STAGE_DIR)" "$(DIST_DIR)"
	@cp manifest.json "$(STAGE_DIR)/"
	@cp background.js "$(STAGE_DIR)/"
	@cp -R experiments "$(STAGE_DIR)/"
	@cp -R ui "$(STAGE_DIR)/"
	@cp -R icons "$(STAGE_DIR)/"
	@rm -f "$(DIST_DIR)/$(XPI_NAME)"
	@(cd "$(STAGE_DIR)" && zip -r -X "../../$(DIST_DIR)/$(XPI_NAME)" . -x "*.DS_Store" "__MACOSX/*")

clean:
	@rm -rf build dist
