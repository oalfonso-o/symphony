.PHONY: help setup build test run

ELIXIR_DIR := elixir
ENV_FILE ?= $(CURDIR)/.env

help:
	@$(MAKE) -C $(ELIXIR_DIR) help

setup:
	@$(MAKE) -C $(ELIXIR_DIR) setup

build:
	@$(MAKE) -C $(ELIXIR_DIR) build

test:
	@$(MAKE) -C $(ELIXIR_DIR) test

run:
	@$(MAKE) -C $(ELIXIR_DIR) run ENV_FILE="$(ENV_FILE)"
