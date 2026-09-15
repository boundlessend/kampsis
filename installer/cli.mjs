#!/usr/bin/env node
// ставит Lidfold из выпуска на GitHub: скачивает архив, сверяет SHA-256, подпись и идентификатор приложения
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { lstat, mkdir, mkdtemp, readFile, rename, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const bundleIdentifier = 'local.boundlessend.lidfold';

const usage = `Установка Lidfold (macOS 26+, Apple silicon)

npx github:boundlessend/lidfold [параметры]

  --applications ПАПКА  куда ставить, по умолчанию /Applications
  --replace             обновить уже установленный Lidfold, прежняя копия останется рядом
  --clear-quarantine    снять карантин только с Lidfold.app: первый запуск пройдёт без предупреждения macOS
  --help                эта справка

После установки откройте Lidfold и разрешите запись экрана в настройках macOS.`;

export function parseArguments(argv) {
  const options = { applications: '/Applications', replace: false, clearQuarantine: false, help: false };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === '--help') options.help = true;
    else if (flag === '--replace') options.replace = true;
    else if (flag === '--clear-quarantine') options.clearQuarantine = true;
    else if (flag === '--applications' && value && !value.startsWith('--')) {
      options.applications = path.resolve(value);
      index += 1;
    } else throw new Error(`Непонятный параметр «${flag}». Справка: --help`);
  }
  return options;
}

/** адрес архива выпуска; описание выпуска проверяется целиком, прежде чем что-то скачивать */
export function releaseAssetURL(release) {
  if (!/^\d+\.\d+\.\d+$/.test(release.version)) throw new Error(`Версия выпуска «${release.version}» не похожа на X.Y.Z.`);
  if (!/^[A-Za-z0-9-]+\/[A-Za-z0-9_.-]+$/.test(release.repository)) {
    throw new Error(`Репозиторий выпуска «${release.repository}» не похож на владелец/имя.`);
  }
  const expectedAsset = `Lidfold-v${release.version}-macos-arm64.zip`;
  if (release.asset !== expectedAsset) throw new Error(`Архив выпуска «${release.asset}», ожидался «${expectedAsset}».`);
  if (!/^[0-9a-f]{64}$/.test(release.sha256)) throw new Error('SHA-256 выпуска должен состоять из 64 шестнадцатеричных знаков.');
  return `https://github.com/${release.repository}/releases/download/v${release.version}/${release.asset}`;
}

export function assertChecksum(bytes, expected) {
  const actual = createHash('sha256').update(bytes).digest('hex');
  if (actual !== expected) {
    throw new Error(`SHA-256 архива ${actual} не совпал с ожидаемым ${expected}. Установка отменена, прежняя копия не тронута.`);
  }
}

