// Model.js is a QML pragma library, so it is loaded here as plain JavaScript
// by stripping the directive. Every test drives the real parser, the real URL
// allowlist and the real seen-state diff.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';

const here = new URL('./', import.meta.url);
const root = new URL('../', here);
const source = readFileSync(new URL('Model.js', root), 'utf8')
  .replace(/^\.pragma\s+library\s*$/m, '');
// "use strict" so an undeclared assignment (which once threw a ReferenceError
// from the GOG parser) fails here instead of at runtime in the shell.
const Model = new Function(`"use strict";\n${source}\nreturn {
  STORES, STORE_LABELS, HOSTS, SEARCH_URLS, MAX_TITLE,
  staleAfterMs, STALE_MULTIPLIER,
  scrubTitle, scrubId, safeUrl, searchUrl, enabled, notifyFor, setting,
  normalizeCountry, normalizeRefreshMinutes, parseStore, parseSteam,
  parseEpic, parseGog, emptySeen, parseSeen, serializeSeen, diffStore,
  notificationArgs, totalGames, activeStores, statusTitle,
  storeErrorLabel, freshnessLabel, ageLabel, firstId, matchAttr,
  storeList, heroTitle, heroDetail, BAR_ICON, STORE_LABELS, STORE_SHORT,
  acknowledgeGame, forgetGame, unseenIds, hasUnseen, acknowledgedOf, STORE_GLYPHS,
  IPC_TARGET, NEW_GAME_GLYPH, HOURGLASS_GLYPH, endingSoon,
};`)();

const fixture = name => readFileSync(new URL(`fixtures/${name}`, here), 'utf8');

// The captured Epic payload carries absolute window dates, so its live and
// upcoming windows are rebased on "now" as it loads. Stored as-is they stop
// meaning live the day the window lapses, which is how these tests silently
// went red. Only the ordering matters, so the offsets are arbitrary.
function epicFixture() {
  const day = 24 * 60 * 60 * 1000;
  const at = days => new Date(Date.now() + days * day).toISOString();
  return fixture('epic-free-games.json')
    .replaceAll('2026-10-08T15:00:00.000Z', at(-10))  // live window opens
    .replaceAll('2026-10-15T15:00:00.000Z', at(10))   // live window closes
    .replaceAll('2026-10-22T15:00:00.000Z', at(20))   // upcoming opens
    .replaceAll('2026-10-29T15:00:00.000Z', at(27));  // upcoming closes
}

test('URL allowlist accepts only the store host over https', () => {
  assert.equal(Model.safeUrl('steam', 'https://store.steampowered.com/app/405640/'),
    'https://store.steampowered.com/app/405640/');
  assert.equal(Model.safeUrl('epic', 'https://store.epicgames.com/p/terra-1'),
    'https://store.epicgames.com/p/terra-1');

  // Everything below must resolve to the search page fallback instead.
  for (const hostile of [
    'https://evil.example/app/1',
    'http://store.steampowered.com/app/1',       // not https
    'https://store.steampowered.com.evil.test/x', // suffix confusion
    'https://user@store.steampowered.com/x',      // credentials in authority
    'https://store.steampowered.com:8443/x',      // alternate port
    'javascript:alert(1)',
    'file:///etc/passwd',
    'https://evil.test/?x=https://store.steampowered.com',
    '',
    null,
    'https://store.steampowered.com/' + 'x'.repeat(400),
  ]) {
    assert.equal(Model.safeUrl('steam', hostile), '', `hostile URL leaked: ${hostile}`);
  }

  // A URL for one store must not pass another's allowlist.
  assert.equal(Model.safeUrl('gog', 'https://store.steampowered.com/app/1'), '');
});

test('titles are scrubbed before they reach any sink', () => {
  assert.equal(Model.scrubTitle('<b>Bold</b> Game'), 'Bold Game');
  assert.equal(Model.scrubTitle('RTL \u202eoverridden'), 'RTL overridden');
  assert.equal(Model.scrubTitle('bell\u0007\u009f'), 'bell');
  assert.equal(Model.scrubTitle('&#60;script&#62;'), 'script');
  assert.equal(Model.scrubTitle('&#x202e;'), '', 'entity-encoded bidi must be dropped');
  assert.equal(Model.scrubTitle('&#xD800;'), '', 'surrogate entity must be dropped');
  assert.ok(Model.scrubTitle('x'.repeat(500)).length <= Model.MAX_TITLE);
});

