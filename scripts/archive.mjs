#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { root, readJSON, hash } from './template.mjs';
import { check } from './check.mjs';
import { releaseDocuments } from './release-docs.mjs';

try {
  const c=check();
  if(!c.initialized)throw Error('Initialize a real project before preparing a release');
  const tag=process.env.RELEASE_TAG;
  if(!/^v\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$/.test(tag||''))throw Error('Set RELEASE_TAG to a semantic version tag');
  const git=(...args)=>{const r=spawnSync('git',args,{cwd:root,encoding:'utf8'});if(r.status!==0)throw Error(r.stderr);return r.stdout.trim();};
  if(git('status','--porcelain'))throw Error('Release requires a clean checkout');
  if(git('rev-parse',`${tag}^{commit}`)!==git('rev-parse','HEAD'))throw Error('Release tag must resolve to this exact commit');
  const a=readJSON(path.join(root,'docs/ACCEPTANCE.json'));
  if(a.status!=='passed'||!a.platform||!a.date||!Array.isArray(a.commands)||!a.commands.length||!Array.isArray(a.results)||!a.results.length||!/^[a-f0-9]{40}$/.test(a.input_commit||''))throw Error('Record actual acceptance evidence before release');
  // Evidence may be recorded in a later docs-only commit, never after a runtime change.
  git('merge-base','--is-ancestor',a.input_commit,'HEAD');
  const changed=git('diff','--name-only',a.input_commit,'HEAD').split('\n').filter(Boolean);
  if(changed.some(f=>!f.startsWith('docs/')&&!['README.md','CREDITS.md'].includes(f)))throw Error('Runtime/build inputs changed after acceptance');
  if(fs.readFileSync(path.join(root,'VERSION'),'utf8').trim()!==tag.slice(1))throw Error('VERSION must match tag');
  if(c.kind==='plugin' && readJSON(path.join(root,'manifest.json')).version!==tag.slice(1))throw Error('Manifest version must match tag');
  if(c.kind==='app' && !fs.readFileSync(path.join(root,'Cargo.toml'),'utf8').includes(`version = "${tag.slice(1)}"`))throw Error('Cargo version must match tag');
  if(c.kind==='package' && !fs.readFileSync(path.join(root,`pkgbuilds/${c.slug}/PKGBUILD`),'utf8').includes(`pkgver=${tag.slice(1)}\n`))throw Error('Package version must match tag');
  const out=path.join(root,'dist');fs.mkdirSync(out,{recursive:true});
  const archive=path.join(out,`${c.slug}-${tag}-source.tar.gz`);
  const r=spawnSync('git',['archive','--format=tar.gz',`--prefix=${c.slug}/`,'-o',archive,'HEAD'],{cwd:root,encoding:'utf8'});
  if(r.status!==0)throw Error(r.stderr);
  const archiveBytes=fs.readFileSync(archive);
  // The commit's own date keeps the documents reproducible: the same tag
  // always yields the same bytes, so a rebuilt release matches its manifest.
  const created=new Date(git('show','-s','--format=%cI','HEAD')).toISOString().replace(/\.\d{3}Z$/,'Z');
  const documents=releaseDocuments({
    slug:c.slug,
    version:tag.slice(1),
    tag,
    repository:`https://github.com/${c.owner}/${c.repo}`,
    commit:git('rev-parse','HEAD'),
    tree:git('rev-parse','HEAD^{tree}'),
    created,
    archive:{name:path.basename(archive),bytes:archiveBytes.length,sha256:hash(archiveBytes)},
    copyright:`Copyright (c) ${c.year} ${c.owner}`,
  });
  for(const document of documents)fs.writeFileSync(path.join(out,document.name),document.text);
  console.log(`Created ${path.basename(archive)} with ${documents.map(d=>d.name).join(', ')}. This is a source archive, not an installable application binary.`);
} catch(e){console.error(e.message);process.exitCode=1;}
