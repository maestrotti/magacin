const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const extract = (start, end) => script.slice(script.indexOf(start), script.indexOf(end, script.indexOf(start)));

function createContext() {
  const clock = { value: '2026-11-03T12:00:00Z' };
  class TestDate extends Date {
    constructor(...args) { super(...(args.length ? args : [clock.value])); }
  }
  const elements = new Map();
  const get = selector => {
    if (!elements.has(selector)) elements.set(selector, {
      value: '', innerHTML: '', hidden: false,
      focus() {},
      querySelectorAll(selector) {
        if (selector !== '[data-calendar-day]') return [];
        this.days = [...this.innerHTML.matchAll(/data-calendar-day="([^"]+)"/g)]
          .map(match => ({ dataset: { calendarDay: match[1] } }));
        return this.days;
      },
    });
    return elements.get(selector);
  };
  const context = vm.createContext({
    $: get, Date: TestDate, Intl, elements, me: { role: 'upravnik' }, tab: 'evid', evidMode: 'tx',
    rg: { f: '', t: '', q: '' }, hf: { cu: '', pr: '', pl: '', kd: '', st: 'main' },
    srt: { k: 'date', d: -1 }, mov: [], customers: [], products: [],
    mgr: () => true, isMok: id => id === 'mok', storeId: () => 'main',
    plantName: id => id, stores: () => [{ id: 'main', name: 'Main' }, { id: 'mok', name: 'MOK' }],
    fmt: String, esc: String, fd: String, dan: () => '',
    custLabel: String, destOf: () => '', tg: () => '', act: () => '',
    inR: movement => (!context.rg.f || movement.date >= context.rg.f)
      && (!context.rg.t || movement.date <= context.rg.t),
    sortMov: rows => rows, applyMokScope() {}, bind() {}, bindEvidTabs() {},
    evidTabs: () => '', toast() {},
  });
  vm.runInContext(extract('const historyCalendar=', "const FI="), context);
  vm.runInContext(extract('function drawHistoryCalendar(', 'function vGroup('), context);
  return { context, get, clock, run: code => vm.runInContext(code, context) };
}

test('the complete application script parses', () => {
  assert.doesNotThrow(() => new vm.Script(script));
});

test('business dates use Sarajevo time across UTC midnight and summer time', () => {
  const { run } = createContext();
  assert.equal(run("sarajevoDate(new Date('2026-11-03T23:30:00Z'))"), '2026-11-04');
  assert.equal(run("sarajevoDate(new Date('2026-07-01T22:30:00Z'))"), '2026-07-02');
  assert.equal(run("shiftCalendarMonth('2026-12',1)"), '2027-01');
  assert.equal(run("shiftCalendarMonth('2026-01',-1)"), '2025-12');
});

test('calendar handles leap years, month navigation and warehouse-specific totals', () => {
  const { context, get, run } = createContext();
  context.mov = [
    { plant_id: 'main', date: '2024-02-10', qty_in: 100, qty_out: 0 },
    { plant_id: 'mok', date: '2024-02-10', qty_in: 999, qty_out: 0 },
  ];
  run("historyCalendar.month='2024-02';drawHistoryCalendar(()=>{})");
  assert.equal(get('#history-calendar').days.length, 29);
  assert.match(get('#history-calendar').innerHTML, /2024-02-10 · ulaz 100 · izlaz 0/);
  assert.doesNotMatch(get('#history-calendar').innerHTML, /999/);
  get('#calendar-next').onclick();
  assert.equal(get('#history-calendar').days.length, 31);
  assert.equal(run('historyCalendar.month'), '2024-03');
});

test('clicking a date filters both directions and switching warehouses preserves the date', () => {
  const { context, get, run } = createContext();
  context.mov = [
    { plant_id: 'main', date: '2026-11-02', qty_in: 100, qty_out: 0, products: { name: 'MAIN-IN' } },
    { plant_id: 'main', date: '2026-11-02', qty_in: 0, qty_out: 40, products: { name: 'MAIN-OUT' } },
    { plant_id: 'main', date: '2026-11-01', qty_in: 7, qty_out: 0, products: { name: 'OLD-DAY' } },
    { plant_id: 'mok', date: '2026-11-02', qty_in: 9, qty_out: 0, products: { name: 'MOK-IN' } },
  ];
  run("historyCalendar.month='2026-11';vEvid()");
  get('#history-calendar').days.find(day => day.dataset.calendarDay === '2026-11-02').onclick();
  assert.equal(context.rg.f, '2026-11-02');
  assert.equal(context.rg.t, '2026-11-02');
  assert.match(get('#l').innerHTML, /MAIN-IN/);
  assert.match(get('#l').innerHTML, /MAIN-OUT/);
  assert.doesNotMatch(get('#l').innerHTML, /OLD-DAY|MOK-IN/);
  get('#fst').onchange({ target: { value: 'mok' } });
  assert.match(get('#l').innerHTML, /MOK-IN/);
  assert.doesNotMatch(get('#l').innerHTML, /MAIN-IN|MAIN-OUT/);
  assert.equal(context.rg.f, '2026-11-02');
  get('#calendar-all').onclick();
  assert.equal(context.rg.f, '');
  assert.equal(context.rg.t, '');
});

test('today follows the date rollover while a manually selected day remains selected', () => {
  const { get, clock, run } = createContext();
  run('vEvid()');
  assert.equal(run('rg.f'), '2026-11-03');
  clock.value = '2026-11-04T12:00:00Z';
  run('tickHistoryCalendar()');
  assert.equal(run('rg.f'), '2026-11-04');
  get('#history-calendar').days.find(day => day.dataset.calendarDay === '2026-11-02').onclick();
  clock.value = '2026-11-05T12:00:00Z';
  run('tickHistoryCalendar()');
  assert.equal(run('rg.f'), '2026-11-02');
  assert.match(get('#history-calendar').innerHTML, /data-calendar-day="2026-11-05" aria-current="date"/);
});

test('customer transfer sends the chosen quantity and rejects invalid quantities', async () => {
  const { context, get, run } = createContext();
  const requests = [];
  let submit;
  context.mainCustomerLabel = String;
  context.custFor = () => [{ id: 'source', name: 'Bulgaria' }, { id: 'target', name: 'Turkey' }];
  context.dlg = (title, info, body, callback) => { submit = callback; };
  context.sb = { rpc: async (name, args) => { requests.push({ name, args }); return {}; } };
  context.row = { plant_id: 'main', product_id: 'LP1', customer_id: 'source', customer: 'Bulgaria', product: 'LP1', serija: 'S1', stanje: 100 };
  run(extract('function transfer(s)', 'function control('));
  run('transfer(row)');
  get('#tc').value = 'target';
  get('#tq').value = '40';
  await submit();
  assert.equal(requests[0].args.p_qty, 40);
  assert.equal(requests[0].args.p_from, 'source');
  assert.equal(requests[0].args.p_to, 'target');
  get('#transfer-mode').value = 'all';
  get('#transfer-mode').onchange();
  await submit();
  assert.equal(requests[1].args.p_qty, 100);
  for (const value of ['0', '-1', '101', '1.5', '']) {
    get('#tq').value = value;
    await assert.rejects(submit);
  }
  assert.equal(requests.length, 2);
});