test('ids are constrained to a safe character set', () => {
  assert.equal(Model.scrubId('abc-123_x.y'), 'abc-123_x.y');
  for (const bad of ['a b', 'a/b', 'a"b', "a'b", 'a;b', 'a&b', 'x'.repeat(41), null]) {
    assert.equal(Model.scrubId(bad), '', `unsafe id accepted: ${bad}`);
  }
});

test('steam attribute reads are anchored and bounded', () => {
  assert.equal(Model.firstId('405640'), '405640');
  assert.equal(Model.firstId('  77 '), '77');
  // The id is concatenated into a URL, so a value that is not *only* digits
  // is refused rather than truncated to the digits it happens to contain.
  assert.equal(Model.firstId('12ab34'), '');
  assert.equal(Model.firstId('99999999999999'), '');
  assert.equal(Model.firstId(''), '');
  assert.equal(Model.firstId(null), '');

  assert.equal(Model.matchAttr('<a data-ds-appid="405640" href="/x">', 'data-ds-appid'),
    '405640');
  assert.equal(Model.matchAttr("<a data-ds-appid='405640'>", 'data-ds-appid'), '405640');
  // A suffixed attribute must not satisfy a shorter name.
  assert.equal(Model.matchAttr('<a xdata-ds-appid="9">', 'data-ds-appid'), '');
  assert.equal(Model.matchAttr('<a data-ds-appid=405640>', 'data-ds-appid'), '');
  // An attribute name carrying regex metacharacters cannot escape its role.
  assert.equal(Model.matchAttr('<a a.*="x">', 'a.*'), '');
  assert.equal(Model.matchAttr('<a x="y">', ''), '');

  // A hostile page cannot make an attribute read return an unbounded string.
  const huge = '<a data-ds-appid="' + '9'.repeat(5000) + '">';
  assert.ok(Model.matchAttr(huge, 'data-ds-appid').length <= 512);
});

test('age labels never render NaN and stay bounded', () => {
  assert.equal(Model.ageLabel(0), '0s');
  assert.equal(Model.ageLabel(59000), '59s');
  assert.equal(Model.ageLabel(60000), '1m');
  assert.equal(Model.ageLabel(3600000), '1h');
  assert.equal(Model.ageLabel(86399000), '23h');
  // Nonsense input used to render as the string "NaNd" in a tooltip.
  for (const bad of ['x', NaN, undefined, null, {}, -5]) {
    const label = Model.ageLabel(bad);
    assert.ok(!/NaN|Infinity|undefined/.test(label), `bad age rendered as: ${label}`);
  }
  assert.ok(Model.ageLabel(1e15).endsWith('d+'), 'an absurd age should be capped');
});

test('the search page falls back to an enabled store', () => {
  assert.equal(Model.searchUrl('steam'),
    'https://store.steampowered.com/search/?maxprice=free&specials=1');
  assert.equal(Model.searchUrl('gog'), 'https://www.gog.com/giveaways');
  assert.equal(Model.searchUrl(''), '');
  assert.equal(Model.searchUrl('', 'epic'), 'https://store.epicgames.com/free-games');
  assert.equal(Model.searchUrl('nintendo', 'steam'),
    'https://store.steampowered.com/search/?maxprice=free&specials=1');
});

test('steam fixture parses into real rows', () => {
  const result = Model.parseSteam(fixture('steam-free.json'));
  assert.equal(result.ok, true);
  assert.equal(result.games.length, 2);
  assert.equal(result.games[0].id, '405640');
  assert.equal(result.games[0].store, 'steam');
  // The href from the response is dropped; the URL is rebuilt from a
  // digits-only id, so there is nothing left to allowlist.
  assert.equal(result.games[0].url, 'https://store.steampowered.com/app/405640/');
  assert.ok(result.games.every(g => /^https:\/\/store\.steampowered\.com\/app\/\d+\/$/.test(g.url)));
});

test('steam rejects a body that is not the search payload', () => {
  for (const body of ['', 'not json', '{}', '[]', '{"results_html":123}', '<html>nope</html>']) {
    const result = Model.parseSteam(body);
    assert.equal(result.ok, false, `accepted ${body}`);
    assert.equal(result.error, 'invalid-response');
    assert.deepEqual(result.games, []);
  }
});

test('epic lists only live zero-discount offers', () => {
  const result = Model.parseEpic(epicFixture());
  assert.equal(result.ok, true);
  const titles = result.games.map(g => g.title);
  assert.ok(titles.includes('Out of Sight'));
  assert.ok(titles.includes('TerraScape Bundle'), 'bundle should still be listed');

  // The three cases that must not appear.
  assert.ok(!titles.includes('Expired Free Game'), 'expired window was listed');
  assert.ok(!titles.includes('Paid Sale'), 'paid promotion was listed');
  assert.ok(!titles.includes('Bad Cheese'), 'upcoming game was listed');
  assert.ok(!titles.includes('Plain Old Game'), 'game with no promotions was listed');
});

