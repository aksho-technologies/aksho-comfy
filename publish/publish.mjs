#!/usr/bin/env node
/**
 * Aksho ComfyUI bundle publisher - admin-only CLI for the public download bucket.
 *
 * Manages the R2 bucket behind dl.akshoai.com: uploads bundle components,
 * maintains manifest.json (hashes, sizes, versions), and publishes releases.
 *
 * Usage:
 *   node publish/publish.mjs ensure                          Create the bucket if missing
 *   node publish/publish.mjs stage <dir>                     Print sha256 + size for every file in a folder
 *   node publish/publish.mjs pack <srcDir> <outZip>          Zip a folder (archive root = folder content)
 *   node publish/publish.mjs upload <localPath> <r2Key>      Multipart upload a file
 *   node publish/publish.mjs set-component <id> <localPath>  Recompute sha256/sizeBytes for a manifest entry
 *   node publish/publish.mjs bump <bundleVersion>            Set manifest bundleVersion
 *   node publish/publish.mjs publish                         Upload manifest.json + installer to the bucket
 *
 * Release flow for a changed/added component:
 *   pack (if archive) -> upload -> set-component -> bump -> publish -> git commit manifest.json
 *
 * Credentials come from publish/.env (see .env.example). The bucket must be
 * connected to the public custom domain once, in the Cloudflare dashboard.
 */

import 'dotenv/config'
import { config } from 'dotenv'
import { createHash } from 'node:crypto'
import { createReadStream, readFileSync, writeFileSync, statSync, readdirSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
config({ path: join(here, '.env') })

import { S3Client, CreateBucketCommand, HeadBucketCommand, PutObjectCommand } from '@aws-sdk/client-s3'
import { Upload } from '@aws-sdk/lib-storage'

const BUCKET = process.env.R2_COMFY_BUCKET || 'aksho-comfy'
const accountId = process.env.R2_ACCOUNT_ID
const accessKeyId = process.env.R2_ACCESS_KEY_ID
const secretAccessKey = process.env.R2_SECRET_ACCESS_KEY

const MANIFEST_PATH = join(here, '..', 'manifest.json')
const INSTALLER_PATH = join(here, '..', 'src', 'install.ps1')

function s3() {
  if (!accountId || !accessKeyId || !secretAccessKey) {
    console.error('[PUBLISH] Missing R2 credentials (R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY) in publish/.env')
    process.exit(1)
  }
  return new S3Client({
    region: 'auto',
    endpoint: `https://${accountId}.r2.cloudflarestorage.com`,
    credentials: { accessKeyId, secretAccessKey },
  })
}

function sha256File(path) {
  return new Promise((resolvePromise, reject) => {
    const hash = createHash('sha256')
    const stream = createReadStream(path)
    stream.on('data', (chunk) => hash.update(chunk))
    stream.on('end', () => resolvePromise(hash.digest('hex')))
    stream.on('error', reject)
  })
}

function loadManifest() {
  return JSON.parse(readFileSync(MANIFEST_PATH, 'utf8'))
}

function saveManifest(manifest) {
  writeFileSync(MANIFEST_PATH, JSON.stringify(manifest, null, 2) + '\n')
}

async function cmdEnsure() {
  const client = s3()
  try {
    await client.send(new HeadBucketCommand({ Bucket: BUCKET }))
    console.log(`[PUBLISH] Bucket ${BUCKET} exists`)
  } catch {
    await client.send(new CreateBucketCommand({ Bucket: BUCKET }))
    console.log(`[PUBLISH] Bucket ${BUCKET} created - connect it to the public custom domain in the Cloudflare dashboard`)
  }
}

async function cmdStage(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name)
    const stats = statSync(path)
    if (!stats.isFile()) continue
    const hash = await sha256File(path)
    console.log(`${name}\t${stats.size}\t${hash}`)
  }
}

function cmdPack(srcDir, outZip) {
  // bsdtar (Windows 10+ tar.exe) infers zip format from the extension with -a.
  // -C into the folder so the archive root is the folder CONTENT, matching the
  // installer's extraction contract (no wrapper directory).
  execFileSync('tar', ['-a', '-cf', resolve(outZip), '-C', resolve(srcDir), '.'], { stdio: 'inherit' })
  console.log(`[PUBLISH] Packed ${srcDir} -> ${outZip}`)
}

async function cmdUpload(localPath, key) {
  const client = s3()
  const size = statSync(localPath).size
  console.log(`[PUBLISH] Uploading ${localPath} (${(size / 1e9).toFixed(2)} GB) -> ${BUCKET}/${key}`)
  const upload = new Upload({
    client,
    params: { Bucket: BUCKET, Key: key, Body: createReadStream(localPath) },
    partSize: 64 * 1024 * 1024,
    queueSize: 4,
  })
  upload.on('httpUploadProgress', (p) => {
    if (p.loaded && size) process.stdout.write(`\r[PUBLISH] ${((p.loaded / size) * 100).toFixed(1)}%   `)
  })
  await upload.done()
  process.stdout.write('\n')
  console.log('[PUBLISH] Upload complete')
}

async function cmdSetComponent(id, localPath) {
  const manifest = loadManifest()
  const component = manifest.components.find((c) => c.id === id)
  if (!component) {
    console.error(`[PUBLISH] No component with id ${id} in manifest.json`)
    process.exit(1)
  }
  component.sha256 = await sha256File(localPath)
  component.sizeBytes = statSync(localPath).size
  saveManifest(manifest)
  console.log(`[PUBLISH] ${id}: sha256=${component.sha256} sizeBytes=${component.sizeBytes}`)
}

function cmdBump(version) {
  const manifest = loadManifest()
  manifest.bundleVersion = version
  saveManifest(manifest)
  console.log(`[PUBLISH] bundleVersion -> ${version}`)
}

async function cmdPublish() {
  const client = s3()
  const manifest = loadManifest()
  const empty = manifest.components.filter((c) => !c.sha256 || !c.sizeBytes)
  if (empty.length) {
    console.error(`[PUBLISH] Refusing to publish - components without sha256/sizeBytes: ${empty.map((c) => c.id).join(', ')}`)
    process.exit(1)
  }
  await client.send(new PutObjectCommand({
    Bucket: BUCKET,
    Key: 'installer/install.ps1',
    Body: readFileSync(INSTALLER_PATH),
    ContentType: 'text/plain; charset=utf-8',
  }))
  await client.send(new PutObjectCommand({
    Bucket: BUCKET,
    Key: 'manifest.json',
    Body: readFileSync(MANIFEST_PATH),
    ContentType: 'application/json',
  }))
  console.log(`[PUBLISH] Published manifest (bundle ${manifest.bundleVersion}, installer ${manifest.installerVersion}) + installer to ${BUCKET}`)
  console.log('[PUBLISH] Remember to git commit manifest.json so the repo stays the source of truth')
}

const [cmd, ...args] = process.argv.slice(2)
switch (cmd) {
  case 'ensure': await cmdEnsure(); break
  case 'stage': await cmdStage(args[0]); break
  case 'pack': cmdPack(args[0], args[1]); break
  case 'upload': await cmdUpload(args[0], args[1]); break
  case 'set-component': await cmdSetComponent(args[0], args[1]); break
  case 'bump': cmdBump(args[0]); break
  case 'publish': await cmdPublish(); break
  default:
    console.log('Usage: node publish/publish.mjs <ensure|stage|pack|upload|set-component|bump|publish> [args]')
    process.exit(cmd ? 1 : 0)
}
