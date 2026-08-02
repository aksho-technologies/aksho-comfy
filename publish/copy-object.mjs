#!/usr/bin/env node
/**
 * Server-side copy inside the aksho-comfy R2 bucket (multipart, so files over
 * 5 GB work). Usage: node publish/copy-object.mjs <srcKey> <destKey>
 */

import 'dotenv/config'
import { config } from 'dotenv'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
config({ path: join(here, '.env') })

import {
  S3Client, HeadObjectCommand, CreateMultipartUploadCommand,
  UploadPartCopyCommand, CompleteMultipartUploadCommand,
} from '@aws-sdk/client-s3'

const BUCKET = process.env.R2_COMFY_BUCKET || 'aksho-comfy'
const client = new S3Client({
  region: 'auto',
  endpoint: `https://${process.env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: process.env.R2_ACCESS_KEY_ID,
    secretAccessKey: process.env.R2_SECRET_ACCESS_KEY,
  },
})

const [src, dest] = process.argv.slice(2)
if (!src || !dest) {
  console.error('Usage: node publish/copy-object.mjs <srcKey> <destKey>')
  process.exit(1)
}

const head = await client.send(new HeadObjectCommand({ Bucket: BUCKET, Key: src }))
const size = head.ContentLength
console.log(`[COPY] ${src} (${(size / 1e9).toFixed(2)} GB) -> ${dest}`)

const PART = 512 * 1024 * 1024
const { UploadId } = await client.send(new CreateMultipartUploadCommand({ Bucket: BUCKET, Key: dest }))
const parts = []
for (let i = 0, part = 1; i < size; i += PART, part += 1) {
  const end = Math.min(i + PART, size) - 1
  const res = await client.send(new UploadPartCopyCommand({
    Bucket: BUCKET, Key: dest, UploadId, PartNumber: part,
    CopySource: `${BUCKET}/${src}`, CopySourceRange: `bytes=${i}-${end}`,
  }))
  parts.push({ ETag: res.CopyPartResult.ETag, PartNumber: part })
  console.log(`[COPY] part ${part} (${((end + 1) / 1e9).toFixed(2)} GB done)`)
}
await client.send(new CompleteMultipartUploadCommand({
  Bucket: BUCKET, Key: dest, UploadId, MultipartUpload: { Parts: parts },
}))
console.log('[COPY] complete')
