// проверки установщика на настоящем маленьком приложении: ditto, PlistBuddy, codesign и xattr работают по-настоящему
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { assertChecksum, bundleIdentifier, install, parseArguments, releaseAssetURL } from './cli.mjs';

let workspace;

before(async () => {
  workspace = await mkdtemp(path.join(tmpdir(), 'lidfold-installer-'));
});

after(async () => {
  await rm(workspace, { recursive: true, force: true });
});

/** собирает подписанный ad-hoc Lidfold.app и zip выпуска с ним */
async function packRelease(name, { version, identifier }) {
  const root = path.join(workspace, name);
  const app = path.join(root, 'Lidfold.app');
  await mkdir(path.join(app, 'Contents/MacOS'), { recursive: true });
  await writeFile(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Lidfold</string>
<key>CFBundleIdentifier</key><string>${identifier}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
</dict></plist>
`);
  await writeFile(path.join(app, 'Contents/MacOS/Lidfold'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', app]);
  const asset = `Lidfold-v${version}-macos-arm64.zip`;
  const archive = path.join(root, asset);
  execFileSync('/usr/bin/ditto', ['-c', '-k', '--keepParent', app, archive]);
  const sha256 = createHash('sha256').update(await readFile(archive)).digest('hex');
  return { archive, release: { version, repository: 'boundlessend/lidfold', asset, sha256 } };
}

function copyFrom(archive) {
  return async (url, destination) => {
    assert.match(url, /^https:\/\/github\.com\/boundlessend\/lidfold\/releases\/download\/v/);
    await copyFile(archive, destination);
  };
}

test('разбор параметров', () => {
  assert.deepEqual(parseArguments([]), { applications: '/Applications', replace: false, clearQuarantine: false, help: false });
  const parsed = parseArguments(['--replace', '--clear-quarantine', '--applications', 'Apps']);
  assert.equal(parsed.replace, true);
  assert.equal(parsed.clearQuarantine, true);
  assert.equal(parsed.applications, path.resolve('Apps'));
  assert.throws(() => parseArguments(['--applications']), /Непонятный параметр/);
  assert.throws(() => parseArguments(['--applications', '--replace']), /Непонятный параметр/);
  assert.throws(() => parseArguments(['--force']), /Непонятный параметр/);
});

test('описание выпуска проверяется до скачивания', () => {
  const good = { version: '1.2.3', repository: 'boundlessend/lidfold', asset: 'Lidfold-v1.2.3-macos-arm64.zip', sha256: 'a'.repeat(64) };
  assert.equal(releaseAssetURL(good),
    'https://github.com/boundlessend/lidfold/releases/download/v1.2.3/Lidfold-v1.2.3-macos-arm64.zip');
  assert.throws(() => releaseAssetURL({ ...good, version: '1.2' }), /X\.Y\.Z/);
  assert.throws(() => releaseAssetURL({ ...good, repository: 'evil.com/../x' }), /владелец\/имя/);
  assert.throws(() => releaseAssetURL({ ...good, asset: 'Other.zip' }), /ожидался/);
  assert.throws(() => releaseAssetURL({ ...good, sha256: 'z'.repeat(64) }), /SHA-256/);
  assert.throws(() => assertChecksum(Buffer.from('архив'), 'a'.repeat(64)), /не совпал/);
});

test('чистая установка ставит карантин, повтор без --replace отказывает', async () => {
  const { archive, release } = await packRelease('fresh', { version: '0.1.0', identifier: bundleIdentifier });
  const applications = path.join(workspace, 'fresh-apps');
  const result = await install({ applications, replace: false, clearQuarantine: false }, release, copyFrom(archive));
  assert.equal(result.version, '0.1.0');
  assert.equal(result.backup, null);
  const quarantine = execFileSync('/usr/bin/xattr', ['-p', 'com.apple.quarantine', result.destination], { encoding: 'utf8' });
  assert.match(quarantine, /lidfold-install/);
  await assert.rejects(install({ applications, replace: false, clearQuarantine: false }, release, copyFrom(archive)), /уже установлен/);
  assert.deepEqual((await readdir(applications)).sort(), ['Lidfold.app']);
});

test('обновление сохраняет прежнюю копию и снимает карантин по просьбе', async () => {
  const first = await packRelease('old', { version: '0.1.0', identifier: bundleIdentifier });
  const second = await packRelease('new', { version: '0.2.0', identifier: bundleIdentifier });
  const applications = path.join(workspace, 'update-apps');
  await install({ applications, replace: false, clearQuarantine: false }, first.release, copyFrom(first.archive));
  const result = await install({ applications, replace: true, clearQuarantine: true }, second.release, copyFrom(second.archive));
  assert.equal(result.version, '0.2.0');
  assert.ok(result.backup);
  assert.throws(() => execFileSync('/usr/bin/xattr', ['-p', 'com.apple.quarantine', result.destination], { stdio: 'pipe' }));
  const entries = (await readdir(applications)).sort();
  assert.equal(entries.length, 2);
  assert.ok(entries.includes('Lidfold.app'));
});

test('подменённый архив и чужое приложение не устанавливаются', async () => {
  const good = await packRelease('checksum', { version: '0.3.0', identifier: bundleIdentifier });
  const applications = path.join(workspace, 'guarded-apps');
  const tampered = { ...good.release, sha256: 'b'.repeat(64) };
  await assert.rejects(install({ applications, replace: false, clearQuarantine: false }, tampered, copyFrom(good.archive)), /не совпал/);

  const stranger = await packRelease('stranger', { version: '0.3.0', identifier: 'com.example.other' });
  await assert.rejects(install({ applications, replace: false, clearQuarantine: false }, stranger.release, copyFrom(stranger.archive)),
    /ожидался local\.boundlessend\.lidfold/);
  assert.deepEqual(await readdir(applications), [], 'после отказа в папке ничего не остаётся');
});
