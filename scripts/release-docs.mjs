// The provenance documents published beside a source archive: two manifests
// that bind the assets to one commit, and an SPDX SBOM for the package. They
// live here rather than in archive.mjs so their shape can be tested without a
// tagged checkout. The marketplace release preflight audits exactly this
// contract against the downloaded assets, so keep the two in step.
import { hash } from './template.mjs';

const COMMIT = /^[a-f0-9]{40}$/;
const SHA256 = /^[a-f0-9]{64}$/;
const SEMVER = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;
const CREATED = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

const json = value => JSON.stringify(value, null, 2) + '\n';
const digest = text => hash(Buffer.from(text, 'utf8'));

function assert(condition, message) {
  if (!condition) throw Error(message);
}

// A plain file name, never a path: the assets are uploaded next to each other.
function plainName(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 255
    && !value.includes('/') && !value.includes('\\') && !value.includes('\0')
    && value !== '.' && value !== '..';
}

/**
 * Build every document that ships with the archive, in upload order.
 *
 * `created` is the commit's own date rather than the wall clock, so the same
 * commit always produces the same bytes.
 */
export function releaseDocuments({ slug, version, tag, repository, commit, tree, created, archive, license = 'MIT', copyright }) {
  assert(/^[a-z][a-z0-9-]*$/.test(slug || ''), 'Invalid slug');
  assert(SEMVER.test(version || ''), 'Invalid version');
  assert(tag === `v${version}`, 'Tag must match the version');
  assert(/^https:\/\/[^\s]+$/.test(repository || ''), 'Invalid repository URL');
  assert(COMMIT.test(commit || ''), 'Invalid commit');
  assert(COMMIT.test(tree || ''), 'Invalid tree');
  assert(CREATED.test(created || ''), 'Creation time must be a UTC timestamp');
  assert(typeof license === 'string' && license.length > 0, 'Invalid licence');
  assert(typeof copyright === 'string' && copyright.length > 0, 'Invalid copyright');
  assert(archive && plainName(archive.name), 'Invalid archive name');
  assert(Number.isSafeInteger(archive.bytes) && archive.bytes > 0, 'Invalid archive size');
  assert(SHA256.test(archive.sha256 || ''), 'Invalid archive digest');

  const source = {
    schemaVersion: 1,
    version,
    source: { repository, commit, tree },
    artifacts: [{ name: archive.name, bytes: archive.bytes, sha256: archive.sha256 }],
  };
  const sourceText = json(source);

  const sbom = {
    spdxVersion: 'SPDX-2.3',
    dataLicense: 'CC0-1.0',
    SPDXID: 'SPDXRef-DOCUMENT',
    name: `${slug}-${version}`,
    documentNamespace: `${repository}/spdx/${version}-${commit}`,
    creationInfo: { created, creators: ['Tool: scripts/archive.mjs'] },
    documentDescribes: [`SPDXRef-Package-${slug}`],
    packages: [{
      name: slug,
      SPDXID: `SPDXRef-Package-${slug}`,
      versionInfo: version,
      downloadLocation: `git+${repository}@${commit}`,
      filesAnalyzed: false,
      licenseConcluded: license,
      licenseDeclared: license,
      copyrightText: copyright,
      sourceInfo: `Tag ${tag}, tree ${tree}`,
    }],
  };
  const sbomText = json(sbom);

  const releaseDocuments = [
    { name: 'SOURCE-MANIFEST.json', bytes: Buffer.byteLength(sourceText), sha256: digest(sourceText) },
    { name: 'SBOM.spdx.json', bytes: Buffer.byteLength(sbomText), sha256: digest(sbomText) },
  ];
  const release = {
    schemaVersion: 1,
    version,
    source: { repository, commit, tree },
    artifacts: [{ name: archive.name, bytes: archive.bytes, sha256: archive.sha256 }],
    releaseDocuments,
  };
  const releaseText = json(release);

  // The sums must cover every manifested file, plus the manifest that names
  // them, which cannot name itself.
  const sums = [
    [archive.sha256, archive.name],
    [releaseDocuments[0].sha256, releaseDocuments[0].name],
    [releaseDocuments[1].sha256, releaseDocuments[1].name],
    [digest(releaseText), 'RELEASE-MANIFEST.json'],
  ].map(([sha256, name]) => `${sha256}  ${name}\n`).join('');

  return [
    { name: 'SOURCE-MANIFEST.json', text: sourceText },
    { name: 'SBOM.spdx.json', text: sbomText },
    { name: 'RELEASE-MANIFEST.json', text: releaseText },
    { name: 'SHA256SUMS', text: sums },
  ];
}
