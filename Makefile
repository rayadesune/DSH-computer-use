SHELL := /bin/bash

BIN        ?= dsh-ui
DEST       ?= $(HOME)/.local/bin
SKILL_DEST ?= $(HOME)/.dsh/skills/dsh-macos-ui

.PHONY: help build install test sync-skill clean

help:
	@echo "make build       编译到 ./dsh-ui"
	@echo "make install     编译并安装到 $$DEST"
	@echo "make test        冒烟测试"
	@echo "make sync-skill  把 skill/SKILL.md 同步到 $$SKILL_DEST"
	@echo "make clean       清理构建产物"

build:
	@swiftc -O dsh-ui.swift -o $(BIN)
	@echo "ok: ./$(BIN)"

install:
	@./install.sh

test: build
	@./$(BIN) --help > /dev/null
	@./$(BIN) displays > /dev/null
	@./$(BIN) --dry keys "Abc-1!" | tail -1
	@./$(BIN) --dry click 10 20
	@./$(BIN) --dry tap 10 20 120
	@./$(BIN) --dry press 10 20
	@./$(BIN) --dry drag 10 10 90 90 --ms 300 | head -1
	@./$(BIN) --dry scroll 120 --drag
	@./$(BIN) --dry shot -R 0,0,100,100 --grid 40 --zoom 2
	@echo "smoke tests passed"

sync-skill:
	@mkdir -p $(SKILL_DEST)
	@install -m 0644 skill/SKILL.md $(SKILL_DEST)/SKILL.md
	@echo "ok: $(SKILL_DEST)/SKILL.md"

clean:
	@rm -f $(BIN)
	@rm -rf .build
