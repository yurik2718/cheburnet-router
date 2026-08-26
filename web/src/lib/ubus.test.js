// ubus.test.js — юнит-тесты ubus-клиента (vitest, node): маппинг ошибок и жизненный
// цикл сессии — та логика, от которой зависят ВСЕ экраны. Сеть и браузерное
// окружение стабятся; настоящий HTTP-путь проверяет tests/qemu/webui.sh (T3b).
//   npm test  (vitest run)

import { describe, it, expect, beforeEach, vi } from 'vitest';

// sessionStorage читается на уровне модуля → стаб ДО импорта, импорт динамический.
const store = new Map();
vi.stubGlobal('sessionStorage', {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => store.set(k, v),
  removeItem: (k) => store.delete(k),
});

const { call, cheburnet, login, logout, isLoggedIn, isAccessDenied } = await import('./ubus.js');

// Хелпер: следующий fetch вернёт этот JSON-RPC ответ (200 OK).
function fetchReturns(json) {
  const mock = vi.fn(async () => ({ ok: true, json: async () => json }));
  vi.stubGlobal('fetch', mock);
  return mock;
}

beforeEach(() => {
  store.clear();
  logout();
});

describe('call: маппинг ответов ubus', () => {
  it('status=0 → возвращает данные метода', async () => {
    fetchReturns({ result: [0, { installed: false }] });
    expect(await cheburnet('status')).toEqual({ installed: false });
  });

  it('status=6 → понятная ошибка PERMISSION_DENIED (UI открывает вход)', async () => {
    fetchReturns({ result: [6] });
    await expect(cheburnet('set_mode', { mode: 'home' }))
      .rejects.toThrow('PERMISSION_DENIED');
  });

  it('неизвестный status → показываем код, не молчим', async () => {
    fetchReturns({ result: [42] });
    await expect(call('cheburnet', 'status')).rejects.toThrow('код 42');
  });

  it('JSON-RPC error → ошибка с текстом', async () => {
    fetchReturns({ error: { code: -32002, message: 'Access denied' } });
    await expect(call('cheburnet', 'status')).rejects.toThrow('Access denied');
  });

  it('доменная ошибка обработчика ({error}) поднимается как есть', async () => {
    fetchReturns({ result: [0, { error: 'неверный install-токен' }] });
    await expect(cheburnet('install', {})).rejects.toThrow('неверный install-токен');
  });

  it('HTTP не-200 → ошибка с кодом', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 500 })));
    await expect(call('cheburnet', 'status')).rejects.toThrow('HTTP 500');
  });

  it('сеть упала → «сеть недоступна», не голый TypeError', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => { throw new TypeError('fail'); }));
    await expect(call('cheburnet', 'status')).rejects.toThrow('сеть недоступна');
  });
});

describe('login/logout: жизненный цикл admin-сессии', () => {
  it('успех: сессия сохраняется и подставляется в следующие вызовы', async () => {
    fetchReturns({ result: [0, { ubus_rpc_session: 'abc123' }] });
    await login('correct-pass');
    expect(isLoggedIn()).toBe(true);

    const mock = fetchReturns({ result: [0, {}] });
    await cheburnet('set_mode', { mode: 'home' });
    const sent = JSON.parse(mock.mock.calls[0][1].body);
    expect(sent.params[0]).toBe('abc123'); // session id — первый элемент params
  });

  it('отказ доступа (код 6 или 9 — зависит от сборки rpcd) → «неверный пароль»', async () => {
    fetchReturns({ result: [6] });
    await expect(login('bad')).rejects.toThrow('неверный пароль');
    fetchReturns({ result: [9] });
    await expect(login('bad')).rejects.toThrow('неверный пароль');
    expect(isLoggedIn()).toBe(false);
  });

  it('ответ без сессии (нестандартный rpcd) → ошибка, не тихий «успех»', async () => {
    fetchReturns({ result: [0, {}] });
    await expect(login('x')).rejects.toThrow('сессия не получена');
    expect(isLoggedIn()).toBe(false);
  });

  it('logout: возвращаемся к анонимной сессии', async () => {
    fetchReturns({ result: [0, { ubus_rpc_session: 'abc123' }] });
    await login('correct-pass');
    logout();
    expect(isLoggedIn()).toBe(false);

    const mock = fetchReturns({ result: [0, {}] });
    await cheburnet('status');
    const sent = JSON.parse(mock.mock.calls[0][1].body);
    expect(sent.params[0]).toBe('00000000000000000000000000000000');
  });
});

describe('isAccessDenied: обе формы отказа доступа — экраны должны открыть вход на любую', () => {
  it('ubus-статус PERMISSION_DENIED (сессия протухла/не хватает прав)', () => {
    expect(isAccessDenied(new Error('ubus отклонил вызов: PERMISSION_DENIED'))).toBe(true);
  });

  it('JSON-RPC error "Access denied" (сессии вовсе не было — uhttpd отсекает ДО ubus)', () => {
    // ШРАМ: до этого теста экраны ловили только вариант выше — первый заход без входа
    // показывал голое «Access denied» вместо модалки логина (см. Status.svelte).
    expect(isAccessDenied(new Error('ubus RPC: Access denied'))).toBe(true);
  });

  it('несвязанная ошибка — не открываем вход зря', () => {
    expect(isAccessDenied(new Error('сеть недоступна: fail'))).toBe(false);
    expect(isAccessDenied(new Error('неверный install-токен'))).toBe(false);
  });
});