function run(file, args) {
  return execFileSync(file, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

export function plistValue(plist, key) {
  return run('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, plist]);
}

export async function downloadWithCurl(url, destination) {
  try {
    execFileSync('/usr/bin/curl', ['--fail', '--location', '--proto', '=https', '--proto-redir', '=https', '--retry', '3',
      '--connect-timeout', '15', '--max-time', '300', '--output', destination, url], { stdio: 'inherit' });
  } catch (error) {
    throw new Error(`Не удалось скачать ${url} (curl завершился с кодом ${error.status}). Проверьте интернет и наличие выпуска.`, { cause: error });
  }
}

async function entryKind(target) {
  try {
    const stats = await lstat(target);
    if (stats.isSymbolicLink()) return 'link';
    return stats.isDirectory() ? 'directory' : 'file';
  } catch (error) {
    if (error.code === 'ENOENT') return 'missing';
    throw error;
  }
}

/** запущена ли именно эта копия: ps на macOS печатает полный путь исполняемого файла */
function copyIsRunning(app) {
  const executable = path.join(app, 'Contents/MacOS/Lidfold');
  const listing = spawnSync('/bin/ps', ['-axo', 'comm='], { encoding: 'utf8' });
  if (listing.error || listing.status !== 0) {
    throw new Error(`Не удалось получить список процессов: ps завершился с кодом ${listing.status}.`, { cause: listing.error });
  }
  return listing.stdout.split('\n').some(line => line.trim() === executable);
}

function assertSupportedMac() {
  if (process.platform !== 'darwin') throw new Error('Lidfold работает только на macOS.');
  if (run('/usr/sbin/sysctl', ['-n', 'hw.optional.arm64']) !== '1') throw new Error('Нужен Mac на Apple silicon.');
  const major = Number(run('/usr/bin/sw_vers', ['-productVersion']).split('.')[0]);
  if (major < 26) throw new Error(`Нужна macOS 26 или новее, установлена ${major}.`);
}

async function loadRelease() {
  const manifest = new URL('./release.json', import.meta.url);
  try {
    return JSON.parse(await readFile(manifest, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') throw new Error(`Нет ${fileURLToPath(manifest)}: выпуск для установщика ещё не подготовлен.`, { cause: error });
    throw error;
  }
}

/** `fetchArchive(url, путь)` кладёт архив по пути; в обычной установке это curl */
export async function install(options, release, fetchArchive) {
  assertSupportedMac();
  const url = releaseAssetURL(release);
  const applications = path.resolve(options.applications);
  const destination = path.join(applications, 'Lidfold.app');
  const existing = await entryKind(destination);
  if (existing === 'link' || existing === 'file') {
    throw new Error(`${destination} занят ссылкой или файлом. Уберите его или обновляйте тем способом, которым ставили.`);
  }
  if (existing === 'directory') {
    if (!options.replace) throw new Error('Lidfold уже установлен. Чтобы обновить, завершите его и добавьте --replace.');
    const installedIdentifier = plistValue(path.join(destination, 'Contents/Info.plist'), 'CFBundleIdentifier');
    if (installedIdentifier !== bundleIdentifier) {
      throw new Error(`В ${destination} другое приложение (${installedIdentifier}), замена отменена.`);
    }
    if (copyIsRunning(destination)) throw new Error('Lidfold запущен. Завершите его из меню в строке меню и повторите.');
  }

  await mkdir(applications, { recursive: true });
  const stage = await mkdtemp(path.join(applications, '.lidfold-install-'));
  try {
    const downloaded = path.join(stage, release.asset);
    await fetchArchive(url, downloaded);
    assertChecksum(await readFile(downloaded), release.sha256);
    run('/usr/bin/ditto', ['-xk', downloaded, stage]);
    const app = path.join(stage, 'Lidfold.app');
    const infoPlist = path.join(app, 'Contents/Info.plist');
    const identifier = plistValue(infoPlist, 'CFBundleIdentifier');
    const version = plistValue(infoPlist, 'CFBundleShortVersionString');
    if (identifier !== bundleIdentifier || version !== release.version) {
      throw new Error(`В архиве ${identifier} ${version}, ожидался ${bundleIdentifier} ${release.version}.`);
    }
    run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
    // curl не ставит карантин сам: без него macOS пропустила бы обычную проверку первого запуска
    if (options.clearQuarantine) run('/usr/bin/xattr', ['-dr', 'com.apple.quarantine', app]);
    else run('/usr/bin/xattr', ['-w', 'com.apple.quarantine', `0081;${Math.floor(Date.now() / 1000).toString(16)};lidfold-install;`, app]);

    let backup = null;
    if (existing === 'directory') {
      backup = path.join(applications, `Lidfold.previous-${Date.now()}.app`);
      await rename(destination, backup);
    } else if ((await entryKind(destination)) !== 'missing') {
      throw new Error('Пока шла установка, в папке появился Lidfold.app. Запустите установку ещё раз.');
    }
    try {
      await rename(app, destination);
    } catch (error) {
      if (backup) await rename(backup, destination);
      throw error;
    }
    return { destination, backup, version };
  } finally {
    await rm(stage, { recursive: true, force: true });
  }
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArguments(process.argv.slice(2));
    if (options.help) {
      console.log(usage);
    } else {
      const release = await loadRelease();
      const result = await install(options, release, downloadWithCurl);
      console.log(`Lidfold ${result.version} установлен: ${result.destination}`);
      if (result.backup) console.log(`Прежняя копия: ${result.backup}`);
      if (!options.clearQuarantine) {
        console.log('Если macOS не даст открыть приложение: Системные настройки → Конфиденциальность и безопасность → Всё равно открыть.');
      }
      console.log('Откройте Lidfold и разрешите запись экрана в настройках macOS.');
    }
  } catch (error) {
    const permission = error.code === 'EACCES' || error.code === 'EPERM';
    console.error(permission ? `Нет прав на запись (${error.message}). Попробуйте --applications "$HOME/Applications".` : error.message);
    process.exitCode = 1;
  }
}
