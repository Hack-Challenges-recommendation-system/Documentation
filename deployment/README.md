# Защитный стенд

Приложение доступно по `https://cson.site`. Внешний Nginx перенаправляет HTTP на HTTPS и передаёт запросы на локальный порт `127.0.0.1:8080` контейнера frontend. Frontend передаёт `/api/` в api-gateway. Файл сайта Nginx установлен в `/etc/nginx/sites-available/cson.site`.

Исходники и Compose находятся в `/root/projects/recommendation-system`. Образы приложения собраны на сервере из этих исходников с тегом `alpha-kch/hackathon-recommendation-system-<service>:defense-20261116`. Приватный `documentation/.env` доступен только root.

```sh
cd /root/projects/recommendation-system/documentation
docker compose ps --all
docker compose up -d --no-build
docker compose logs --tail 100 recommendation-service
nginx -t
certbot renew --dry-run
```

Сертификат Let's Encrypt для `cson.site` обновляется таймером Certbot. Hook в `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx` перезагружает Nginx после обновления сертификата.

Grafana доступна только через SSH-перенаправление порта. На компьютере демонстрации выполните:

```sh
ssh -N -L 3000:127.0.0.1:3000 SSH_USER@VPS_HOST
```

Затем откройте дашборды:

- [Состояние системы](http://127.0.0.1:3000/d/alpha-system/01-c2b7-sostojanie-sistemy)
- [Рекомендации и LLM](http://127.0.0.1:3000/d/alpha-recommendation/02-c2b7-rekomendacii-i-llm)
- [События и A/B](http://127.0.0.1:3000/d/alpha-product/03-c2b7-sobytija-i-a-b)
- [Журналы сервисов](http://127.0.0.1:3000/d/alpha-logs/04-c2b7-zhurnaly-servisov)

Состояние локального XRay SOCKS-туннеля доступно в Prometheus по метрике `recommendation_xray_ready`. Значение `1` означает, что локальный SOCKS принимает соединения. Отдельный HTTPS-запрос через туннель к `api.anthropic.com` проверяет сетевой путь.
