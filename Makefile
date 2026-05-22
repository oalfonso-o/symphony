.PHONY: help all setup build test run symphony

ELIXIR_DIR := elixir
ENV_FILE ?= $(CURDIR)/.env
MIX ?= mise exec -- mix
SYMPHONY_PORT ?= 4001
SYMPHONY_WORKFLOW ?= $(CURDIR)/WORKFLOW.huekin-runtime.md

help:
	@$(MAKE) -C $(ELIXIR_DIR) help MIX="$(MIX)"

all:
	@$(MAKE) -C $(ELIXIR_DIR) all MIX="$(MIX)"

setup:
	@$(MAKE) -C $(ELIXIR_DIR) setup MIX="$(MIX)"

build:
	@$(MAKE) -C $(ELIXIR_DIR) build MIX="$(MIX)"

test:
	@$(MAKE) -C $(ELIXIR_DIR) test MIX="$(MIX)"

run:
	@$(MAKE) -C $(ELIXIR_DIR) run MIX="$(MIX)" ENV_FILE="$(ENV_FILE)"

symphony:
	@$(MAKE) -C $(ELIXIR_DIR) run MIX="$(MIX)" PORT="$(SYMPHONY_PORT)" WORKFLOW="$(SYMPHONY_WORKFLOW)" ENV_FILE="$(ENV_FILE)"
