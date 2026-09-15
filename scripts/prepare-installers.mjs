#!/usr/bin/env node
// закрепляет собранный архив выпуска в installer/release.json и формуле Homebrew Casks/lidfold.rb
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { bundleIdentifier, plistValue, releaseAssetURL } from '../installer/cli.mjs';

const repository = 'boundlessend/lidfold';
const projectRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

const [archiveArgument, ...unexpected] = process.argv.slice(2);
if (!archiveArgument || unexpected.length > 0) {
  console.error('Использование: node scripts/prepare-installers.mjs dist/Lidfold-vВЕРСИЯ-macos-arm64.zip');
  process.exit(2);
}
const zipPath = path.resolve(archiveArgument);

/** версия из project.yml, которая должна совпадать с package.json */
async function projectVersion() {
  const manifest = JSON.parse(await readFile(path.join(projectRoot, 'package.json'), 'utf8'));
  const project = await readFile(path.join(projectRoot, 'project.yml'), 'utf8');
  const marketing = /MARKETING_VERSION:\s*"(\d+\.\d+\.\d+)"/.exec(project)?.[1];
  if (marketing !== manifest.version) {
    throw new Error(`Версии расходятся: project.yml ${marketing}, package.json ${manifest.version}.`);
  }
  return marketing;
}

/** распаковывает архив рядом и проверяет идентификатор, версию и подпись сертификатом выпусков */
async function inspectArchive(version) {
  const unpacked = await mkdtemp(path.join(tmpdir(), 'lidfold-installers-'));
  try {
    execFileSync('/usr/bin/ditto', ['-xk', zipPath, unpacked]);
    const app = path.join(unpacked, 'Lidfold.app');
    const infoPlist = path.join(app, 'Contents/Info.plist');
    const found = [plistValue(infoPlist, 'CFBundleIdentifier'), plistValue(infoPlist, 'CFBundleShortVersionString')];
    if (found[0] !== bundleIdentifier || found[1] !== version) {
      throw new Error(`В архиве ${found.join(' ')}, ожидался ${bundleIdentifier} ${version}.`);
    }
    execFileSync(path.join(projectRoot, 'scripts/verify-release-signature.sh'), [app], { stdio: 'inherit' });
  } finally {
    await rm(unpacked, { recursive: true, force: true });
  }
}

function caskFormula(release) {
  return `cask "lidfold" do
  version "${release.version}"
  sha256 "${release.sha256}"

  url "https://github.com/${release.repository}/releases/download/v#{version}/Lidfold-v#{version}-macos-arm64.zip"
  name "Lidfold"
  desc "Folds, blurs and dims the MacBook desktop as the lid closes"
  homepage "https://github.com/${release.repository}"

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "Lidfold.app"

  caveats <<~EOS
    Lidfold is signed with the project's own certificate and is not notarized by Apple.
    If macOS refuses to open it, allow it in System Settings > Privacy & Security.
    Then grant screen recording access when Lidfold asks.
  EOS
end
`;
}

const version = await projectVersion();
const digest = createHash('sha256').update(await readFile(zipPath)).digest('hex');
const release = { version, repository, asset: path.basename(zipPath), sha256: digest };
const downloadURL = releaseAssetURL(release);
await inspectArchive(version);

const casksFolder = path.join(projectRoot, 'Casks');
await mkdir(casksFolder, { recursive: true });
await writeFile(path.join(casksFolder, 'lidfold.rb'), caskFormula(release));
await writeFile(path.join(projectRoot, 'installer/release.json'), `${JSON.stringify(release, null, 2)}\n`);
console.log(`Установщики закреплены на ${release.asset}: ${downloadURL}`);
console.log('Сначала загрузите этот архив в выпуск на GitHub, потом публикуйте изменения установщиков.');
