SHELL := /bin/bash

COMPOSE        := docker compose
SECRETS_DIR    := secrets
ENV_FILE       := .env
AUTHELIA_DIR   := authelia
AUTHELIA_CFG   := $(AUTHELIA_DIR)/configuration.yml
AUTHELIA_USERS := $(AUTHELIA_DIR)/users_database.yml
CA_OUT         := painscaler-ca.crt
AUTHELIA_IMG   := authelia/authelia:4.39

.PHONY: help
help:
	@awk 'BEGIN{FS=":.*##"; printf "Targets:\n"} /^[a-zA-Z0-9_.-]+:.*##/ {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: init
init: env secrets render ## bootstrap: generate .env, secrets, rendered configs

$(SECRETS_DIR):
	@mkdir -p $(SECRETS_DIR)
	@chmod 700 $(SECRETS_DIR)

$(ENV_FILE):
	@if [ ! -f $(ENV_FILE) ]; then cp .env.example $(ENV_FILE) && echo "[init] created $(ENV_FILE) — fill ZPA_* values"; fi

.PHONY: env
env: $(ENV_FILE) ## ensure .env exists (copy from .env.example)

.PHONY: secrets
secrets: $(SECRETS_DIR) $(SECRETS_DIR)/session_secret $(SECRETS_DIR)/storage_encryption_key $(SECRETS_DIR)/jwt_secret $(SECRETS_DIR)/admin_password $(SECRETS_DIR)/admin_password_hash ## generate all random secrets (idempotent — only fills missing)

$(SECRETS_DIR)/session_secret: | $(SECRETS_DIR)
	@openssl rand -hex 32 > $@ && chmod 600 $@ && echo "[secrets] session_secret"

$(SECRETS_DIR)/storage_encryption_key: | $(SECRETS_DIR)
	@openssl rand -hex 32 > $@ && chmod 600 $@ && echo "[secrets] storage_encryption_key"

$(SECRETS_DIR)/jwt_secret: | $(SECRETS_DIR)
	@openssl rand -hex 32 > $@ && chmod 600 $@ && echo "[secrets] jwt_secret"

$(SECRETS_DIR)/admin_password: | $(SECRETS_DIR)
	@LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*_+-' </dev/urandom | head -c 24 > $@
	@echo >> $@
	@chmod 600 $@
	@echo "[secrets] admin_password (plaintext, view: make show-admin)"

$(SECRETS_DIR)/admin_password_hash: $(SECRETS_DIR)/admin_password
	@echo "[secrets] hashing admin password via $(AUTHELIA_IMG)..."
	@docker run --rm $(AUTHELIA_IMG) authelia crypto hash generate argon2 --password "$$(cat $(SECRETS_DIR)/admin_password)" \
		| awk -F': ' '/Digest/ {print $$2}' > $@
	@chmod 600 $@
	@if [ ! -s $@ ]; then echo "[error] hash empty"; rm -f $@; exit 1; fi

.PHONY: render
render: $(AUTHELIA_CFG) $(AUTHELIA_USERS) ## render templated Authelia configs from secrets

$(AUTHELIA_CFG): $(AUTHELIA_DIR)/configuration.yml.tmpl secrets
	@AUTHELIA_SESSION_SECRET="$$(cat $(SECRETS_DIR)/session_secret)" \
	 AUTHELIA_STORAGE_ENCRYPTION_KEY="$$(cat $(SECRETS_DIR)/storage_encryption_key)" \
	 AUTHELIA_JWT_SECRET="$$(cat $(SECRETS_DIR)/jwt_secret)" \
	 envsubst < $< > $@
	@chmod 600 $@
	@echo "[render] $@"

$(AUTHELIA_USERS): $(AUTHELIA_DIR)/users_database.yml.tmpl secrets
	@ADMIN_PASSWORD_HASH="$$(cat $(SECRETS_DIR)/admin_password_hash)" \
	 envsubst < $< > $@
	@chmod 600 $@
	@echo "[render] $@"

.PHONY: show-admin
show-admin: ## print admin credentials
	@echo "user: admin"
	@echo "pass: $$(cat $(SECRETS_DIR)/admin_password)"

.PHONY: rotate
rotate: ## regenerate all secrets and re-render configs (DESTRUCTIVE — invalidates sessions)
	@read -p "this wipes existing secrets + sessions. type 'yes' to continue: " ans && [ "$$ans" = "yes" ]
	@rm -rf $(SECRETS_DIR) $(AUTHELIA_CFG) $(AUTHELIA_USERS)
	@$(MAKE) init
	@echo "[rotate] done — restart with: make restart"

.PHONY: hash
hash: ## hash a password: make hash PASSWORD=secret
	@if [ -z "$(PASSWORD)" ]; then echo "usage: make hash PASSWORD=..."; exit 1; fi
	@docker run --rm $(AUTHELIA_IMG) authelia crypto hash generate argon2 --password "$(PASSWORD)"

.PHONY: build
build: ## build all images
	@$(COMPOSE) build

.PHONY: up
up: init ## start stack (runs init first)
	@$(COMPOSE) up -d
	@echo
	@echo "stack up. add to /etc/hosts on clients:"
	@echo "  <docker-host-ip>  painscaler.lan auth.lan"
	@echo "then: make ca && trust $(CA_OUT) in your browser"

.PHONY: down
down: ## stop stack (keep volumes)
	@$(COMPOSE) down

.PHONY: nuke
nuke: ## stop stack and remove all volumes (DESTRUCTIVE)
	@read -p "deletes all data. type 'yes' to continue: " ans && [ "$$ans" = "yes" ]
	@$(COMPOSE) down -v

.PHONY: restart
restart: ## restart stack
	@$(COMPOSE) restart

.PHONY: logs
logs: ## tail all logs
	@$(COMPOSE) logs -f --tail=100

.PHONY: ps
ps: ## list services
	@$(COMPOSE) ps

.PHONY: ca
ca: ## extract Caddy root CA cert to ./$(CA_OUT)
	@$(COMPOSE) cp caddy:/data/caddy/pki/authorities/local/root.crt ./$(CA_OUT)
	@echo "[ca] wrote ./$(CA_OUT) — install in browser/OS trust store"

.PHONY: mfa
mfa: ## tail Authelia notifications (MFA codes / TOTP setup links)
	@touch $(AUTHELIA_DIR)/notifications.txt
	@tail -f $(AUTHELIA_DIR)/notifications.txt

.PHONY: clean
clean: ## remove rendered configs and secrets (does NOT touch volumes)
	@read -p "removes ./$(SECRETS_DIR), $(AUTHELIA_CFG), $(AUTHELIA_USERS). type 'yes': " ans && [ "$$ans" = "yes" ]
	@rm -rf $(SECRETS_DIR) $(AUTHELIA_CFG) $(AUTHELIA_USERS) $(CA_OUT)
