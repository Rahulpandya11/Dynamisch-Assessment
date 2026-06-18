.PHONY: install start stop logs shell status

COMPOSE = docker compose --env-file secrets/.env

install:
	bash scripts/install-magento.sh

start:
	$(COMPOSE) up -d

stop:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f

shell:
	$(COMPOSE) exec php-fpm bash

status:
	$(COMPOSE) ps
