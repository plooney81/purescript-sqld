.DEFAULT_GOAL := help
.PHONY: help build test validate validate-fast sql list examples examples-check pg-stop clean

# Optional filter: `make validate-fast ONLY=join`
ONLY ?=
ARGS := $(if $(ONLY),--only $(ONLY),)

VALIDATOR := node scripts/validate-sql.mjs
LOCAL_PG  := ./scripts/pg-validate-local.sh

help: ## Show this help
	@echo "sqld — development targets"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables:"
	@echo "  ONLY=<pattern>  filter corpus entries by name (validate, validate-fast)"
	@echo "  SQL=<query>     ad-hoc query for the 'sql' target"
	@echo
	@echo "Examples:"
	@echo "  make validate-fast ONLY=join"
	@echo "  make sql SQL='SELECT \"u\".* FROM \"users\" AS \"u\"'"

build: ## Compile the library
	spago build

test: ## Run the golden tests (also emits test-artifacts/corpus.json)
	spago test

validate: ## Run tests, then validate every query against real PostgreSQL
	$(LOCAL_PG) $(ARGS)

validate-fast: ## Validate using the existing corpus and a warm container (skips spago test)
	SQLD_SKIP_TEST=1 $(LOCAL_PG) $(ARGS)

sql: ## Probe one ad-hoc query: make sql SQL='SELECT 1'
ifndef SQL
	$(error SQL is not set. Usage: make sql SQL='SELECT 1')
endif
	SQLD_SKIP_TEST=1 $(LOCAL_PG) --sql $(call quote,$(SQL))

examples: ## Regenerate EXAMPLES.md from the cookbook
	spago test
	@node scripts/build-examples.mjs

examples-check: ## Fail if EXAMPLES.md is out of date
	@node scripts/build-examples.mjs --check

list: ## List corpus entry names (no database needed)
	@$(VALIDATOR) --list

pg-stop: ## Remove the local PostgreSQL container
	docker rm -f sqld-pg-validate 2>/dev/null || true

clean: ## Remove build and test artifacts
	rm -rf output test-artifacts

# Wraps a value in single quotes, escaping any it already contains, so queries
# survive the trip through the shell intact.
quote = '$(subst ','\'',$(1))'
