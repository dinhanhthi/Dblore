const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
function loadCatalog() {
  return vm.runInNewContext(`${fs.readFileSync(path.join(__dirname, 'features-data.js'), 'utf8')}\nFEATURES`);
}

test('catalog has stable unique IDs, descriptions, actual versions and source provenance', () => {
  const features = loadCatalog();
  const versions = new Set(execFileSync('git', ['tag', '--list'], { cwd: root, encoding: 'utf8' }).trim().split('\n').map(tag => tag.replace(/^v/, '')));
  // Release preparation updates the catalog before CI creates the target tag.
  const project = fs.readFileSync(path.join(root, 'Dblore.xcodeproj/project.pbxproj'), 'utf8');
  for (const match of project.matchAll(/MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+);/g)) versions.add(match[1]);
  versions.add('Unreleased');
  versions.add('Unknown');
  assert.ok(features.length > 0);
  const ids = new Set();
  const descriptions = new Set();
  for (const entry of features) {
    assert.ok(Number.isSafeInteger(entry.id) && entry.id > 0, entry.feature);
    assert.ok(!ids.has(entry.id), `Duplicate ID ${entry.id}`);
    assert.ok(typeof entry.feature === 'string' && entry.feature.trim(), `Missing description for ${entry.id}`);
    assert.ok(!descriptions.has(entry.feature), `Duplicate feature ${entry.feature}`);
    assert.ok(versions.has(entry.version), `Invalid version ${entry.version}`);
    assert.ok(Array.isArray(entry.sources) && entry.sources.length, `Missing source for ${entry.id}`);
    for (const source of entry.sources) assert.ok(fs.existsSync(path.join(root, source)), `Missing source ${source}`);
    assert.match(entry.commit, /^[0-9a-f]{8,40}$/, `Missing commit for ${entry.id}`);
    assert.ok(typeof entry.evidence === 'string' && entry.evidence.trim(), `Missing availability evidence for ${entry.id}`);
    ids.add(entry.id);
    descriptions.add(entry.feature);
  }
});

test('catalog preserves source-verified gestures, protection choices and parameter/export actions', () => {
  const features = loadCatalog();
  for (const [description, version] of [
    ['Double-click a result cell to edit its value inline', '0.1.0'],
    ['Double-click a favorite to insert its SQL into the editor', '0.3.0'],
    ['Open a query history entry in the detail modal', '0.4.0'],
  ]) {
    assert.equal(features.find(entry => entry.feature === description)?.version, version, description);
  }
  assert.ok(!features.some(entry => /double-click.*history/i.test(entry.feature) && /always/i.test(entry.feature)));
  const protection = features.find(entry => entry.id === 96);
  assert.equal(protection.feature, 'Choose among None, Schema Protected and Read-Only connection protection levels');
  assert.equal(protection.version, '0.1.0');
  for (const [id, description, version] of [
    [272, 'Export a result chart as a PNG image', '0.4.0'],
    [273, 'Edit and bind named SQL parameters in the SQL editor sidebar', '0.5.0'],
    [274, 'Choose whether notebook cell parameter values are saved in the file', '0.5.0'],
  ]) {
    const entry = features.find(entry => entry.id === id);
    assert.equal(entry?.feature, description, `Missing source-backed capability ${id}`);
    assert.equal(entry.version, version, description);
  }

});

function loadPageLogic() {
  const context = vm.createContext({ URL, URLSearchParams });
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'features.js'), 'utf8'), context);
  return context;
}

const sampleFeatures = [
  { id: 2, feature: 'Zoo', version: '0.9.0' },
  { id: 10, feature: 'alpha', version: '0.10.0' },
  { id: 3, feature: 'Alpha', version: 'Unreleased' },
  { id: 4, feature: 'Bravo', version: 'Unknown' },
];

test('sorts without mutating the catalog, with numeric IDs, alphabetical names and numeric versions', () => {
  const { sortFeatures } = loadPageLogic();
  const ids = (column, direction) => Array.from(sortFeatures(sampleFeatures, column, direction), entry => entry.id);
  assert.deepEqual(ids('id', 'descending'), [10, 4, 3, 2]);
  assert.deepEqual(ids('id', 'ascending'), [2, 3, 4, 10]);
  assert.deepEqual(ids('feature', 'ascending'), [3, 10, 4, 2]);
  assert.deepEqual(ids('feature', 'descending'), [2, 4, 3, 10]);
  assert.deepEqual(ids('version', 'ascending'), [2, 10, 3, 4]);
  assert.deepEqual(ids('version', 'descending'), [4, 3, 10, 2]);
  assert.deepEqual(sampleFeatures.map(entry => entry.id), [2, 10, 3, 4]);
});

test('fuzzy search handles accents, multiword abbreviations and single-character typos', () => {
  const { filterFeatures } = loadPageLogic();
  const entries = [
    { id: 1, feature: 'Double-click a result cell to edit its value inline' },
    { id: 2, feature: 'Open a query history entry in the detail modal' },
    { id: 3, feature: 'Save a café favorite' },
  ];
  for (const query of ['RES cell', 'reslt edit', 'resuult edit', 'rezult edit', 'rslt inln']) {
    assert.deepEqual(Array.from(filterFeatures(entries, query), entry => entry.id), [1], query);
  }
  assert.deepEqual(Array.from(filterFeatures(entries, 'cafe'), entry => entry.id), [3]);
  assert.deepEqual(Array.from(filterFeatures(entries, 'history xyznonexistent'), entry => entry.id), []);
  assert.deepEqual(Array.from(filterFeatures(entries, '  '), entry => entry.id), [1, 2, 3]);
});

test('issue links encode the feature title and use templates for visitor-friendly default labels', () => {
  const { featureIssueURL } = loadPageLogic();
  const title = 'Copy SQL & "quoted" values + café';
  const url = new URL(featureIssueURL(title));
  assert.equal(url.origin + url.pathname, 'https://github.com/dinhanhthi/Dblore/issues/new');
  assert.equal(url.searchParams.get('title'), `Bug: ${title}`);
  assert.equal(url.searchParams.get('template'), 'bug_report.md');
  assert.equal(url.searchParams.has('labels'), false);
});
