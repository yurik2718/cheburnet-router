// ubus.js — клиент ubus JSON-RPC поверх uhttpd-mod-ubus (/ubus) к объекту `cheburnet` (engine/ubus).
// До установки — НУЛЕВАЯ сессия (ACL даёт анониму read + install, мутации гейтит токен); admin-методы
// требуют сессии от `session.login` (root + пароль, тот же механизм, что у LuCI) — login() её берёт,
// call() подставляет.

const UBUS_URL = '/ubus';
const NULL_SESSION = '00000000000000000000000000000000';

// Session id живёт в sessionStorage: переживает перезагрузку страницы, но не вкладку/браузер.
// Протухшую сессию ubus отвергнет ACCESS-кодом — UI снова покажет вход.
const SESSION_KEY = 'cheburnet_session';
let session = sessionStorage.getItem(SESSION_KEY) || NULL_SESSION;

let nextId = 1;

// Коды результата ubus (status в первом элементе result-кортежа).
const UBUS_STATUS = {
  0: 'OK',
  2: 'INVALID_ARGUMENT',
  4: 'METHOD_NOT_FOUND',
  6: 'PERMISSION_DENIED',
  7: 'TIMEOUT',
  9: 'NOT_FOUND',
};

// call(object, method, params) → данные ответа метода. Бросает Error с понятным текстом при
// сетевой/JSON-RPC/ubus-ошибке — экраны ловят и показывают пользователю.
export async function call(object, method, params = {}) {
  const body = {
    jsonrpc: '2.0',
    id: nextId++,
    method: 'call',
    params: [session, object, method, params],
  };

  let res;
  try {
    res = await fetch(UBUS_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch (e) {
    throw new Error(`сеть недоступна: ${e.message}`);
  }
  if (!res.ok) throw new Error(`HTTP ${res.status} от /ubus`);

  const json = await res.json();
  if (json.error) throw new Error(`ubus RPC: ${json.error.message ?? json.error.code}`);

  // result = [status, data]. status != 0 → ubus отклонил вызов (права/метод/аргументы).
  const [status, data] = json.result ?? [];
  if (status !== 0) {
    const label = UBUS_STATUS[status] ?? `код ${status}`;
    throw new Error(`ubus отклонил вызов: ${label}`);
  }

  // Наши обработчики возвращают {error: "..."} при доменной ошибке (валидация/токен) — поднимаем.
  if (data && data.error) throw new Error(data.error);
  return data ?? {};
}

// Шорткат к нашему объекту движка.
export const cheburnet = (method, params) => call('cheburnet', method, params);

// isLoggedIn() — есть ли (предположительно живая) admin-сессия. Протухание ловится по
// PERMISSION_DENIED на вызове — UI тогда зовёт logout() и снова просит вход.
export const isLoggedIn = () => session !== NULL_SESSION;

// isAccessDenied(e) — отказ доступа в ОБЕИХ формах: без сессии uhttpd отсекает ДО ubus
// ({code:-32002, "Access denied"}), с протухшей — ubus отдаёт статус 6 ("PERMISSION_DENIED").
// ШРАМ: экраны матчили только вторую — первый вход не открывал модалку, человек видел голый «Access denied».
export function isAccessDenied(e) {
  return /PERMISSION_DENIED|Access denied/i.test(e.message);
}

export function logout() {
  session = NULL_SESSION;
  sessionStorage.removeItem(SESSION_KEY);
}

// login(password) — admin-сессия через ubus session.login (root). Успех → session id
// подставляется во все последующие вызовы. Неверный пароль ubus отдаёт как отказ доступа —
// переводим в понятную ошибку.
export async function login(password) {
  logout(); // login всегда с нулевой сессией
  let data;
  try {
    data = await call('session', 'login', { username: 'root', password, timeout: 3600 });
  } catch (e) {
    // Точный код отказа session.login зависит от сборки rpcd (видели 6/9) — матчим шире и
    // дописываем оригинал, чтобы нестандартный ответ не превратился в немую ошибку. QEMU-чек.
    if (/PERMISSION|ACCESS|NOT_FOUND|denied/i.test(e.message)) {
      throw new Error('неверный пароль');
    }
    throw new Error(`вход не удался: ${e.message}`);
  }
  if (!data.ubus_rpc_session) throw new Error('сессия не получена — неверный пароль?');
  session = data.ubus_rpc_session;
  sessionStorage.setItem(SESSION_KEY, session);
}
