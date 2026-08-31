// readme-shots.mjs — скриншоты интерфейса для README (через герметичный mock-router).
// Снимает экран настройки (web-installer.png) и панель управления (web-mgmt.png)
// с реального собранного бандла — то, что видит пользователь.
//   node tests/e2e/readme-shots.mjs <out-dir>
import { chromium } from '@playwright/test';
import { spawn } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';

const OUT = process.argv[2] || '/tmp/readme-shots';
// E2E_PORT — как в mock-router.mjs (в WSL mirrored-режиме 4317 бывает занят со стороны Windows).
const BASE = `http://127.0.0.1:${process.env.E2E_PORT ?? 4317}`;
const AWG_CONF = `[Interface]
PrivateKey = 0000000000000000000000000000000000000000000=
Address = 10.8.1.7/32
DNS = 1.1.1.1
Jc = 4
Jmin = 40
Jmax = 70

[Peer]
PublicKey = 0000000000000000000000000000000000000000000=
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0`;

const mock = spawn('node', ['tests/e2e/mock-router.mjs'], { stdio: 'inherit' });
await sleep(1200);

const browser = await chromium.launch({ args: ['--no-sandbox'] });
try {
  const page = await browser.newPage({ viewport: { width: 760, height: 900 } });
  // Железо, которое тянет Full-тир: на скриншоте видно все три туннеля живыми. На слабом мок
  // запирает два из трёх, и README показывал бы две недоступные строки вместо главной ценности.
  await page.request.post(`${BASE}/__set`, { data: { hw: 'full' } });
  await page.goto(`${BASE}/cheburnet/?token=TESTTOKEN`);
  await page.getByText('все 6 проверок пройдены').waitFor();
  await page.getByRole('button', { name: 'Продолжить' }).click();

  // Экран настройки — с заполненными полями (как у реального пользователя). Дефолт на таком
  // железе — Reality; для кадра берём AmneziaWG, рекомендованный в README.
  await page.getByRole('radio', { name: /Роутер слабый или хочется максимально быстро/ }).check();
  await page.getByLabel('VPN-конфиг').fill(AWG_CONF);
  await page.getByLabel('Пароль администратора (root)').fill('secret-pass-1');
  await page.getByLabel('Повторите пароль').fill('secret-pass-1');
  await page.getByLabel('Имя сети (SSID)').fill('MyHomeNet');
  await page.getByLabel('Пароль Wi-Fi').fill('wifi-pass-1');
  await page.screenshot({ path: `${OUT}/web-installer.png`, fullPage: true });

  // Дальше до панели управления.
  await page.getByRole('button', { name: 'Установить' }).click();
  await page.getByText('Шаг 3 из 4').waitFor();
  await page.getByRole('button', { name: 'Установить' }).click();
  await page.getByText('Готово! Роутер настроен').waitFor({ timeout: 15_000 });
  await page.getByRole('button', { name: 'Открыть панель управления' }).click();
  await page.getByRole('heading', { name: 'Состояние' }).waitFor({ timeout: 10_000 });
  await sleep(400); // дорисовка статусных строк
  await page.screenshot({ path: `${OUT}/web-mgmt.png`, fullPage: true });
  console.log(`✓ скриншоты в ${OUT}`);
} finally {
  await browser.close();
  mock.kill();
}
