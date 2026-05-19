.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e run

MIX ?= mix
MISE ?= mise
PORT ?= 4000
WORKFLOW ?= $(HOME)/pipprojects/newhuekin/WORKFLOW.md
ENV_FILE ?= ../.env
PORT_ORIGIN := $(origin PORT)
WORKFLOW_ORIGIN := $(origin WORKFLOW)
SYMPHONY_ACK_FLAG := --i-understand-that-this-will-be-running-without-the-usual-guardrails

help:
	@echo "Targets: setup, deps, build, run, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"
	@echo "Run options: make run PORT=4000 WORKFLOW=$(HOME)/pipprojects/newhuekin/WORKFLOW.md ENV_FILE=../.env"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

run:
	@if [ ! -x ./bin/symphony ]; then $(MAKE) build; fi
	@if [ ! -f "$(ENV_FILE)" ]; then \
		echo "Missing $(ENV_FILE). Copy .env.example to .env and set LINEAR_API_KEY." >&2; \
		exit 1; \
	fi
	@set -a; \
	. "$(ENV_FILE)"; \
	set +a; \
	if [ "$(PORT_ORIGIN)" = "command line" ]; then PORT="$(PORT)"; fi; \
	if [ "$(WORKFLOW_ORIGIN)" = "command line" ]; then WORKFLOW="$(WORKFLOW)"; fi; \
	: "$${PORT:=$(PORT)}"; \
	: "$${WORKFLOW:=$(WORKFLOW)}"; \
	if [ -z "$$LINEAR_API_KEY" ]; then \
		echo "LINEAR_API_KEY is not set in $(ENV_FILE)." >&2; \
		exit 1; \
	fi; \
	if [ ! -f "$$WORKFLOW" ]; then \
		echo "Workflow file not found: $$WORKFLOW" >&2; \
		exit 1; \
	fi; \
	$(MISE) exec -- ./bin/symphony $(SYMPHONY_ACK_FLAG) --port "$$PORT" "$$WORKFLOW"

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
