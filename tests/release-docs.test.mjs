import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { releaseDocuments } from '../scripts/release-docs.mjs';

const ARCHIVE = 'loot-drops-v0.5.0-source.tar.gz';
const digestOf = text => crypto.createHash('sha256').update(Buffer.from(text, 'utf8')).digest('hex');

const fixture = () => ({
  slug: 'loot-drops',
  version: '0.5.0',
  tag: 'v0.5.0',
  repository: 'https://github.com/salmun-nister/omarchy-loot-drops',
  commit: 'a'.repeat(40),
  tree: 'b'.repeat(40),
  created: '2026-11-20T10:00:00Z',
  archive: { name: ARCHIVE, bytes: 4096, sha256: 'c'.repeat(64) },
  copyright: 'Copyright (c) 2026 salmun-nister',
});

const byName = input => {
  const documents = releaseDocuments(input ? { ...fixture(), ...input } : fixture());
  return { documents, text: Object.fromEntries(documents.map(d => [d.name, d.text])) };
};

test('emits the four published documents in upload order', () => {
  const { documents } = byName();
  assert.deepEqual(documents.map(d => d.name),
    ['SOURCE-MANIFEST.json', 'SBOM.spdx.json', 'RELEASE-MANIFEST.json', 'SHA256SUMS']);
  for (const document of documents) {
    assert.equal(typeof document.text, 'string');
    assert.ok(document.text.endsWith('\n'), `${document.name} must end with a newline`);
  }
});

test('both manifests bind one version, repository, commit and tree', () => {
  const { text } = byName();
  const expected = { repository: fixture().repository, commit: 'a'.repeat(40), tree: 'b'.repeat(40) };
  for (const name of ['SOURCE-MANIFEST.json', 'RELEASE-MANIFEST.json']) {
    const document = JSON.parse(text[name]);
    assert.equal(document.schemaVersion, 1);
    assert.equal(document.version, '0.5.0');
    assert.deepEqual(document.source, expected);
    assert.deepEqual(document.artifacts, [{ name: ARCHIVE, bytes: 4096, sha256: 'c'.repeat(64) }]);
  }
});

test('the release manifest lists exactly the two documents it ships with', () => {
  const { text } = byName();
  const release = JSON.parse(text['RELEASE-MANIFEST.json']);
  assert.deepEqual(release.releaseDocuments, ['SOURCE-MANIFEST.json', 'SBOM.spdx.json'].map(name => ({
    name,
    bytes: Buffer.byteLength(text[name]),
    sha256: digestOf(text[name]),
  })));
});

test('the SBOM is one SPDX 2.3 package bound to the version and commit', () => {
  const { text } = byName();
  const sbom = JSON.parse(text['SBOM.spdx.json']);
  assert.equal(sbom.spdxVersion, 'SPDX-2.3');
  assert.equal(sbom.dataLicense, 'CC0-1.0');
  assert.equal(sbom.name, 'loot-drops-0.5.0');
  assert.equal(sbom.documentNamespace,
    `https://github.com/salmun-nister/omarchy-loot-drops/spdx/0.5.0-${'a'.repeat(40)}`);
  assert.equal(sbom.creationInfo.created, '2026-11-20T10:00:00Z');
  assert.equal(sbom.packages.length, 1);
  const [pkg] = sbom.packages;
  assert.equal(pkg.name, 'loot-drops');
  assert.equal(pkg.versionInfo, '0.5.0');
  assert.ok(pkg.downloadLocation.endsWith(`@${'a'.repeat(40)}`), 'package must name the commit');
  assert.equal(pkg.filesAnalyzed, false);
  assert.equal(pkg.licenseDeclared, 'MIT');
  assert.ok(sbom.documentDescribes.includes(pkg.SPDXID));
  assert.ok(pkg.sourceInfo.includes(`tree ${'b'.repeat(40)}`));
});

test('SHA256SUMS covers every manifested file plus the release manifest', () => {
  const { text } = byName();
  const sums = new Map();
  for (const line of text.SHA256SUMS.trimEnd().split('\n')) {
    const match = /^([a-f0-9]{64})  ([^/\s]+)$/.exec(line);
    assert.ok(match, `Malformed checksum line: ${line}`);
    assert.ok(!sums.has(match[2]), `Duplicate checksum entry: ${match[2]}`);
    sums.set(match[2], match[1]);
  }
  assert.deepEqual([...sums.keys()].sort(),
    ['RELEASE-MANIFEST.json', 'SBOM.spdx.json', 'SOURCE-MANIFEST.json', ARCHIVE]);
  assert.equal(sums.get(ARCHIVE), 'c'.repeat(64));
  for (const name of ['SOURCE-MANIFEST.json', 'SBOM.spdx.json', 'RELEASE-MANIFEST.json']) {
    assert.equal(sums.get(name), digestOf(text[name]), `${name} digest must match its own bytes`);
  }
});

test('the same commit always produces the same documents', () => {
  assert.deepEqual(releaseDocuments(fixture()), releaseDocuments(fixture()));
});

test('refuses an unsafe asset name', () => {
  for (const name of ['../escape.tar.gz', 'nested/file.tar.gz', '', '.']) {
    assert.throws(() => releaseDocuments({ ...fixture(), archive: { ...fixture().archive, name } }),
      /Invalid archive name/);
  }
});

test('refuses an identity that does not hold together', () => {
  const bad = [
    [{ tag: 'v0.4.7' }, /Tag must match the version/],
    [{ version: '0.4' }, /Invalid version/],
    [{ commit: 'HEAD' }, /Invalid commit/],
    [{ tree: 'b'.repeat(39) }, /Invalid tree/],
    [{ created: '2026-11-20 10:00' }, /Creation time must be a UTC timestamp/],
    [{ repository: 'github.com/x/y' }, /Invalid repository URL/],
    [{ archive: { ...fixture().archive, bytes: 0 } }, /Invalid archive size/],
    [{ archive: { ...fixture().archive, sha256: 'SKIP' } }, /Invalid archive digest/],
    [{ copyright: '' }, /Invalid copyright/],
  ];
  for (const [override, message] of bad) {
    assert.throws(() => releaseDocuments({ ...fixture(), ...override }), message);
  }
});