test('epic builds links from the catalog mapping, with urlSlug fallback', () => {
  const result = Model.parseEpic(epicFixture());
  const byTitle = Object.fromEntries(result.games.map(g => [g.title, g]));

  assert.equal(byTitle['Out of Sight'].url,
    'https://store.epicgames.com/p/out-of-sight-b96ca8');
  assert.equal(byTitle['TerraScape Bundle'].url,
    'https://store.epicgames.com/bundles/terrascape-2b12b1',
    'a BUNDLE offer uses the /bundles/ path');
  assert.equal(byTitle['No Mapping Game'].url,
    'https://store.epicgames.com/p/nomapping-slug',
    'an empty catalogNs falls back to urlSlug');
});

test('epic scrubs markup-shaped titles', () => {
  const result = Model.parseEpic(epicFixture());
  const hostile = result.games.find(g => g.id === 'id-markup');
  assert.ok(hostile, 'the markup title should still be listed');
  assert.ok(!hostile.title.includes('<'), 'angle brackets survived');
  assert.ok(!hostile.title.includes('\u202e'), 'bidi override survived');
});

test('epic rejects a payload without the expected shape', () => {
  for (const body of ['', 'nope', '{}', '{"data":{}}', '{"data":{"Catalog":{}}}',
    '{"data":{"Catalog":{"searchStore":{}}}}', '[]']) {
    const result = Model.parseEpic(body);
    assert.equal(result.ok, false, `accepted ${body}`);
    assert.equal(result.error, 'invalid-response');
  }
});

test('gog reports a running giveaway', () => {
  const result = Model.parseGog(fixture('gog-giveaway.json'));
  assert.equal(result.ok, true);
  assert.equal(result.games.length, 1);
  assert.equal(result.games[0].title, 'Giveaway Game');
  assert.equal(result.games[0].store, 'gog');
  assert.equal(result.games[0].url, 'https://www.gog.com/game/giveaway_game');
});

test('gog rejects a body that is not an object', () => {
  for (const body of ['', 'null', '[]', '"str"', '{"id":"a b","title":"x"}',
    '{"id":"../../etc/passwd","title":"x"}']) {
    const result = Model.parseGog(body);
    assert.equal(result.ok, false, `accepted ${body}`);
    assert.equal(result.error, 'invalid-response');
    assert.deepEqual(result.games, []);
  }
  // A well-formed giveaway with an unusable title is a valid response that
  // simply has nothing to show, which is not the same as a malformed one.
  assert.deepEqual(Model.parseGog('{"id":"123","title":""}'),
    { ok: true, games: [] });
});

// A giveaway with an id and title but no usable slug used to throw a
// ReferenceError from an undeclared `url`, which escaped the fetch callback and
// left GOG's busy flag set so it never refreshed again. It must list instead,
// with an empty url so the caller falls back to the store search.
test('gog lists a giveaway that has no usable slug', () => {
  const result = Model.parseGog('{"id":"123","title":"No Slug Game","endDate":"2026-10-20T15:00:00Z"}');
  assert.equal(result.ok, true);
  assert.equal(result.games.length, 1);
  assert.equal(result.games[0].title, 'No Slug Game');
  assert.equal(result.games[0].url, '');
  assert.equal(Model.safeUrl('gog', result.games[0].url) || Model.searchUrl('gog'),
    'https://www.gog.com/giveaways');
});

// The slug path must leave no implicit global behind: a slugged response
// followed by a slugless one must yield "" rather than the previous url.
test('gog does not leak the slug url between responses', () => {
  assert.equal(Model.parseGog(fixture('gog-giveaway.json')).games[0].url,
    'https://www.gog.com/game/giveaway_game');
  const next = Model.parseGog('{"id":"999","title":"Another Game"}');
  assert.equal(next.games[0].url, '');
});

test('parseStore routes each store and refuses an unknown one', () => {
  assert.equal(Model.parseStore('steam', fixture('steam-free.json')).ok, true);
  assert.equal(Model.parseStore('epic', epicFixture()).ok, true);
  assert.equal(Model.parseStore('gog', fixture('gog-giveaway.json')).ok, true);
  const unknown = Model.parseStore('nintendo', '{}');
  assert.equal(unknown.ok, false);
  assert.equal(unknown.error, 'invalid-response');
});

