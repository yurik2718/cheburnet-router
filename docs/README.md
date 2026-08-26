# Документация cheburnet-router

## Архитектура и база знаний

- **[architecture.md](architecture.md)** — полный дизайн-документ: лёгкий split-tunnel
  на примитивах ядра, движок на ucode, дистрибуция через GitHub Releases + apk.
- **[База знаний (Obsidian-vault)](kb/README.md)** — образовательная документация «от первых
  принципов»: как работает [split-routing](kb/concepts/split-routing.md),
  [policy routing](kb/concepts/policy-routing.md), и почему приняты ключевые
  [решения (ADR)](kb/decisions/0001-why-not-singbox.md). Точка входа и карта —
  [kb/README.md](kb/README.md).

> Для AI-ассистентов и контрибьюторов: гид по проекту — `CLAUDE.md` в корне репозитория.

## Установка

- **[00 · Прошивка OpenWrt](00-flash-openwrt.md)** — первая установка OpenWrt на роутер, нужна
  один раз перед основной установкой.
- **[open-terminal.md](open-terminal.md)** — как открыть терминал и вставить команду установки
  (для тех, кто впервые видит терминал).
- **[install-no-ssh.md](install-no-ssh.md)** — установка через браузер (LuCI), без SSH.
- **[install-blocked.md](install-blocked.md)** — что делать, если провайдер блокирует загрузку
  пакетов при установке.
- **[uninstall.md](uninstall.md)** — снять настройку или удалить cheburnet целиком (и что из
  зависимостей трогать нельзя).

## Справочные

- **[kb/reference/troubleshooting.md](kb/reference/troubleshooting.md)** — куда смотреть, когда
  что-то не работает.
- **[kb/reference/hardware-requirements.md](kb/reference/hardware-requirements.md)** — какое
  железо подходит.
- **[kb/meta/release-checklist.md](kb/meta/release-checklist.md)** — ручная проверка перед тегом.
- **[support.md](support.md)** — как поддержать проект.