test('first fetch is silent for every store', () => {
  for (const store of Model.STORES) {
    const games = [{ store, id: 'a', title: 'A' }, { store, id: 'b', title: 'B' }];
    const out = Model.diffStore(Model.emptySeen(), store, games, true, true);
    assert.deepEqual(out.alerts, [], `${store} alerted on its first fetch`);
    assert.equal(out.state.stores[store].ids.length, 2);
  }
});

test('a new game after the baseline alerts once, then goes quiet', () => {
  const first = Model.diffStore(Model.emptySeen(), 'steam',
    [{ id: 'a', title: 'A' }], true, true);
  assert.deepEqual(first.alerts, []);

  const second = Model.diffStore(first.state, 'steam',
    [{ id: 'a', title: 'A' }, { id: 'b', title: 'B' }], true, true);
  assert.equal(second.alerts.length, 1);
  assert.equal(second.alerts[0].id, 'b');

  const third = Model.diffStore(second.state, 'steam',
    [{ id: 'a', title: 'A' }, { id: 'b', title: 'B' }], true, true);
  assert.deepEqual(third.alerts, [], 'an unchanged list must not re-alert');
});

test('a muted store records without alerting', () => {
  const first = Model.diffStore(Model.emptySeen(), 'epic', [{ id: 'a', title: 'A' }], true, false);
  assert.deepEqual(first.alerts, []);
  const second = Model.diffStore(first.state, 'epic',
    [{ id: 'a', title: 'A' }, { id: 'b', title: 'B' }], true, false);
  assert.deepEqual(second.alerts, [], 'a muted store must stay silent');
  // The baseline still moved, so unmuting does not replay a backlog.
  const unmuted = Model.diffStore(second.state, 'epic',
    [{ id: 'a', title: 'A' }, { id: 'b', title: 'B' }], true, true);
  assert.deepEqual(unmuted.alerts, [], 'unmuting must not replay what it already saw');
});

test('re-enabling a store re-records silently instead of flooding', () => {
  const on = Model.diffStore(Model.emptySeen(), 'gog', [{ id: 'a', title: 'A' }], true, true);
  const off = Model.diffStore(on.state, 'gog', [{ id: 'a', title: 'A' }], false, true);
  assert.deepEqual(off.alerts, []);

  // While disabled the store is never fetched, so games come back different.
  const back = Model.diffStore(off.state, 'gog',
    [{ id: 'a', title: 'A' }, { id: 'z', title: 'Z' }], true, true);
  assert.deepEqual(back.alerts, [], 're-enabling flooded with backfill alerts');
  assert.equal(back.state.stores.gog.ids.length, 2, 'baseline should re-record');
});

test('toggling one store never disturbs another store baseline', () => {
  let state = Model.diffStore(Model.emptySeen(), 'steam', [{ id: 's1', title: 'S' }], true, true).state;
  state = Model.diffStore(state, 'epic', [{ id: 'e1', title: 'E' }], true, true).state;

  // Disable steam, change epic.
  let next = Model.diffStore(state, 'steam', [], false, true);
  next = Model.diffStore(next.state, 'epic', [{ id: 'e1', title: 'E' }, { id: 'e2', title: 'E2' }], true, true);
  assert.equal(next.alerts.length, 1);
  assert.equal(next.alerts[0].store, 'epic');
  assert.deepEqual(next.state.stores.steam.ids, ['s1'], 'steam baseline was lost');
});

test('seen state round-trips and survives a corrupt file', () => {
  const state = Model.diffStore(Model.emptySeen(), 'steam',
    [{ id: '405640', title: 'Pony Island' }], true, true).state;
  const round = Model.parseSeen(Model.serializeSeen(state));
  assert.deepEqual(round.stores.steam.ids, ['405640']);
  assert.equal(round.stores.steam.primed, true);

  // A primed store with recorded ids derives priming from the ids, so a
  // hand-edited file cannot silence the first alert forever.
  const handEdited = JSON.parse(Model.serializeSeen(state));
  handEdited.stores.steam.primed = false;
  assert.equal(Model.parseSeen(JSON.stringify(handEdited)).stores.steam.primed, true);

  for (const bad of ['', 'garbage', '[]', '"str"', 'null',
    '{"stores":{"steam":{"ids":["a b","../../etc/passwd"]}}}']) {
    const parsed = Model.parseSeen(bad);
    assert.equal(parsed.primed, false);
    for (const store of Model.STORES) {
      assert.ok(parsed.stores[store].ids.every(id => Model.scrubId(id) === id),
        `unsafe id survived: ${bad}`);
    }
  }
});

test('the widget publishes the same IPC target the notification calls', async () => {
  const widget = readFileSync(new URL('BarWidget.qml', root), 'utf8');
  assert.ok(widget.includes('ipcTarget: Model.IPC_TARGET'),
    'BarWidget.qml hardcodes its own ipcTarget instead of sharing Model.IPC_TARGET');
  assert.ok(Model.IPC_TARGET.length > 0, 'the IPC target is empty');
});

test('notification args are safe for the notification server', () => {
  const alerts = [{ id: 'a', title: '<b>Bold</b> Game', url: 'https://evil.test/x' }];
  const argv = Model.notificationArgs('steam', alerts);
  assert.equal(argv[0], 'omarchy-notification-send');
  assert.ok(!argv.includes('<'), 'markup survived into the notification');
  // The click opens the panel, so no URL rides along at all: there is no longer
  // a host to allow or reject, and nothing to leak into another application.
  assert.ok(!argv.some(a => a.includes('https://') || a.includes('evil.test')),
    'a URL reached the notification action');
  const exec = argv.slice(argv.indexOf('--exec') + 1);
  assert.deepEqual(exec, ['omarchy-shell', '-q', Model.IPC_TARGET, 'open'],
    'the notification no longer opens the panel');

  // The headline occupies an option position, so leading dashes must go.
  const flagged = Model.notificationArgs('steam',
    [{ id: 'a', title: '--exec', url: 'https://store.steampowered.com/app/1/' }]);
  const headline = flagged[flagged.indexOf('-t') + 2];
  assert.ok(!headline.startsWith('-'), `headline still looks like a flag: ${headline}`);

  assert.equal(Model.notificationArgs('steam', []), null);
  const many = Model.notificationArgs('epic',
    Array.from({ length: 7 }, (_, i) => ({ id: String(i), title: 'G' + i, url: '' })));
  // The headline is followed by the body, which is followed by --exec.
  const body = many[many.indexOf('--exec') - 1];
  assert.ok(body.includes('and 3 more'), `long list should summarise, got: ${body}`);
});

test('a store row says only why it failed, and nothing otherwise', () => {
  const errors = { gog: { message: 'Could not reach GOG' } };
  assert.equal(Model.storeErrorLabel('gog', errors), 'Could not reach GOG');
  // A healthy empty store and a store with games both say nothing at all.
  assert.equal(Model.storeErrorLabel('gog', {}), '');
  assert.equal(Model.storeErrorLabel('steam', {}), '');
  assert.equal(Model.storeErrorLabel('epic', undefined), '');
  // A 404 from GOG is a healthy empty store, so it must not surface as an error.
  assert.equal(Model.storeErrorLabel('gog', { gog: { httpStatus: 404, message: '' } }), '');
});

test('status copy reflects only the enabled stores', () => {
  const all = { steam: true, epic: true, gog: true };
  const games = { steam: { games: [{ id: 'a' }, { id: 'b' }] }, epic: { games: [] }, gog: { games: [] } };
  assert.equal(Model.statusTitle(games, all, false), '2 games free to keep');
  assert.equal(Model.statusTitle(games, { steam: true, epic: false, gog: false }, false),
    '2 games free to keep');
  assert.equal(Model.totalGames(games), 2);
  assert.equal(Model.statusTitle(games, { steam: false, epic: false, gog: false }, false),
    'No stores watched');
  assert.equal(Model.activeStores(all).length, 3);
});

test('freshness labels cross the stale threshold', () => {
  const now = 1000000000;
  const staleAt = Model.staleAfterMs(90);
  assert.equal(Model.freshnessLabel(0, now, false, staleAt), 'Not checked yet');
  assert.equal(Model.freshnessLabel(now, now, false, staleAt), 'Updated just now');
  assert.equal(Model.freshnessLabel(now - 60000, now, false, staleAt), 'Updated 1m ago');
  assert.equal(Model.freshnessLabel(now - staleAt, now, false, staleAt).startsWith('Stale'), true);
  // One tick short of the threshold is still fresh.
  assert.equal(Model.freshnessLabel(now - staleAt + 1, now, false, staleAt).startsWith('Stale'), false);
});

test('stale tracks the refresh interval instead of a fixed constant', () => {
  // The point of deriving it: at every interval, stale means "we may have
  // missed something", not "more than four hours have passed".
  for (const minutes of [30, 90, 180, 720]) {
    const expected = minutes * Model.STALE_MULTIPLIER * 60 * 1000;
    assert.equal(Model.staleAfterMs(minutes), expected,
      `stale should be ${Model.STALE_MULTIPLIER}x of a ${minutes} minute interval`);
    // Always later than one poll, so a single missed cycle does not read stale.
    assert.ok(expected > minutes * 60 * 1000, `${minutes}: stale must exceed one interval`);
  }
  // An out-of-range interval is normalised first, so it cannot produce a stale
  // threshold that disagrees with the settings slider.
  assert.equal(Model.staleAfterMs(0), Model.staleAfterMs(Model.normalizeRefreshMinutes(0)));
  assert.equal(Model.staleAfterMs('nonsense'), Model.staleAfterMs(90));
});

test('settings are normalised into safe ranges', () => {
  assert.equal(Model.normalizeRefreshMinutes(90), 90);
  assert.equal(Model.normalizeRefreshMinutes(0), 30);
  assert.equal(Model.normalizeRefreshMinutes(99999), 720);
  assert.equal(Model.normalizeRefreshMinutes('nonsense'), 90);
  assert.equal(Model.normalizeCountry(' de '), 'DE');
  assert.equal(Model.normalizeCountry('USA'), '', 'a two-letter code is required');
  assert.equal(Model.normalizeCountry('d3'), '');

  const on = Model.enabled({ steamEnabled: false });
  assert.equal(on.steam, false);
  assert.equal(on.epic, true, 'an absent setting keeps its default');
  assert.equal(Model.enabled(undefined).gog, true);
});

test('the panel headline is the plugin name and the count is a subtitle', () => {
  assert.equal(Model.heroTitle(), 'Loot Drops');
  const all = { steam: true, epic: true, gog: true };
  const four = { steam: { games: [{ id: 'a' }, { id: 'b' }] },
                 epic: { games: [{ id: 'c' }, { id: 'd' }] }, gog: { games: [] } };
  assert.equal(Model.heroDetail(four, all),
    '4 FREE GAMES FROM Steam, Epic, and GOG');

  // Singular, and a store with nothing free is still named as watched.
  const one = { steam: { games: [{ id: 'a' }] }, gog: { games: [] } };
  assert.equal(Model.heroDetail(one, all), '1 FREE GAME FROM Steam, Epic, and GOG');
  assert.equal(Model.heroDetail({ steam: { games: [] }, gog: { games: [] } }, all),
    '0 FREE GAMES FROM Steam, Epic, and GOG');
});

test('the store list names only the stores being watched', () => {
  // The subtitle uses short names because it is uppercased and letter-spaced;
  // the headers and notification headline keep the full ones.
  assert.equal(Model.storeList({ steam: true, epic: true, gog: true }),
    'Steam, Epic, and GOG');
  assert.equal(Model.storeList({ steam: true, epic: false, gog: true }), 'Steam, and GOG');
  assert.equal(Model.STORE_LABELS.epic, 'Epic Games', 'headers keep the full name');
  assert.equal(Model.STORE_SHORT.epic, 'Epic');
  assert.equal(Model.storeList({ steam: true, epic: false, gog: false }), 'Steam');
  assert.equal(Model.storeList({ steam: false, epic: false, gog: false }), '');
  assert.equal(Model.storeList(null), '');
  // With nothing watched the headline must not read "...from " with no list.
  assert.equal(Model.heroDetail({ steam: { games: [{ id: 'a' }] } },
    { steam: false, epic: false, gog: false }), 'Turn a store on to start watching');
});

test('the bar icon is a private-use treasure chest that takes a theme colour', () => {
  const code = Model.BAR_ICON.codePointAt(0);
  // Two private-use planes: BMP U+E000-F8FF, and Plane 15 at U+F0000-FFFFD. The
  // Nerd Fonts Material Design block sits in the second.
  assert.ok((code >= 0xe000 && code <= 0xf8ff)
    || (code >= 0xf0000 && code <= 0xffffd),
    `BAR_ICON U+${code.toString(16)} is not private-use, so it could paint its
     own colour instead of the theme's`);
  // U+26A1 carries Emoji_Presentation=Yes and rendered yellow in every theme.
  assert.notEqual(code, 0x26a1);
  assert.equal(code, 0xf0726, 'the treasure chest mark moved between Nerd Fonts releases');
});

test('the new-game marker is a private-use coin that takes a theme colour', () => {
  const code = Model.NEW_GAME_GLYPH.codePointAt(0);
  // BMP private-use, like the bar icon: no emoji presentation, so it renders
  // monochrome and takes the accent the row gives it.
  assert.ok(code >= 0xe000 && code <= 0xf8ff,
    `NEW_GAME_GLYPH U+${code.toString(16)} is not private-use`);
  // Nerd Fonts 3.5.1: EDE8 is fa-coins. F51E, the old Font Awesome coins
  // position, is oct-stack there, which is why the mark moved.
  assert.equal(code, 0xede8, 'the coins mark is U+EDE8');
  assert.equal(Model.NEW_GAME_GLYPH.length, 1);
});

test('a game is marked seen one at a time, and siblings stay unseen', () => {
  const fresh = Model.emptySeen();
  const onOffer = { steam: { games: [{ id: 'a' }, { id: 'b' }] },
                    epic: { games: [{ id: 'c' }] }, gog: { games: [] } };

  // A first install shows the dot: nobody has looked yet.
  assert.deepEqual(Model.unseenIds(fresh, onOffer), ['a', 'b', 'c']);
  assert.equal(Model.hasUnseen(fresh, onOffer), true);

  // Acknowledging one game clears only that one.
  const one = Model.acknowledgeGame(fresh, 'steam', 'a');
  assert.deepEqual(Model.unseenIds(one, onOffer), ['b', 'c']);

  // Acknowledging the rest goes quiet, and marking again is a no-op.
  let all = Model.acknowledgeGame(one, 'steam', 'b');
  all = Model.acknowledgeGame(all, 'epic', 'c');
  assert.equal(Model.hasUnseen(all, onOffer), false);
  assert.deepEqual(Model.acknowledgedOf(Model.acknowledgeGame(all, 'steam', 'a'), 'steam'),
    ['a', 'b'], 'marking an already-seen game must not duplicate it');

  // A game arriving afterwards lights it again, and only for that game.
  const later = Object.assign({}, onOffer, {
    steam: { games: [{ id: 'a' }, { id: 'b' }, { id: 'NEW' }] },
  });
  assert.deepEqual(Model.unseenIds(all, later), ['NEW']);

  // A game leaving does not resurrect anything.
  const gone = { steam: { games: [{ id: 'a' }] }, epic: { games: [] }, gog: { games: [] } };
  assert.deepEqual(Model.unseenIds(all, gone), []);
});

test('a seen game can be forgotten again, toggling its marker back', () => {
  let state = Model.emptySeen();
  const onOffer = { steam: { games: [{ id: 'a' }, { id: 'b' }] } };
  state = Model.acknowledgeGame(state, 'steam', 'a');
  state = Model.acknowledgeGame(state, 'steam', 'b');
  assert.deepEqual(Model.unseenIds(state, onOffer), []);

  // Forgetting one brings only that one back.
  state = Model.forgetGame(state, 'steam', 'a');
  assert.deepEqual(Model.unseenIds(state, onOffer), ['a']);
  assert.deepEqual(Model.acknowledgedOf(state, 'steam'), ['b']);

  // Forgetting a game that is not acknowledged, or an unknown store, is a
  // no-op rather than a throw.
  assert.deepEqual(Model.acknowledgedOf(Model.forgetGame(state, 'steam', 'zzz'), 'steam'), ['b']);
  assert.deepEqual(Model.acknowledgedOf(Model.forgetGame(state, 'nope', 'b'), 'steam'), ['b']);
});

test('the unseen set is independent of the notification baseline', () => {
  // diffStore records ids for notification; acknowledgeGame records ids for
  // having looked. A game can be in the first and not the second, which is
  // exactly the case the dot exists for.
  let state = Model.diffStore(Model.emptySeen(), 'steam',
    [{ id: 'a', title: 'A' }], true, true).state;
  const offered = { steam: { games: [{ id: 'a' }] }, epic: { games: [] }, gog: { games: [] } };
  assert.equal(Model.hasUnseen(state, offered), true,
    'already announced is not the same as already seen');

  state = Model.acknowledgeGame(state, 'steam', 'a');
  assert.equal(Model.hasUnseen(state, offered), false);

  // A muted store is still unwatched, so it still reports unseen games.
  const muted = Model.diffStore(state, 'steam', [{ id: 'a' }, { id: 'z' }], true, false);
  const withZ = { steam: { games: [{ id: 'a' }, { id: 'z' }] }, epic: { games: [] }, gog: { games: [] } };
  assert.deepEqual(Model.unseenIds(muted.state, withZ), ['z']);
});

test('acknowledged ids survive a round trip and ignore junk', () => {
  let state = Model.acknowledgeGame(Model.emptySeen(), 'steam', '405640');
  state = Model.acknowledgeGame(state, 'steam', '2990600');
  const round = Model.parseSeen(Model.serializeSeen(state));
  assert.deepEqual(Model.acknowledgedOf(round, 'steam'), ['2990600', '405640']);

  // An unusable id and an unknown store change nothing. acknowledgedOf keeps
  // insertion order, so compare sorted.
  assert.deepEqual(Model.acknowledgedOf(Model.acknowledgeGame(state, 'steam', 'a b'), 'steam').sort(),
    ['2990600', '405640'], 'a non-id must not enter the acknowledged set');
  assert.deepEqual(Model.acknowledgedOf(Model.acknowledgeGame(state, 'nope', 'x'), 'steam').sort(),
    ['2990600', '405640'], 'an unknown store must not be acknowledged');

  // A corrupt or hostile file cannot inject ids that were never acknowledged.
  for (const bad of ['', 'garbage', '[]', 'null',
    '{"stores":{"steam":{"acknowledged":["a b","../../etc/passwd",""]}}}']) {
    const parsed = Model.parseSeen(bad);
    for (const store of Model.STORES) {
      assert.ok(Model.acknowledgedOf(parsed, store)
        .every(id => Model.scrubId(id) === id), `unsafe id survived: ${bad}`);
    }
  }

  // A store that has never been acknowledged reports nothing seen.
  assert.deepEqual(Model.acknowledgedOf(Model.emptySeen(), 'gog'), []);
});

test('every store has a header mark, and the real logos are private-use', () => {
  // Steam and GOG use the Material Design marks in Nerd Fonts 3.5.1. Both are
  // private-use codepoints, so they render monochrome and take the theme colour;
  // an emoji-presentation codepoint here would paint its own colour instead.
  const steam = Model.STORE_GLYPHS.steam.codePointAt(0);
  const gog = Model.STORE_GLYPHS.gog.codePointAt(0);
  // Two private-use planes: BMP U+E000-F8FF, and Plane 15 at U+F0000-FFFFD.
  // The Nerd Fonts Material Design block sits in the second of these.
  const privateUse = c => (c >= 0xe000 && c <= 0xf8ff)
    || (c >= 0xf0000 && c <= 0xffffd);
  for (const [name, code] of [['steam', steam], ['gog', gog]]) {
    assert.ok(privateUse(code),
      `the ${name} mark U+${code.toString(16)} is not private-use`);
  }
  assert.equal(steam, 0xf04d3, 'the steam mark moved between Nerd Fonts releases');
  assert.equal(gog, 0xf0ba1, 'the gog mark moved between Nerd Fonts releases');

  // Nerd Fonts ships no Epic mark. The real Epic shield was tried here and is
  // unusable at eleven pixels: carrying "EPIC GAMES" lettering inside the
  // outline it fills into a blob, and stripped to just the outer edge it is
  // still a featureless silhouette. So Epic gets the one generic mark that
  // still reads as a shop at that size.
  const epic = Model.STORE_GLYPHS.epic.codePointAt(0);
  assert.ok(privateUse(epic), `the epic mark U+${epic.toString(16)} is not private-use`);
  assert.equal(epic, 0xf04dc, 'the epic mark moved between Nerd Fonts releases');

  // No store may be left without a mark.
  for (const store of Model.STORES) {
    const mark = Model.STORE_GLYPHS[store];
    assert.equal(typeof mark, 'string', `${store} has no mark`);
    assert.ok(mark.length > 0, `${store} has an empty mark`);
  }
});

test('the hourglass is a private-use mark, pinned to its Nerd Fonts codepoint', () => {
  const code = Model.HOURGLASS_GLYPH.codePointAt(0);
  assert.ok(code >= 0xe000 && code <= 0xf8ff,
    `the hourglass U+${code.toString(16)} is not private-use`);
  assert.equal(code, 0xf253, 'the hourglass moved between Nerd Fonts releases');
});

test('ending soon is a one-day window that survives an elapsed end date', () => {
  const now = Date.parse('2026-10-16T12:00:00Z');
  const iso = hours => new Date(now + hours * 3600 * 1000).toISOString();

  assert.equal(Model.endingSoon(iso(48), now), false, 'two days out is not soon');
  assert.equal(Model.endingSoon(iso(24.5), now), false, 'just beyond the window');
  assert.equal(Model.endingSoon(iso(24), now), true, 'exactly one day counts');
  assert.equal(Model.endingSoon(iso(1), now), true, 'within the window');
  // The whole point of the unbounded check: a lapsed giveaway keeps its mark
  // until a refresh drops the row or moves the date back out.
  assert.equal(Model.endingSoon(iso(-48), now), true, 'an elapsed end date stays marked');

  // Unknown or malformed dates must not mark a row, so those rows read as before.
  for (const bad of ['', 'not a date', null, undefined]) {
    assert.equal(Model.endingSoon(bad, now), false, `marked on a bad date: ${bad}`);
  }
});
